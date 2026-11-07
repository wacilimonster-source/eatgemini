/// 网关 HTTP 服务：/v1/chat/completions、/v1/models、/healthz、/readyz、
/// /router/status。
///
/// 规则来源：内核文档 §10、§11，桌面文档 §10。
/// 管理接口不在这里：它们只存在于只绑定回环的控制台服务上。
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import '../core/chat.dart';
import '../core/config.dart';
import '../core/router_engine.dart';
import '../core/telemetry.dart';
import '../quota/quota.dart';

class GatewayServer {
  GatewayServer({
    required RouterConfig Function() config,
    required RouterEngine Function() engine,
    required this.quota,
    required this.tokens,
    required this.appStatus,
    required this.upstreamConfigured,
    this.onSummary,
    this.onEvent,
    this.onAttempt,
    this.onAccess,
    DateTime Function()? clock,
    this.appVersion = '1.0.0',
  })  : _config = config,
        _engine = engine,
        clock = clock ?? DateTime.now;

  final RouterConfig Function() _config;
  final RouterEngine Function() _engine;
  final QuotaManager quota;
  final TokenDirectory tokens;
  final AppStatus Function() appStatus;
  final bool Function() upstreamConfigured;
  final void Function(RequestSummary summary)? onSummary;
  final EventSink? onEvent;
  final void Function(AttemptEvent event)? onAttempt;

  /// 所有被网关直接拒绝（鉴权、限流、未知路径、解析失败）的请求；
  /// 这些请求不进请求记录，但没有这条日志"完全没有痕迹"会误导排查。
  final void Function(int status, String code, String detail)? onAccess;
  final DateTime Function() clock;
  final String appVersion;

  HttpServer? _server;
  final _Admission _admission = _Admission();
  final _AuthRateLimiter _authLimiter = _AuthRateLimiter();

  /// 当前实际监听的地址与端口。
  String? get boundAddress => _server?.address.address;
  int? get boundPort => _server?.port;

  Future<void> start(ListenConfig listen) async {
    final server = await HttpServer.bind(listen.host, listen.port);
    _server = server;
    server.autoCompress = false;
    unawaited(_acceptLoop(server));
  }

  Future<void> stop() async {
    await _server?.close(force: true);
    _server = null;
  }

  Future<void> _acceptLoop(HttpServer server) async {
    await for (final request in server) {
      unawaited(_handle(request));
    }
  }

  Future<void> _handle(HttpRequest request) async {
    final started = clock();
    try {
      request.response.headers.set('x-eatgemini-version', appVersion);
      final remoteIp = request.connectionInfo?.remoteAddress.address ?? '';
      // 契约：/v1 与 /v1/ 两种 baseUrl 都可用（内核文档 §10）。客户端如果
      // 朴素拼接（如酒馆 custom 分支 `${apiUrl}/chat/completions`），带尾
      // 斜杠的 baseUrl 会产生 `/v1//chat/completions` —— 路由前先把重复
      // 斜杠归一，避免 404「未知路径」；访问日志仍记原始 path 便于定位。
      final rawPath = request.uri.path;
      final path = rawPath.replaceAll(RegExp(r'/{2,}'), '/');

      if (request.method == 'GET' && path == '/healthz') {
        await _json(request, 200, {
          'status': 'ok',
          'app': 'eatgemini',
          'version': appVersion,
          'api': kApiVersion,
        });
        return;
      }

      if (request.method == 'GET' && path == '/readyz') {
        final status = appStatus();
        final ready = status.state == 'ready' || status.state == 'degraded';
        await _json(request, ready ? 200 : 503, {
          'ready': ready,
          'state': status.state,
          if (status.reason != null) 'reason': status.reason,
        });
        return;
      }

      if (!path.startsWith('/v1/') && path != '/router/status') {
        onAccess?.call(404, 'not_found', 'path=$rawPath remote=$remoteIp');
        await _openAiError(request, 404, 'not_found', '未知路径 $path');
        return;
      }

      // ---- 鉴权 ----
      final auth = request.headers.value(HttpHeaders.authorizationHeader) ?? '';
      final token = auth.toLowerCase().startsWith('bearer ')
          ? auth.substring(7).trim()
          : '';
      if (_authLimiter.isLocked(remoteIp, clock())) {
        onAccess?.call(429, 'auth_rate_limited', 'remote=$remoteIp');
        await _openAiError(request, 429, 'auth_rate_limited', '鉴权失败次数过多，请稍后再试');
        return;
      }
      final clientId = token.isEmpty ? null : tokens.clientIdForToken(token);
      if (clientId == null) {
        _authLimiter.recordFailure(remoteIp, clock());
        onAccess?.call(401, 'invalid_client_token',
            'remote=$remoteIp token=${token.isEmpty ? '(空)' : '(已脱敏)'}');
        await _openAiError(request, 401, 'invalid_client_token',
            '访问令牌无效，请在 eatgemini 窗口的「接入」页复制新令牌');
        return;
      }
      _authLimiter.recordSuccess(remoteIp);
      final client = _config().auth.clients[clientId];
      if (client == null) {
        await _openAiError(
            request, 401, 'invalid_client_token', '访问令牌对应的客户端已不在配置中');
        return;
      }

      if (request.method == 'GET' && path == '/v1/models') {
        await _handleModels(request, clientId, client);
        return;
      }

      if (request.method == 'GET' && path == '/router/status') {
        await _handleRouterStatus(request, clientId, client);
        return;
      }

      if (request.method == 'POST' && path == '/v1/chat/completions') {
        await _handleChat(request, clientId, client, remoteIp, started);
        return;
      }

      await _openAiError(request, 404, 'not_found', '未知路径 $path');
    } catch (e) {
      // 兜底：绝不让异常把连接挂死。
      try {
        await _openAiError(request, 500, 'gateway_internal_error', '网关内部错误');
      } catch (_) {}
    }
  }

