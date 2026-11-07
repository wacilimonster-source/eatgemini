/// 选路引擎：候选生成、预算、首事件提交边界与降级。
///
/// 规则来源：内核文档 §6、§7、§8。
/// 提交边界：向调用方返回 200 之前，必须已经拿到一个完整、合法的上游
/// completion 事件；提交之后不再换模型，只能以 SSE error 结束。
library;

import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import '../adapters/transport.dart';
import '../core/chat.dart';
import '../core/classify.dart';
import '../core/config.dart';
import '../quota/quota.dart';
import '../http/sse.dart';

/// 取消信号：客户端断开或用户点停止时置位。
class AbortToken {
  bool _aborted = false;
  final Completer<void> _completer = Completer<void>();

  bool get isAborted => _aborted;

  Future<void> get whenAborted => _completer.future;

  void abort() {
    if (_aborted) return;
    _aborted = true;
    _completer.complete();
  }
}

class AttemptEvent {
  const AttemptEvent({
    required this.requestId,
    required this.attemptId,
    required this.model,
    required this.phase,
    this.status,
    this.classification,
    this.latencyMs,
    this.reason,
  });

  final String requestId;
  final int attemptId;
  final String model;

  /// sending / waiting_first_event / streaming / done / failed / skipped
  final String phase;
  final int? status;
  final String? classification;
  final int? latencyMs;
  final String? reason;

  Map<String, Object?> toJson() => {
        'requestId': requestId,
        'attemptId': attemptId,
        'model': model,
        'phase': phase,
        if (status != null) 'status': status,
        if (classification != null) 'classification': classification,
        if (latencyMs != null) 'latencyMs': latencyMs,
        if (reason != null) 'reason': reason,
      };
}

class RouteTrace {
  RouteTrace({
    required this.requestId,
    required this.requestedModel,
    required this.startedAt,
  });

  final String requestId;
  final String requestedModel;
  final DateTime startedAt;
  String? profile;
  String? servedModel;
  String? clientId;
  bool fellBack = false;
  int upstreamAttempts = 0;
  final List<AttemptEvent> attempts = [];
  final List<String> transforms = [];
  final List<String> skipped = [];

  Map<String, Object?> toJson() => {
        'requestId': requestId,
        'requestedModel': requestedModel,
        'profile': profile,
        'servedModel': servedModel,
        'fellBack': fellBack,
        'upstreamAttempts': upstreamAttempts,
        'transforms': transforms,
        'skipped': skipped,
        'attempts': [for (final a in attempts) a.toJson()],
      };
}

sealed class RouteResult {
  RouteResult(this.trace);

  final RouteTrace trace;
}

class RouteStreamResult extends RouteResult {
  RouteStreamResult(
    super.trace, {
    required this.status,
    required this.headers,
    required this.body,
  });

  final int status;
  final Map<String, String> headers;
  final Stream<List<int>> body;
}

class RouteJsonResult extends RouteResult {
  RouteJsonResult(
    super.trace, {
    required this.status,
    required this.headers,
    required this.json,
  });

  final int status;
  final Map<String, String> headers;
  final Map<String, Object?> json;
}

class RouteErrorResult extends RouteResult {
  RouteErrorResult(
    super.trace, {
    required this.status,
    required this.body,
    this.retryAfterSeconds,
    this.code = 'router_error',
  });

  final int status;
  final Map<String, Object?> body;
  final int? retryAfterSeconds;
  final String code;
}

class RouteInput {
  RouteInput({
    required this.clientId,
    required this.client,
    required this.request,
    required this.requestId,
    required this.startedAt,
    this.profileHeader,
    AbortToken? abort,
    void Function(AttemptEvent event)? onAttempt,
  })  : abort = abort ?? AbortToken(),
        _onAttempt = onAttempt;

  final String clientId;
  final ClientSpec client;
  final ChatRequest request;
  final String requestId;
  final DateTime startedAt;
  final String? profileHeader;
  final AbortToken abort;
  final void Function(AttemptEvent event)? _onAttempt;

  void emit(AttemptEvent event) => _onAttempt?.call(event);
}

class RouterEngine {
  RouterEngine({
    required RouterConfig Function() config,
    required this.transport,
    required this.quota,
    required String Function() upstreamApiKey,
    DateTime Function()? clock,
    Random? random,
  })  : _config = config,
        _upstreamApiKey = upstreamApiKey,
        clock = clock ?? DateTime.now,
        _random = random ?? Random();