  Future<void> _handleModels(
    HttpRequest request,
    String clientId,
    ClientSpec client,
  ) async {
    final cfg = _config();
    final data = <Map<String, Object?>>[];
    final created = 1700000000;

    data.add({
      'id': 'auto',
      'object': 'model',
      'created': created,
      'owned_by': 'eatgemini',
    });
    for (final profileId in client.allowedProfiles) {
      final ids = cfg.profiles[profileId] ?? const <String>[];
      final entry = <String, Object?>{
        'id': 'router:$profileId',
        'object': 'model',
        'created': created,
        'owned_by': 'eatgemini',
      };
      _applyProfileLimits(entry, ids);
      data.add(entry);
    }
    final allowedModels = <String>{
      for (final p in client.allowedProfiles) ...?cfg.profiles[p],
    };
    for (final id in allowedModels) {
      final spec = cfg.models[id];
      if (spec == null) continue;
      data.add({
        'id': id,
        'object': 'model',
        'created': created,
        'owned_by': 'google',
        if (spec.inputTokenLimit != null)
          'context_window': spec.inputTokenLimit,
        if (spec.outputTokenLimit != null)
          'max_output_tokens': spec.outputTokenLimit,
      });
    }

    await _json(request, 200, {'object': 'list', 'data': data});
  }

  /// 路由别名只在所有已启用候选都核验过容量时输出容量字段。
  void _applyProfileLimits(Map<String, Object?> entry, List<String> ids) {
    final cfg = _config();
    int? inputLimit;
    int? outputLimit;
    var known = true;
    for (final id in ids) {
      final spec = cfg.models[id];
      if (spec == null || !spec.enabled) continue;
      final i = spec.inputTokenLimit;
      final o = spec.outputTokenLimit;
      if (i == null || o == null) {
        known = false;
        break;
      }
      inputLimit = inputLimit == null ? i : min(inputLimit, i);
      outputLimit = outputLimit == null ? o : min(outputLimit, o);
    }
    if (known && inputLimit != null && outputLimit != null) {
      entry['context_window'] = inputLimit;
      entry['max_output_tokens'] = outputLimit;
    }
  }