  final RouterConfig Function() _config;
  final String Function() _upstreamApiKey;
  final Transport transport;
  final QuotaManager quota;
  final DateTime Function() clock;
  final Random _random;

  RouterConfig get config => _config();

  Future<RouteResult> route(RouteInput input) async {
    final trace = RouteTrace(
      requestId: input.requestId,
      requestedModel: input.request.model,
      startedAt: input.startedAt,
    )..clientId = input.clientId;

    final resolution = _resolveCandidates(input, trace);
    if (resolution is _Reject) {
      return _errorResult(
        trace,
        status: resolution.status,
        code: resolution.code,
        message: resolution.message,
      );
    }
    final spec = resolution as _Plan;
    trace.profile = spec.profileId;

    final policy = config.policy;
    final routeDeadline =
        input.startedAt.add(Duration(milliseconds: policy.routingDeadlineMs));
    final requestDeadline = policy.requestDeadlineMs == 0
        ? DateTime.utc(9999)
        : input.startedAt.add(Duration(milliseconds: policy.requestDeadlineMs));

    final estTokens = input.request.estimatedInputTokens;
    final queue = [
      for (final id in spec.models)
        _Candidate(modelId: id, spec: config.models[id]!),
    ];
    var cursor = 0;
    var attempts = 0;
    var distinctModels = 0;
    var transientRetries = 0;
    var repairs = 0;
    var probePass = false;
    UpstreamFailure? lastFailure;

    while (true) {
      if (input.abort.isAborted) {
        return _cancelled(trace);
      }
      final now = clock();
      if (attempts >= policy.maxUpstreamRequests) break;
      if (distinctModels >= policy.maxDistinctModels) break;

      _Candidate? chosen;
      while (cursor < queue.length) {
        final candidate = queue[cursor];
        if (candidate.exhausted) {
          cursor++;
          continue;
        }
        final skip = quota.check(
          candidate.modelId,
          estTokens,
          now,
          allowProbe: probePass,
        );
        if (skip != null) {
          trace.skipped.add('${candidate.modelId}: ${skip.reason}');
          candidate.exhausted = true;
          candidate.skip = skip;
          cursor++;
          continue;
        }
        chosen = candidate;
        break;
      }

      if (chosen == null) {
        // 全部候选都被本地状态挡住：如果只是"疑似日耗尽"，允许一次低频探测。
        if (!probePass &&
            queue.any((c) => c.skip?.reason == 'daily_suspected')) {
          probePass = true;
          for (final c in queue) {
            if (c.skip?.reason == 'daily_suspected') {
              c.exhausted = false;
              c.skip = null;
            }
          }
          cursor = 0;
          continue;
        }
        break;
      }

      if (!chosen.seen) {
        chosen.seen = true;
        distinctModels++;
      }

      final nowAfterWait = clock();
      if (!nowAfterWait.isBefore(routeDeadline)) break;

      final reservation = quota.reserve(
        chosen.modelId,
        estTokens,
        nowAfterWait,
        allowProbe: probePass,
      );
      if (reservation == null) {
        chosen.exhausted = true;
        cursor++;
        continue;
      }

      attempts++;
      trace.upstreamAttempts = attempts;
      final attemptId = trace.attempts.length + 1;
      final attemptStart = clock();

      final body = _buildBody(
        input.request,
        chosen.spec,
        chosen.modelId,
        trace.transforms,
        spec.compatibility.defaultMaxOutputTokens,
        {...chosen.repairs, ...quota.learnedStripsFor(chosen.modelId)},
      );
      input.emit(AttemptEvent(
        requestId: trace.requestId,
        attemptId: attemptId,
        model: chosen.modelId,
        phase: 'sending',
      ));

      final outcome = await _attempt(
        input: input,
        modelId: chosen.modelId,
        body: body,
        reservation: reservation,
        routeDeadline: routeDeadline,
        requestDeadline: requestDeadline,
      );

      final latency = clock().difference(attemptStart).inMilliseconds;

      switch (outcome) {
        case _AttemptSuccess():
          trace.servedModel = outcome.modelId;
          trace.fellBack =
              attempts > 1 || chosen.modelId != queue.first.modelId;
          trace.attempts.add(AttemptEvent(
            requestId: trace.requestId,
            attemptId: attemptId,
            model: chosen.modelId,
            phase: outcome.isStream ? 'streaming' : 'done',
            status: 200,
            latencyMs: latency,
          ));
          input.emit(trace.attempts.last);
          if (outcome.stream != null) {
            return RouteStreamResult(
              trace,
              status: 200,
              headers: outcome.headers,
              body: outcome.stream!,
            );
          }
          return RouteJsonResult(
            trace,
            status: 200,
            headers: outcome.headers,
            json: outcome.json!,
          );

        case _AttemptFailure():
          lastFailure = outcome.failure;
          trace.attempts.add(AttemptEvent(
            requestId: trace.requestId,
            attemptId: attemptId,
            model: chosen.modelId,
            phase: 'failed',
            status: outcome.failure.status,
            classification: outcome.failure.kind.name,
            latencyMs: latency,
          ));
          input.emit(trace.attempts.last);
          quota.applyFailure(
            chosen.modelId,
            outcome.failure,
            clock(),
            reservation: reservation,
          );

          final kind = outcome.failure.kind;
          if (kind.scopeWide) {
            return _failureToResult(trace, outcome.failure);
          }
          if (kind == FailureKind.blocked ||
              kind == FailureKind.invalidRequest) {
            return _failureToResult(trace, outcome.failure);
          }
          if (kind == FailureKind.repairableParam &&
              repairs < policy.maxParamRepairsPerRequest &&
              outcome.failure.param != null) {
            repairs++;
            // 'penalty' 是分类层的合成组键：一次剥掉两个惩罚项。
            final strippedParams = outcome.failure.param == 'penalty'
                ? const ['frequency_penalty', 'presence_penalty']
                : [outcome.failure.param!];
            for (final name in strippedParams) {
              chosen.repairs.add(name);
              trace.transforms.add('repair:drop:$name');
            }
            // 记住该模型不支持这些参数，后续请求（含重启后）不再发送。
            quota.learnStrips(chosen.modelId, strippedParams);
            continue; // 同一模型再试一次
          }
          if (kind == FailureKind.transient &&
              transientRetries < policy.maxTransientRetriesPerRequest &&
              clock().isBefore(routeDeadline)) {
            transientRetries++;
            await Future<void>.delayed(
              Duration(milliseconds: 250 + _random.nextInt(250)),
            );
            continue; // 同一模型重试一次
          }
          chosen.exhausted = true;
          cursor++;
          continue;
      }
    }

    // 没有成功：区分"全部限流 / 临时故障 / 截止 / 无能力匹配"。
    return _exhaustedResult(
      trace,
      attempts: attempts,
      lastFailure: lastFailure,
      queue: queue,
      requestDeadline: requestDeadline,
      aborted: input.abort.isAborted,
    );
  }

  // ---------------------------------------------------------------- 解析

  Object _resolveCandidates(RouteInput input, RouteTrace trace) {
    final cfg = config;
    final allowedProfiles = input.client.allowedProfiles;
    final model = input.request.model;

    if (model.startsWith('router:')) {
      final profileId = model.substring('router:'.length);
      if (input.profileHeader != null && input.profileHeader != profileId) {
        return _Reject(400, 'conflicting_profile_header',
            'model 与 X-Router-Profile 指定的档位不一致');
      }
      if (!allowedProfiles.contains(profileId)) {
        return _Reject(
            403, 'profile_not_allowed', '该客户端的访问令牌不允许使用档位 $profileId');
      }
      final ids = cfg.profiles[profileId];
      if (ids == null) {
        return _Reject(400, 'unknown_profile', '未知档位 $profileId');
      }
      trace.profile = profileId;
      return _Plan(
        profileId,
        ids,
        cfg.compatibility[input.client.compatibility]!,
      );
    }

    if (model == 'auto') {
      final profileId = input.profileHeader ?? cfg.policy.defaultProfile;
      if (!allowedProfiles.contains(profileId)) {
        return _Reject(
            403, 'profile_not_allowed', '该客户端的访问令牌不允许使用档位 $profileId');
      }
      final ids = cfg.profiles[profileId];
      if (ids == null) {
        return _Reject(400, 'unknown_profile', '未知档位 $profileId');
      }
      trace.profile = profileId;
      return _Plan(
        profileId,
        ids,
        cfg.compatibility[input.client.compatibility]!,
      );
    }

    if (!cfg.models.containsKey(model)) {
      return _Reject(404, 'unknown_model', '网关没有模型「$model」');
    }
    final allowedModels = <String>{
      for (final p in allowedProfiles) ...?cfg.profiles[p],
    };
    if (!allowedModels.contains(model)) {
      return _Reject(403, 'model_not_allowed', '该客户端的访问令牌不允许使用模型 $model');
    }
    trace.profile = null;
    return _Plan(
      null,
      [model],
      cfg.compatibility[input.client.compatibility]!,
    );
  }