  Future<void> _handleRouterStatus(
    HttpRequest request,
    String clientId,
    ClientSpec client,
  ) async {
    // 限流：同一令牌 2 秒一次。
    if (!_statusAllowed(clientId)) {
      await _openAiError(request, 429, 'status_rate_limited', '请求过于频繁');
      return;
    }
    final cfg = _config();
    final now = clock();
    final snapshot = quota.snapshot(now);
    final buckets = (snapshot['buckets'] as Map).cast<String, Object?>();
    final models = (snapshot['models'] as Map).cast<String, Object?>();

    final profileEntries = <Map<String, Object?>>[];
    for (final profileId in client.allowedProfiles) {
      final ids = (cfg.profiles[profileId] ?? const <String>[])
          .where((id) => cfg.models[id]?.enabled ?? false)
          .toList();
      int? retryAtMs;
      var available = 0;
      String? nextModel;
      Set<String>? efforts;
      int? contextWindow;
      int? maxOutput;
      var effortsKnown = true;
      var limitsKnown = true;
      for (final id in ids) {
        final skip = quota.check(id, 0, now);
        if (skip == null) {
          available++;
          nextModel ??= id;
        } else {
          final until = skip.blockedUntilMs;
          if (until != null && (retryAtMs == null || until < retryAtMs)) {
            retryAtMs = until;
          }
        }
        final spec = cfg.models[id]!;
        final modelEfforts = spec.reasoningEfforts.toSet();
        if (modelEfforts.isEmpty) {
          effortsKnown = false;
        } else if (efforts == null) {
          efforts = modelEfforts;
        } else {
          efforts = efforts.intersection(modelEfforts);
        }
        if (spec.inputTokenLimit == null || spec.outputTokenLimit == null) {
          limitsKnown = false;
        } else {
          contextWindow = contextWindow == null
              ? spec.inputTokenLimit
              : min(contextWindow, spec.inputTokenLimit!);
          maxOutput = maxOutput == null
              ? spec.outputTokenLimit
              : min(maxOutput, spec.outputTokenLimit!);
        }
      }
      final appState = appStatus();
      final String state;
      if (!upstreamConfigured() || appState.state == 'needs_key') {
        state = 'unavailable';
      } else if (available == 0) {
        state = ids.isEmpty ? 'unavailable' : 'limited';
      } else {
        state = 'available';
      }
      profileEntries.add({
        'id': profileId,
        'model': 'router:$profileId',
        'state': state,
        'nextModel': nextModel,
        'availableModels': available,
        'totalModels': ids.length,
        'retryAt': retryAtMs == null
            ? null
            : DateTime.fromMillisecondsSinceEpoch(retryAtMs, isUtc: true)
                .toIso8601String(),
        'reasoningEfforts':
            effortsKnown ? (efforts?.toList() ?? const []) : const [],
        if (limitsKnown && contextWindow != null)
          'contextWindow': contextWindow,
        if (limitsKnown && maxOutput != null) 'maxOutputTokens': maxOutput,
      });
    }

    final allowedModels = <String>{
      for (final p in client.allowedProfiles) ...?cfg.profiles[p],
    };
    final modelEntries = <Map<String, Object?>>[];
    for (final id in allowedModels) {
      final spec = cfg.models[id];
      if (spec == null) continue;
      final state = (models[id] as Map?)?.cast<String, Object?>() ??
          const <String, Object?>{};
      final rpdGroup = spec.quotaGroups[QuotaDimension.rpd];
      final bucket = rpdGroup == null ? null : buckets['$rpdGroup:rpd'];
      final bucketMap = bucket is Map
          ? bucket.cast<String, Object?>()
          : const <String, Object?>{};
      final skip = quota.check(id, 0, now);
      modelEntries.add({
        'id': id,
        'state': skip == null
            ? 'available'
            : skip.reason == 'daily_suspected' ||
                    skip.reason == 'confirmed_blocked'
                ? 'exhausted'
                : skip.reason == 'quota_unavailable'
                    ? 'unavailable'
                    : 'cooldown',
        'blockedUntil': state['blockedUntil'],
        'reason': skip?.reason,
        'rpd': {
          'used': bucketMap['localAttempts'] ?? 0,
          'limit': spec.quotaGroups[QuotaDimension.rpd] == null
              ? null
              : cfg.quotaGroups[rpdGroup!]?.rpd,
          'estimated': true,
        },
      });
    }

    await _json(request, 200, {
      'api': kApiVersion,
      'app': {'state': appStatus().state, 'reason': appStatus().reason},
      'quotaDay': {
        'day': snapshot['quotaDay'],
        'nextResetAt': snapshot['nextResetAt'],
      },
      'profiles': profileEntries,
      'models': modelEntries,
    });
  }

  final Map<String, DateTime> _lastStatusAt = {};

  bool _statusAllowed(String clientId) {
    final now = clock();
    final last = _lastStatusAt[clientId];
    if (last != null && now.difference(last).inMilliseconds < 2000) {
      return false;
    }
    _lastStatusAt[clientId] = now;
    return true;
  }