  Map<String, Object?> _buildBody(
    ChatRequest req,
    ModelSpec spec,
    String modelId,
    List<String> transforms,
    int defaultMaxOutputTokens,
    Set<String> repairs,
  ) {
    final body = <String, Object?>{
      'model': modelId,
      'messages': [for (final m in req.messages) m.toUpstreamJson()],
      'stream': req.stream,
      if (req.stream) 'stream_options': const {'include_usage': true},
    };

    void put(String key, Object? value) {
      if (value == null) return;
      if (spec.stripParams.contains(key) || repairs.contains(key)) {
        transforms.add('strip:$key');
        return;
      }
      body[key] = value;
    }

    put('temperature', req.temperature);
    put('top_p', req.topP);
    put('frequency_penalty', req.frequencyPenalty);
    put('presence_penalty', req.presencePenalty);
    put('top_k', req.topK);

    final outLimit = spec.outputTokenLimit;
    final maxTokens = req.maxTokens ??
        (defaultMaxOutputTokens > 0 ? defaultMaxOutputTokens : outLimit);
    if (maxTokens != null) {
      if (repairs.contains('max_tokens') ||
          spec.stripParams.contains('max_tokens')) {
        transforms.add('strip:max_tokens');
      } else if (outLimit != null && maxTokens > outLimit) {
        body['max_tokens'] = outLimit;
        transforms.add('clamp:max_tokens');
      } else {
        body['max_tokens'] = maxTokens;
      }
    }

    if (req.stop != null && !repairs.contains('stop')) {
      body['stop'] = req.stop;
    }

    if (req.reasoningEffort != null && !repairs.contains('reasoning_effort')) {
      final effort = req.reasoningEffort!;
      if (spec.reasoningEfforts.isEmpty) {
        transforms.add('drop:reasoning_effort(unverified)');
      } else if (!spec.reasoningEfforts.contains(effort)) {
        transforms.add('drop:reasoning_effort(unsupported)');
      } else {
        body['reasoning_effort'] = effort;
      }
    }

    if (req.seed != null && !repairs.contains('seed')) {
      transforms.add('drop:seed');
    }

    return body;
  }

  // ---------------------------------------------------------------- 单次尝试

  Future<_AttemptOutcome> _attempt({
    required RouteInput input,
    required String modelId,
    required Map<String, Object?> body,
    required Reservation reservation,
    required DateTime routeDeadline,
    required DateTime requestDeadline,
  }) async {
    final cfg = config;
    final uri = Uri.parse('${cfg.upstream.baseUrl}chat/completions');
    final payload = Uint8List.fromList(utf8.encode(jsonEncode(body)));
    final headers = <String, String>{
      'content-type': 'application/json',
      'authorization': 'Bearer ${_upstreamApiKey()}',
      'user-agent': 'eatgemini/1.0',
    };

    final firstEventBudget = _minDuration(
      Duration(milliseconds: cfg.upstream.firstEventTimeoutMs),
      _remaining(requestDeadline),
    );
    if (firstEventBudget <= Duration.zero) {
      quota.markUncertain(reservation);
      return _AttemptFailure(
        const UpstreamFailure(
          kind: FailureKind.transient,
          status: 504,
          message: '路由截止时间已到',
        ),
      );
    }

    UpstreamResponse response;
    try {
      response = await transport.send(
        UpstreamRequest(
          uri: uri,
          headers: headers,
          body: payload,
        ),
        firstEventTimeout: firstEventBudget,
      );
    } on EgressDenied catch (e) {
      quota.releaseUnsent(reservation);
      return _AttemptFailure(UpstreamFailure(
        kind: FailureKind.endpointMisconfigured,
        status: 502,
        message: e.toString(),
      ));
    } on TimeoutException {
      quota.markUncertain(reservation);
      return _AttemptFailure(const UpstreamFailure(
        kind: FailureKind.transient,
        status: 504,
        message: '等待上游响应头超时',
      ));
    } catch (e) {
      quota.markUncertain(reservation);
      return _AttemptFailure(UpstreamFailure(
        kind: FailureKind.transient,
        status: 502,
        message: _shorten(e.toString()),
      ));
    }

    if (response.statusCode != 200) {
      final text = await _readLimited(response.body, 65536);
      await response.cancel();
      final failure = classifyUpstreamError(
        status: response.statusCode,
        headers: response.headers,
        body: text,
      );
      return _AttemptFailure(failure);
    }

    if (!input.request.stream) {
      try {
        final bytes = await _readLimitedBytes(
          response.body,
          cfg.policy.maxBufferedResponseBytes,
        );
        final decoded = jsonDecode(utf8.decode(bytes));
        if (decoded is! Map) {
          quota.markUncertain(reservation);
          return _AttemptFailure(const UpstreamFailure(
            kind: FailureKind.upstreamProtocolError,
            status: 200,
            message: '上游返回的不是 JSON 对象',
          ));
        }
        final choices = decoded['choices'];
        if (choices is! List || choices.isEmpty) {
          final error = decoded['error'];
          if (error != null) {
            return _AttemptFailure(_classifyStreamError(
              error,
              response.headers,
            ));
          }
          quota.markUncertain(reservation);
          return _AttemptFailure(const UpstreamFailure(
            kind: FailureKind.upstreamProtocolError,
            status: 200,
            message: '上游响应缺少 choices',
          ));
        }
        quota.markSuccess(reservation);
        final served = decoded['model']?.toString();
        return _AttemptSuccess.json(
          (decoded).cast<String, Object?>(),
          modelId: served ?? modelId,
          headers: _passthroughHeaders(response.headers),
        );
      } on TimeoutException {
        await response.cancel();
        quota.markUncertain(reservation);
        return _AttemptFailure(const UpstreamFailure(
          kind: FailureKind.transient,
          status: 504,
          message: '等待上游完整响应超时',
        ));
      } catch (e) {
        await response.cancel();
        quota.markUncertain(reservation);
        return _AttemptFailure(UpstreamFailure(
          kind: FailureKind.upstreamProtocolError,
          status: 200,
          message: _shorten(e.toString()),
        ));
      }
    }

    // ---- 流式：等第一个合法 completion 事件 ----
    // 思考模型（Gemini 3 系）首事件普遍 20–60s：这里的等待由
    // firstEventTimeoutMs 与总截止约束，不受路由截止截断——路由截止
    // 只限制"开始新的上游尝试"（内核文档 §6.2）。
    final iterator = StreamIterator(decodeSse(response.body));
    Map<String, Object?>? first;
    var sawAny = false;
    try {
      while (true) {
        final hasNext = await _moveNext(
          iterator,
          _minDuration(
            Duration(milliseconds: cfg.upstream.firstEventTimeoutMs),
            _remaining(requestDeadline),
          ),
        );
        if (!hasNext) break;
        final event = iterator.current;
        if (event.isDone) break;
        sawAny = true;
        Object? decoded;
        try {
          decoded = jsonDecode(event.data);
        } catch (_) {
          throw SseProtocolException('上游返回了无法解析的 SSE 数据');
        }
        if (decoded is! Map) continue;
        final map = decoded.cast<String, Object?>();
        if (map['error'] != null) {
          return _AttemptFailure(
            _classifyStreamError(map['error'], response.headers),
          );
        }
        final choices = map['choices'];
        if (choices is List && choices.isNotEmpty) {
          first = map;
          break;
        }
        // usage-only 或 role-only 帧：继续等。
      }
    } on TimeoutException {
      await iterator.cancel();
      await response.cancel();
      quota.markUncertain(reservation);
      return _AttemptFailure(const UpstreamFailure(
        kind: FailureKind.transient,
        status: 504,
        message: '等待上游首个响应事件超时',
      ));
    } catch (e) {
      await iterator.cancel();
      await response.cancel();
      quota.markUncertain(reservation);
      return _AttemptFailure(UpstreamFailure(
        kind: FailureKind.upstreamProtocolError,
        status: 200,
        message: _shorten(e.toString()),
      ));
    }

    if (first == null) {
      await iterator.cancel();
      await response.cancel();
      quota.markUncertain(reservation);
      return _AttemptFailure(UpstreamFailure(
        kind: FailureKind.transient,
        status: 200,
        message: sawAny ? '上游流在首帧前结束' : '上游返回了空流',
      ));
    }

    quota.markSuccess(reservation);
    final served = first['model']?.toString() ?? modelId;
    return _AttemptSuccess.stream(
      _continueStreamText(
        iterator: iterator,
        first: first,
        includeUsage: input.request.includeUsage,
        idleTimeout: Duration(milliseconds: cfg.upstream.streamIdleTimeoutMs),
        requestDeadline: requestDeadline,
      ).map(utf8.encode),
      modelId: served,
      headers: const {
        'content-type': 'text/event-stream; charset=utf-8',
        'cache-control': 'no-cache, no-transform',
        'x-accel-buffering': 'no',
      },
    );
  }