  Future<void> _handleChat(
    HttpRequest request,
    String clientId,
    ClientSpec client,
    String remoteIp,
    DateTime started,
  ) async {
    final cfg = _config();
    final status = appStatus();
    final requestId = 'req_${_randomId()}';

    if (status.state == 'needs_key' || !upstreamConfigured()) {
      await _openAiError(request, 503, 'gateway_needs_key',
          'eatgemini 还没有配置 Google API Key，请在电脑上的 eatgemini 窗口中填写');
      return;
    }
    if (status.state == 'persist_error') {
      await _openAiError(request, 503, 'gateway_persist_error',
          'eatgemini 无法保存额度状态，已暂停接收请求，请查看电脑上的提示');
      return;
    }
    if (status.state == 'stopping') {
      await _openAiError(request, 503, 'gateway_stopping', 'eatgemini 正在退出');
      return;
    }

    final bytes = await _readBody(request, cfg.policy.maxRequestBytes);
    if (bytes == null) {
      onAccess?.call(
          413, 'request_too_large', 'remote=$remoteIp client=$clientId');
      await _openAiError(request, 413, 'request_too_large',
          '请求体超过网关大小上限（${cfg.policy.maxRequestBytes} 字节）');
      return;
    }

    Map<String, Object?> body;
    try {
      final decoded = jsonDecode(utf8.decode(bytes));
      if (decoded is! Map) throw const FormatException('顶层必须是对象');
      body = decoded.cast<String, Object?>();
    } on FormatException catch (e) {
      await _openAiError(
          request, 400, 'invalid_json', '请求体不是合法 JSON：${e.message}');
      return;
    }

    ChatRequest chat;
    try {
      chat = parseChatRequest(body);
    } on RequestRejected catch (e) {
      onAccess?.call(e.status, e.code,
          'remote=$remoteIp client=$clientId param=${e.param ?? '-'}');
      await _openAiError(request, e.status, e.code, e.message, param: e.param);
      return;
    }

    final profileHeader = request.headers.value('x-router-profile')?.trim();
    final traceRequested = request.headers.value('x-router-trace') == '1';

    final admitted = await _admission.acquire(
      clientId: clientId,
      maxGlobal: cfg.policy.maxInFlight,
      maxPerClient: cfg.policy.maxInFlightPerClient,
      maxQueue: cfg.policy.maxQueueLength,
      maxQueuePerClient: cfg.policy.maxQueueLengthPerClient,
      maxWaitMs: cfg.policy.maxQueueWaitMs,
    );
    if (!admitted) {
      onAccess?.call(
          429, 'local_capacity_exhausted', 'remote=$remoteIp client=$clientId');
      await _openAiError(
          request, 429, 'local_capacity_exhausted', '网关正在处理的请求已满，请稍后重试');
      return;
    }

    // 取消信号：客户端断开时置位。
    final token = AbortToken();
    onEvent?.call('request.started', {
      'requestId': requestId,
      'client': clientId,
      'requestedModel': chat.model,
      'stream': chat.stream,
      'startedAt': started.toUtc().toIso8601String(),
    });

    RouteResult result;
    try {
      result = await _engine().route(RouteInput(
        clientId: clientId,
        client: client,
        request: chat,
        requestId: requestId,
        startedAt: started,
        profileHeader: profileHeader,
        abort: token,
        onAttempt: onAttempt,
      ));
    } finally {
      _admission.release(clientId);
    }

    final firstEventMs = clock().difference(started).inMilliseconds;
    final trace = result.trace;

    switch (result) {
      case RouteJsonResult r:
        _emitSummary(
          requestId: requestId,
          clientId: clientId,
          chat: chat,
          trace: trace,
          started: started,
          remoteIp: remoteIp,
          outcome: 'succeeded',
          httpStatus: r.status,
          firstEventMs: firstEventMs,
          usage: _usageOf(r.json),
        );
        await _writeJson(request, r.status, r.json, headers: {
          'x-request-id': requestId,
          if (traceRequested) 'x-router-model': trace.servedModel ?? '',
          if (traceRequested) 'x-router-attempts': '${trace.upstreamAttempts}',
        });
        return;

      case RouteStreamResult r:
        {
          final headers = <String, String>{
            ...r.headers,
            'x-request-id': requestId,
            if (traceRequested) 'x-router-model': trace.servedModel ?? '',
            if (traceRequested)
              'x-router-attempts': '${trace.upstreamAttempts}',
          };
          var committed = false;
          Map<String, Object?>? usage;
          var outcome = 'succeeded';
          try {
            request.response.statusCode = r.status;
            // Windows 上 HttpResponse 默认 bufferOutput=true，flush() 不会把
            // 小块真正推出去，SSE 会攒到响应结束才一次性到达客户端（实测
            // 400ms 间隔的块被整段缓冲）。流式响应必须关掉输出缓冲。
            request.response.bufferOutput = false;
            headers.forEach(request.response.headers.set);
            await request.response.flush();
            committed = true;
            await for (final chunk in r.body) {
              usage = _sniffUsage(chunk, usage);
              request.response.add(chunk);
              await request.response.flush();
            }
            await request.response.close();
          } catch (_) {
            outcome =
                committed ? 'failed_after_commit' : 'failed_before_commit';
            token.abort();
            try {
              await request.response.close();
            } catch (_) {}
          }
          _emitSummary(
            requestId: requestId,
            clientId: clientId,
            chat: chat,
            trace: trace,
            started: started,
            remoteIp: remoteIp,
            outcome: outcome,
            httpStatus: r.status,
            firstEventMs: firstEventMs,
            usage: usage,
          );
          return;
        }

      case RouteErrorResult r:
        _emitSummary(
          requestId: requestId,
          clientId: clientId,
          chat: chat,
          trace: trace,
          started: started,
          remoteIp: remoteIp,
          outcome: r.status == 499 ? 'cancelled' : 'failed_before_commit',
          httpStatus: r.status,
          errorCode: r.code,
          firstEventMs: firstEventMs,
        );
        await _writeJson(request, r.status, r.body, headers: {
          'x-request-id': requestId,
          if (r.retryAfterSeconds != null)
            'retry-after': '${r.retryAfterSeconds}',
        });
        return;
    }
  }