  Stream<String> _continueStreamText({
    required StreamIterator<SseEvent> iterator,
    required Map<String, Object?> first,
    required bool includeUsage,
    required Duration idleTimeout,
    required DateTime requestDeadline,
  }) async* {
    var finishSeen = _hasFinish(first);
    yield encodeDownstreamData(first);
    try {
      while (true) {
        final budget = _minDuration(idleTimeout, _remaining(requestDeadline));
        if (budget <= Duration.zero) {
          yield encodeDownstreamData(sseErrorPayload(
            message: '网关总截止时间已到',
            code: 'gateway_deadline',
          ));
          return;
        }
        bool hasNext;
        try {
          hasNext = await _moveNext(iterator, budget);
        } on TimeoutException {
          yield encodeDownstreamData(sseErrorPayload(
            message: '上游流空闲超时',
            code: 'upstream_idle_timeout',
          ));
          return;
        }
        if (!hasNext) {
          if (finishSeen) {
            yield kDownstreamDone;
          } else {
            yield encodeDownstreamData(sseErrorPayload(
              message: '上游流在完成前结束，回复不完整',
              code: 'incomplete_stream',
            ));
          }
          return;
        }
        final event = iterator.current;
        if (event.isDone) {
          if (!finishSeen) {
            yield encodeDownstreamData(sseErrorPayload(
              message: '上游只发送了结束标记，没有合法完成帧',
              code: 'incomplete_stream',
            ));
          } else {
            yield kDownstreamDone;
          }
          return;
        }
        Object? decoded;
        try {
          decoded = jsonDecode(event.data);
        } catch (_) {
          yield encodeDownstreamData(sseErrorPayload(
            message: '上游返回了无法解析的数据',
            code: 'gateway_protocol',
          ));
          return;
        }
        if (decoded is! Map) continue;
        final map = decoded.cast<String, Object?>();
        final error = map['error'];
        if (error != null) {
          yield encodeDownstreamData(sseErrorPayload(
            message: _errorMessage(error),
            code: 'upstream_stream_error',
          ));
          return;
        }
        final choices = map['choices'];
        final usageOnly = choices is List && choices.isEmpty;
        if (usageOnly && !includeUsage) continue;
        if (_hasFinish(map)) finishSeen = true;
        yield encodeDownstreamData(map);
      }
    } finally {
      await iterator.cancel();
    }
  }

  Future<bool> _moveNext(StreamIterator<SseEvent> it, Duration timeout) {
    if (timeout <= Duration.zero) {
      throw TimeoutException('no budget');
    }
    return it.moveNext().timeout(timeout);
  }

  bool _hasFinish(Map<String, Object?> map) {
    final choices = map['choices'];
    if (choices is! List) return false;
    for (final c in choices) {
      if (c is Map) {
        final fr = c['finish_reason'];
        if (fr != null && fr.toString() != 'null' && fr.toString().isNotEmpty) {
          return true;
        }
      }
    }
    return false;
  }

  UpstreamFailure _classifyStreamError(
      Object? error, Map<String, String> headers) {
    String message;
    String? code;
    int status = 400;
    if (error is Map) {
      message = (error['message'] ?? error['msg'] ?? '上游返回错误').toString();
      code = error['code']?.toString() ?? error['status']?.toString();
      final numeric = int.tryParse(error['code']?.toString() ?? '');
      if (numeric != null && numeric >= 400) status = numeric;
    } else {
      message = error.toString();
    }
    final lowered = message.toLowerCase();
    if (lowered.contains('quota') ||
        lowered.contains('resource_exhausted') ||
        code == 'RESOURCE_EXHAUSTED') {
      return UpstreamFailure(
        kind: FailureKind.unknown429,
        status: 429,
        message: message,
        code: code,
      );
    }
    if (lowered.contains('safety') || lowered.contains('blocked')) {
      return UpstreamFailure(
        kind: FailureKind.blocked,
        status: status,
        message: message,
        code: code,
      );
    }
    return UpstreamFailure(
      kind: FailureKind.upstreamProtocolError,
      status: status,
      message: message,
      code: code,
    );
  }

  Map<String, String> _passthroughHeaders(Map<String, String> upstream) => {
        'content-type': 'application/json; charset=utf-8',
        if (upstream['x-request-id'] != null)
          'x-request-id': upstream['x-request-id']!,
      };

  // ---------------------------------------------------------------- 结果构造

  RouteResult _cancelled(RouteTrace trace) => RouteErrorResult(
        trace,
        status: 499,
        code: 'request_cancelled',
        body: _envelope(
          message: '客户端已取消请求',
          code: 'request_cancelled',
          requestId: trace.requestId,
        ),
      );

  RouteResult _failureToResult(RouteTrace trace, UpstreamFailure f) {
    final (status, code) = _mapFailure(f);
    return _errorResult(
      trace,
      status: status,
      code: code,
      message: _userMessage(f),
      retryAfter: f.retryAfterSeconds,
      requestId: trace.requestId,
      type: f.kind.scopeWide ? 'upstream_error' : 'invalid_request_error',
    );
  }

  (int, String) _mapFailure(UpstreamFailure f) => switch (f.kind) {
        FailureKind.upstreamAccessError => (502, 'upstream_access_error'),
        FailureKind.upstreamBillingError => (502, 'upstream_billing_error'),
        FailureKind.endpointMisconfigured => (502, 'endpoint_misconfigured'),
        FailureKind.blocked => (400, 'blocked_by_upstream'),
        FailureKind.invalidRequest => (400, 'invalid_request'),
        FailureKind.upstreamProtocolError => (502, 'upstream_protocol_error'),
        FailureKind.modelUnavailable => (503, 'model_unavailable'),
        FailureKind.modelAccessDenied => (503, 'model_access_denied'),
        FailureKind.transient => (503, 'upstream_unavailable'),
        _ => (429, 'router_quota_unavailable'),
      };

  String _userMessage(UpstreamFailure f) {
    switch (f.kind) {
      case FailureKind.upstreamAccessError:
        return 'Google 拒绝了请求（Key 无效、项目未启用或地区受限）：${_shorten(f.message)}';
      case FailureKind.upstreamBillingError:
        return '上游要求结算信息：${_shorten(f.message)}';
      case FailureKind.endpointMisconfigured:
        return '上游端点配置错误：${_shorten(f.message)}';
      case FailureKind.blocked:
        return '上游安全策略拒绝了这次生成：${_shorten(f.message)}';
      case FailureKind.invalidRequest:
        return '请求被上游拒绝：${_shorten(f.message)}';
      case FailureKind.upstreamProtocolError:
        return '上游返回了无法处理的数据：${_shorten(f.message)}';
      default:
        return _shorten(f.message);
    }
  }

  RouteResult _exhaustedResult(
    RouteTrace trace, {
    required int attempts,
    required UpstreamFailure? lastFailure,
    required List<_Candidate> queue,
    required DateTime requestDeadline,
    required bool aborted,
  }) {
    if (aborted) return _cancelled(trace);
    if (!clock().isBefore(requestDeadline)) {
      return _errorResult(
        trace,
        status: 504,
        code: 'request_deadline_exceeded',
        message: '网关等待上游超过总截止时间',
        requestId: trace.requestId,
        type: 'timeout_error',
      );
    }

    if (attempts == 0) {
      final enabled = config.models.entries.where((e) => e.value.enabled);
      if (enabled.isEmpty) {
        return _errorResult(
          trace,
          status: 503,
          code: 'no_enabled_candidates',
          message: '没有启用的模型',
          requestId: trace.requestId,
          type: 'router_error',
        );
      }
      int? blockedUntil;
      for (final c in queue) {
        final b = c.skip?.blockedUntilMs;
        if (b != null && (blockedUntil == null || b < blockedUntil)) {
          blockedUntil = b;
        }
      }
      final retryAfter = blockedUntil == null
          ? null
          : max(0,
              ((blockedUntil - clock().millisecondsSinceEpoch) / 1000).ceil());
      return _errorResult(
        trace,
        status: 429,
        code: 'router_quota_unavailable',
        message: '当前允许的模型均受配额限制，请稍后重试',
        retryAfter: retryAfter,
        requestId: trace.requestId,
        type: 'rate_limit_error',
      );
    }

    if (lastFailure != null) {
      if (lastFailure.kind == FailureKind.dailyExhausted ||
          lastFailure.kind == FailureKind.rpmLimited ||
          lastFailure.kind == FailureKind.tpmLimited ||
          lastFailure.kind == FailureKind.unknown429 ||
          lastFailure.kind == FailureKind.quotaUnavailable) {
        return _errorResult(
          trace,
          status: 429,
          code: 'router_quota_unavailable',
          message: '当前允许的模型均受配额限制，请稍后重试',
          retryAfter: lastFailure.retryAfterSeconds,
          requestId: trace.requestId,
          type: 'rate_limit_error',
        );
      }
      return _failureToResult(trace, lastFailure);
    }

    return _errorResult(
      trace,
      status: 503,
      code: 'all_candidates_unavailable',
      message: '所有候选模型都暂时不可用',
      requestId: trace.requestId,
      type: 'router_error',
    );
  }