  void _emitSummary({
    required String requestId,
    required String clientId,
    required ChatRequest chat,
    required RouteTrace trace,
    required DateTime started,
    required String remoteIp,
    required String outcome,
    required int httpStatus,
    required int firstEventMs,
    String? errorCode,
    Map<String, Object?>? usage,
  }) {
    final summary = RequestSummary(
      requestId: requestId,
      clientId: clientId,
      requestedModel: chat.model,
      profile: trace.profile,
      servedModel: trace.servedModel,
      stream: chat.stream,
      startedAt: started,
      outcome: outcome,
      httpStatus: httpStatus,
      errorCode: errorCode,
      upstreamAttempts: trace.upstreamAttempts,
      fellBack: trace.fellBack,
      cancelled: outcome == 'cancelled',
      totalMs: clock().difference(started).inMilliseconds,
      firstEventMs: firstEventMs,
      remoteIp: remoteIp,
      transforms: trace.transforms,
      skipped: trace.skipped,
      usage: usage,
    );
    onSummary?.call(summary);
    onEvent?.call('request.finished', summary.toJson());
  }

  Map<String, Object?>? _usageOf(Map<String, Object?> json) {
    final usage = json['usage'];
    return usage is Map ? usage.cast<String, Object?>() : null;
  }

  /// 从下游 SSE 块里窥探 usage（只用于统计，不改写内容）。
  Map<String, Object?>? _sniffUsage(
    List<int> chunk,
    Map<String, Object?>? current,
  ) {
    if (chunk.isEmpty) return current;
    try {
      final text = utf8.decode(chunk, allowMalformed: true);
      final idx = text.indexOf('"usage"');
      if (idx < 0) return current;
      for (final line in text.split('\n')) {
        if (!line.startsWith('data: ')) continue;
        final payload = line.substring(6).trim();
        if (payload == '[DONE]' || !payload.contains('"usage"')) continue;
        final decoded = jsonDecode(payload);
        if (decoded is Map) {
          final usage = decoded['usage'];
          if (usage is Map) return usage.cast<String, Object?>();
        }
      }
    } catch (_) {}
    return current;
  }