  RouteErrorResult _errorResult(
    RouteTrace trace, {
    required int status,
    required String code,
    required String message,
    int? retryAfter,
    String? requestId,
    String type = 'router_error',
  }) =>
      RouteErrorResult(
        trace,
        status: status,
        code: code,
        retryAfterSeconds: retryAfter,
        body: _envelope(
          message: message,
          code: code,
          type: type,
          retryAfterSeconds: retryAfter,
          requestId: requestId,
        ),
      );

  Map<String, Object?> _envelope({
    required String message,
    required String code,
    String type = 'router_error',
    String? param,
    int? retryAfterSeconds,
    String? requestId,
  }) =>
      {
        'error': {
          'message': message,
          'type': type,
          'code': code,
          'param': param,
          'request_id': requestId,
          if (retryAfterSeconds != null)
            'retry_after_seconds': retryAfterSeconds,
        },
      };

  // ---------------------------------------------------------------- 工具

  Duration _remaining(DateTime deadline) {
    final left = deadline.difference(clock());
    return left.isNegative ? Duration.zero : left;
  }

  Duration _minDuration(Duration a, Duration b) => a < b ? a : b;

  Future<String> _readLimited(Stream<List<int>> stream, int maxBytes) async {
    final builder = BytesBuilder(copy: false);
    await for (final chunk in stream) {
      builder.add(chunk);
      if (builder.length >= maxBytes) break;
    }
    return utf8.decode(builder.takeBytes(), allowMalformed: true);
  }

  Future<List<int>> _readLimitedBytes(
    Stream<List<int>> stream,
    int maxBytes,
  ) async {
    final builder = BytesBuilder(copy: false);
    await for (final chunk in stream) {
      if (maxBytes > 0 && builder.length + chunk.length > maxBytes) {
        throw SseProtocolException('上游响应超过缓冲上限');
      }
      builder.add(chunk);
    }
    return builder.takeBytes();
  }

  static String _shorten(String s) {
    final t = s.replaceAll(RegExp(r'\s+'), ' ').trim();
    return t.length > 300 ? '${t.substring(0, 300)}…' : t;
  }

  static String _errorMessage(Object? error) {
    if (error is Map) {
      final m = error['message'] ?? error['msg'];
      if (m != null) return m.toString();
    }
    return error.toString();
  }
}

class _Reject {
  _Reject(this.status, this.code, this.message);

  final int status;
  final String code;
  final String message;
}

class _Plan {
  _Plan(this.profileId, this.models, this.compatibility);

  final String? profileId;
  final List<String> models;
  final CompatibilityProfile compatibility;
}

class _Candidate {
  _Candidate({required this.modelId, required this.spec});

  final String modelId;
  final ModelSpec spec;
  final Set<String> repairs = {};
  bool seen = false;
  bool exhausted = false;
  SkipInfo? skip;
}

sealed class _AttemptOutcome {}

class _AttemptSuccess implements _AttemptOutcome {
  _AttemptSuccess.stream(
    this.stream, {
    required this.modelId,
    required this.headers,
  })  : json = null,
        isStream = true;

  _AttemptSuccess.json(
    Map<String, Object?> this.json, {
    required this.modelId,
    required this.headers,
  })  : stream = null,
        isStream = false;

  final Stream<List<int>>? stream;
  final Map<String, Object?>? json;
  final Map<String, String> headers;
  final String modelId;
  final bool isStream;
}

class _AttemptFailure implements _AttemptOutcome {
  _AttemptFailure(this.failure);

  final UpstreamFailure failure;
}