  Future<Uint8List?> _readBody(HttpRequest request, int maxBytes) async {
    final builder = BytesBuilder(copy: false);
    var overLimit = false;
    await for (final chunk in request) {
      if (maxBytes > 0 &&
          !overLimit &&
          builder.length + chunk.length > maxBytes) {
        // 先把请求体读完再回 413：提前断开会把客户端的连接打断，
        // 客户端读不到错误响应（内核文档 §10）。
        overLimit = true;
      }
      if (overLimit) continue;
      builder.add(chunk);
    }
    if (overLimit) return null;
    return builder.takeBytes();
  }

  Future<void> _json(
      HttpRequest request, int status, Map<String, Object?> body) async {
    request.response.statusCode = status;
    request.response.headers.contentType =
        ContentType('application', 'json', charset: 'utf-8');
    request.response.headers.set('cache-control', 'no-store');
    request.response.write(jsonEncode(body));
    await request.response.close();
  }

  Future<void> _writeJson(
    HttpRequest request,
    int status,
    Map<String, Object?> body, {
    Map<String, String> headers = const {},
  }) async {
    request.response.statusCode = status;
    request.response.headers.contentType =
        ContentType('application', 'json', charset: 'utf-8');
    request.response.headers.set('cache-control', 'no-store');
    headers.forEach((k, v) => request.response.headers.set(k, v));
    request.response.write(jsonEncode(body));
    await request.response.close();
  }

  Future<void> _openAiError(
    HttpRequest request,
    int status,
    String code,
    String message, {
    String? param,
  }) async {
    await _writeJson(request, status, {
      'error': {
        'message': message,
        'type': switch (status) {
          401 || 403 => 'authentication_error',
          429 => 'rate_limit_error',
          >= 500 => 'upstream_error',
          _ => 'invalid_request_error',
        },
        'code': code,
        'param': param,
      },
    }, headers: {
      if (status == 429) 'retry-after': '5',
    });
  }

  String _randomId() {
    final r = Random.secure();
    const chars = 'abcdefghijklmnopqrstuvwxyz0123456789';
    return List.generate(10, (_) => chars[r.nextInt(chars.length)]).join();
  }
}

class _Admission {
  int _inFlight = 0;
  final Map<String, int> _perClient = {};
  final List<Completer<bool>> _waiters = [];

  Future<bool> acquire({
    required String clientId,
    required int maxGlobal,
    required int maxPerClient,
    required int maxQueue,
    required int maxQueuePerClient,
    required int maxWaitMs,
  }) async {
    final perClient = _perClient[clientId] ?? 0;
    if (_inFlight < maxGlobal && perClient < maxPerClient) {
      _take(clientId);
      return true;
    }
    if (_waiters.length >= maxQueue) return false;
    final completer = Completer<bool>();
    _waiters.add(completer);
    Timer(Duration(milliseconds: maxWaitMs), () {
      if (!completer.isCompleted) {
        _waiters.remove(completer);
        completer.complete(false);
      }
    });
    // 排队等待释放：由 release 唤醒。
    return completer.future;
  }

  void _take(String clientId) {
    _inFlight++;
    _perClient[clientId] = (_perClient[clientId] ?? 0) + 1;
  }

  void release(String clientId) {
    _inFlight = _inFlight > 0 ? _inFlight - 1 : 0;
    final next = (_perClient[clientId] ?? 1) - 1;
    if (next <= 0) {
      _perClient.remove(clientId);
    } else {
      _perClient[clientId] = next;
    }
    while (_waiters.isNotEmpty) {
      final waiter = _waiters.removeAt(0);
      if (waiter.isCompleted) continue;
      _take(clientId);
      waiter.complete(true);
      return;
    }
  }
}

class _AuthRateLimiter {
  final Map<String, List<DateTime>> _failures = {};
  final Map<String, DateTime> _lockedUntil = {};

  bool isLocked(String ip, DateTime now) {
    final until = _lockedUntil[ip];
    if (until == null) return false;
    if (now.isAfter(until)) {
      _lockedUntil.remove(ip);
      _failures.remove(ip);
      return false;
    }
    return true;
  }

  void recordFailure(String ip, DateTime now) {
    final list = _failures.putIfAbsent(ip, () => []);
    list.add(now);
    list.removeWhere((t) => now.difference(t).inMinutes >= 1);
    if (list.length >= 10) {
      _lockedUntil[ip] = now.add(const Duration(minutes: 5));
    }
  }

  void recordSuccess(String ip) {
    _failures.remove(ip);
  }
}
