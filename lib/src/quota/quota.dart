/// 配额桶：本地估算、原子预留、封锁与持久化。
///
/// 规则来源：内核文档 §2.4、§9、§7。
/// 关键约束：临界区里不 await；已发送的失败/超时按"不确定"保留；
/// 明确日耗尽封锁到太平洋午夜，未知 429 只做短冷却。
library;

import 'dart:async';
import 'dart:convert';

import '../core/classify.dart';
import '../core/config.dart';
import '../core/pacific_clock.dart';

/// 状态存储抽象（桌面版为文件实现，测试用内存实现）。
abstract interface class StateStore {
  Future<Map<String, Object?>?> read();
  Future<void> write(Map<String, Object?> data);
}

class MemoryStateStore implements StateStore {
  MemoryStateStore([this._data]);

  Map<String, Object?>? _data;

  @override
  Future<Map<String, Object?>?> read() async => _data;

  @override
  Future<void> write(Map<String, Object?> data) async => _data = data;
}

class BucketState {
  BucketState({
    required this.group,
    required this.dimension,
    required this.limit,
    required this.quotaDay,
  });

  final String group;
  final QuotaDimension dimension;
  int? limit;
  String quotaDay;

  int localAttempts = 0;
  int successfulCompletions = 0;
  int uncertainAttempts = 0;

  /// 近 60 秒发送时刻（毫秒时间戳）。
  final List<int> minuteEvents = [];

  /// 近 60 秒的输入 token 估算（毫秒时间戳, tokens）。
  final List<(int, int)> tokenEvents = [];

  int? confirmedBlockedUntilMs;
  int? suspectedBlockedUntilMs;

  /// 最近一次探测时刻（疑似耗尽时允许低频验证）。
  int? lastProbeMs;

  String? reason;
  String? evidence;
  String? confidence;

  String get key => '$group:${dimension.name}';

  Map<String, Object?> toJson() => {
        'group': group,
        'dimension': dimension.name,
        'limit': limit,
        'quotaDay': quotaDay,
        'localAttempts': localAttempts,
        'successfulCompletions': successfulCompletions,
        'uncertainAttempts': uncertainAttempts,
        'minuteEvents': minuteEvents,
        'tokenEvents': [for (final e in tokenEvents) [e.$1, e.$2]],
        'confirmedBlockedUntilMs': confirmedBlockedUntilMs,
        'suspectedBlockedUntilMs': suspectedBlockedUntilMs,
        'lastProbeMs': lastProbeMs,
        'reason': reason,
        'evidence': evidence,
        'confidence': confidence,
      };

  static BucketState fromJson(Map<String, Object?> j) {
    final dim = QuotaDimension.values.firstWhere(
      (d) => d.name == j['dimension'],
      orElse: () => QuotaDimension.rpm,
    );
    final state = BucketState(
      group: (j['group'] ?? '').toString(),
      dimension: dim,
      limit: (j['limit'] as num?)?.toInt(),
      quotaDay: (j['quotaDay'] ?? '').toString(),
    );
    state.localAttempts = (j['localAttempts'] as num?)?.toInt() ?? 0;
    state.successfulCompletions =
        (j['successfulCompletions'] as num?)?.toInt() ?? 0;
    state.uncertainAttempts = (j['uncertainAttempts'] as num?)?.toInt() ?? 0;
    final me = j['minuteEvents'];
    if (me is List) {
      state.minuteEvents.addAll(me.whereType<num>().map((e) => e.toInt()));
    }
    final te = j['tokenEvents'];
    if (te is List) {
      for (final e in te) {
        if (e is List && e.length == 2) {
          final a = e[0];
          final b = e[1];
          if (a is num && b is num) {
            state.tokenEvents.add((a.toInt(), b.toInt()));
          }
        }
      }
    }
    state.confirmedBlockedUntilMs =
        (j['confirmedBlockedUntilMs'] as num?)?.toInt();
    state.suspectedBlockedUntilMs =
        (j['suspectedBlockedUntilMs'] as num?)?.toInt();
    state.lastProbeMs = (j['lastProbeMs'] as num?)?.toInt();
    state.reason = j['reason']?.toString();
    state.evidence = j['evidence']?.toString();
    state.confidence = j['confidence']?.toString();
    return state;
  }
}

class ModelState {
  ModelState();

  int? blockedUntilMs;
  String? reason;
  int consecutiveTransient = 0;
  int? transientBlockedUntilMs;
  int? lastAttemptMs;

  /// 运行期从上游错误学到的"该模型不支持、发送前应剥离"的参数
  /// （如 Gemini 3 系的 frequency/presence_penalty）。跨重启保留。
  final Set<String> learnedStrips = {};

  Map<String, Object?> toJson() => {
        'blockedUntilMs': blockedUntilMs,
        'reason': reason,
        'consecutiveTransient': consecutiveTransient,
        'transientBlockedUntilMs': transientBlockedUntilMs,
        'lastAttemptMs': lastAttemptMs,
        'learnedStrips': learnedStrips.toList(),
      };

  static ModelState fromJson(Map<String, Object?> j) {
    final s = ModelState();
    s.blockedUntilMs = (j['blockedUntilMs'] as num?)?.toInt();
    s.reason = j['reason']?.toString();
    s.consecutiveTransient =
        (j['consecutiveTransient'] as num?)?.toInt() ?? 0;
    s.transientBlockedUntilMs =
        (j['transientBlockedUntilMs'] as num?)?.toInt();
    s.lastAttemptMs = (j['lastAttemptMs'] as num?)?.toInt();
    final learned = j['learnedStrips'];
    if (learned is List) {
      s.learnedStrips.addAll(learned.map((e) => e.toString()));
    }
    return s;
  }
}

/// 一次预留：绑定发送时的配额日，跨午夜完成时回记原日。
class Reservation {
  Reservation({
    required this.reservationId,
    required this.modelId,
    required this.bucketKeys,
    required this.estTokens,
    required this.quotaDay,
    required this.atMs,
  });

  final int reservationId;
  final String modelId;
  final List<String> bucketKeys;
  final int estTokens;
  final String quotaDay;
  final int atMs;

  bool committed = false;
  bool released = false;
  bool settled = false;
}

/// 预留失败原因，用于向界面说明"为什么没试这个模型"。
class SkipInfo {
  const SkipInfo(this.reason, {this.blockedUntilMs, this.detail});

  final String reason;
  final int? blockedUntilMs;
  final String? detail;

  @override
  String toString() => detail == null ? reason : '$reason（$detail）';
}

class QuotaManager {
  QuotaManager({
    required RouterConfig Function() config,
    required this.store,
    this.clock = const PacificClock(),
  }) : _config = config;

  final RouterConfig Function() _config;
  final StateStore store;
  final PacificClock clock;

  final Map<String, BucketState> _buckets = {};
  final Map<String, ModelState> _models = {};
  int? _projectBlockedUntilMs;
  String? _projectReason;
  int _nextReservationId = 1;
  bool _dirty = false;
  bool _loaded = false;
  Future<void> _flushChain = Future.value();
  String? _lastError;

  /// 最近一次持久化失败的原因；非 null 时应用应停止新准入。
  String? get persistError => _lastError;

  String get currentDay => clock.dayKey(DateTime.now().toUtc());

  Future<void> load() async {
    final raw = await store.read();
    _buckets.clear();
    _models.clear();
    if (raw == null) {
      _loaded = true;
      return;
    }
    final projectRef = raw['projectRef']?.toString();
    if (projectRef != null && projectRef != _config().projectRef) {
      // 换了项目：不沿用旧项目状态（内核文档 §9.3）。
      _loaded = true;
      return;
    }
    final buckets = raw['buckets'];
    if (buckets is Map) {
      for (final e in buckets.entries) {
        if (e.value is Map) {
          final state = BucketState.fromJson(
              (e.value as Map).cast<String, Object?>());
          _buckets[e.key.toString()] = state;
        }
      }
    }
    final models = raw['models'];
    if (models is Map) {
      for (final e in models.entries) {
        if (e.value is Map) {
          _models[e.key.toString()] =
              ModelState.fromJson((e.value as Map).cast<String, Object?>());
        }
      }
    }
    _projectBlockedUntilMs = (raw['projectBlockedUntilMs'] as num?)?.toInt();
    _projectReason = raw['projectReason']?.toString();
    _loaded = true;
    rollover(DateTime.now().toUtc());
  }

  /// 跨日重置：只清日桶与"疑似日耗尽"，分钟窗口与权限状态保留。
  void rollover(DateTime now) {
    final day = clock.dayKey(now.toUtc());
    for (final b in _buckets.values) {
      if (b.dimension == QuotaDimension.rpd && b.quotaDay != day) {
        b.quotaDay = day;
        b.localAttempts = 0;
        b.successfulCompletions = 0;
        b.uncertainAttempts = 0;
        b.suspectedBlockedUntilMs = null;
        b.lastProbeMs = null;
        if (b.confirmedBlockedUntilMs != null &&
            b.confirmedBlockedUntilMs! <=
                now.toUtc().millisecondsSinceEpoch) {
          b.confirmedBlockedUntilMs = null;
          b.reason = null;
          b.evidence = null;
        }
      }
    }
  }

  BucketState _bucketFor(String group, QuotaDimension dim, DateTime now) {
    final key = '$group:${dim.name}';
    final limit = _config().quotaGroups[group]?.limitFor(dim);
    final state = _buckets.putIfAbsent(
      key,
      () => BucketState(
        group: group,
        dimension: dim,
        limit: limit,
        quotaDay: clock.dayKey(now.toUtc()),
      ),
    );
    state.limit = limit;
    return state;
  }

  ModelState _modelState(String modelId) =>
      _models.putIfAbsent(modelId, ModelState.new);

  /// 检查是否可以发往该模型；返回 null 表示可以。
  SkipInfo? check(
    String modelId,
    int estTokens,
    DateTime now, {
    bool allowProbe = false,
  }) {
    final nowMs = now.toUtc().millisecondsSinceEpoch;
    rollover(now);

    final projectBlocked = _projectBlockedUntilMs;
    if (projectBlocked != null && nowMs < projectBlocked) {
      return SkipInfo('project_blocked',
          blockedUntilMs: projectBlocked, detail: _projectReason);
    }

    final model = _modelState(modelId);
    if (model.blockedUntilMs != null && nowMs < model.blockedUntilMs!) {
      return SkipInfo('model_blocked',
          blockedUntilMs: model.blockedUntilMs, detail: model.reason);
    }
    if (model.transientBlockedUntilMs != null &&
        nowMs < model.transientBlockedUntilMs!) {
      return SkipInfo('transient_cooldown',
          blockedUntilMs: model.transientBlockedUntilMs);
    }

    final spec = _config().models[modelId];
    if (spec == null || !spec.enabled) {
      return const SkipInfo('model_disabled');
    }

    for (final entry in spec.quotaGroups.entries) {
      final bucket = _bucketFor(entry.value, entry.key, now);
      final skip = _checkBucket(bucket, estTokens, nowMs, allowProbe: allowProbe);
      if (skip != null) return skip;
    }
    return null;
  }

  SkipInfo? _checkBucket(
    BucketState b,
    int estTokens,
    int nowMs, {
    required bool allowProbe,
  }) {
    final limit = b.limit;
    if (limit == null) return null; // 未知限额：按上游反馈运行
    if (limit == 0) {
      return SkipInfo('quota_unavailable', detail: b.group);
    }

    final confirmed = b.confirmedBlockedUntilMs;
    if (confirmed != null && nowMs < confirmed) {
      return SkipInfo('confirmed_blocked',
          blockedUntilMs: confirmed, detail: b.reason ?? b.group);
    }
    final suspected = b.suspectedBlockedUntilMs;
    if (suspected != null && nowMs < suspected) {
      return SkipInfo('cooldown',
          blockedUntilMs: suspected, detail: b.group);
    }

    switch (b.dimension) {
      case QuotaDimension.rpm:
        _pruneMinute(b, nowMs);
        if (b.minuteEvents.length >= limit) {
          final oldest = b.minuteEvents.first;
          return SkipInfo('rpm_limited', blockedUntilMs: oldest + 60000);
        }
      case QuotaDimension.tpm:
        _pruneMinute(b, nowMs);
        var used = 0;
        for (final e in b.tokenEvents) {
          used += e.$2;
        }
        if (used + estTokens > limit) {
          final oldest = b.tokenEvents.isEmpty ? nowMs : b.tokenEvents.first.$1;
          return SkipInfo('tpm_limited', blockedUntilMs: oldest + 60000);
        }
      case QuotaDimension.rpd:
        if (b.localAttempts >= limit) {
          final probeMs = b.lastProbeMs;
          final interval = _config().policy.quotaProbeIntervalMs;
          final canProbe = allowProbe &&
              (probeMs == null || nowMs - probeMs >= interval);
          if (!canProbe) {
            return SkipInfo('daily_suspected',
                blockedUntilMs: clock
                    .nextMidnightUtc(DateTime.fromMillisecondsSinceEpoch(nowMs,
                        isUtc: true))
                    .millisecondsSinceEpoch);
          }
        }
    }
    return null;
  }

  void _pruneMinute(BucketState b, int nowMs) {
    final cutoff = nowMs - 60000;
    b.minuteEvents.removeWhere((t) => t < cutoff);
    b.tokenEvents.removeWhere((e) => e.$1 < cutoff);
  }

  /// 原子预留：检查并在同一临界区内记账。返回 null 表示被跳过。
  ///
  /// [allowProbe] 为 true 时，本地日计数已达上限的桶允许一次低频验证，
  /// 避免一次错误的本地估算把整个模型锁死一天（内核文档 §9.1）。
  Reservation? reserve(
    String modelId,
    int estTokens,
    DateTime now, {
    bool allowProbe = false,
  }) {
    final skip = check(modelId, estTokens, now, allowProbe: allowProbe);
    if (skip != null) return null;

    final spec = _config().models[modelId]!;
    final nowMs = now.toUtc().millisecondsSinceEpoch;
    final keys = <String>[];

    for (final entry in spec.quotaGroups.entries) {
      final b = _bucketFor(entry.value, entry.key, now);
      keys.add(b.key);
      b.minuteEvents.add(nowMs);
      if (entry.key == QuotaDimension.tpm) {
        b.tokenEvents.add((nowMs, estTokens));
      }
      if (entry.key == QuotaDimension.rpd) {
        b.localAttempts++;
        if (b.localAttempts > (b.limit ?? 0) &&
            b.limit != null &&
            b.lastProbeMs == null) {
          b.lastProbeMs = nowMs;
        }
      }
    }
    _modelState(modelId).lastAttemptMs = nowMs;
    _dirty = true;
    scheduleFlush();
    return Reservation(
      reservationId: _nextReservationId++,
      modelId: modelId,
      bucketKeys: keys,
      estTokens: estTokens,
      quotaDay: clock.dayKey(now.toUtc()),
      atMs: nowMs,
    );
  }

  /// 确定未发送：释放预留（目前只在本地未发出时调用，保留接口）。
  void releaseUnsent(Reservation r) {
    if (r.released || r.committed) return;
    r.released = true;
    final nowMs = DateTime.now().toUtc().millisecondsSinceEpoch;
    for (final key in r.bucketKeys) {
      final b = _buckets[key];
      if (b == null) continue;
      b.minuteEvents.removeLastWhere((_) => true, orElse: () => 0);
      if (b.dimension == QuotaDimension.rpd && b.localAttempts > 0) {
        b.localAttempts--;
      }
      b.tokenEvents.removeWhere((e) => e.$1 >= nowMs - 1000);
    }
    _dirty = true;
  }

  /// 发送成功且已收到首个合法事件。
  void markSuccess(Reservation r) {
    if (r.settled) return;
    r.settled = true;
    for (final key in r.bucketKeys) {
      _buckets[key]?.successfulCompletions += 1;
    }
    final m = _modelState(r.modelId);
    m.consecutiveTransient = 0;
    m.transientBlockedUntilMs = null;
    _dirty = true;
    scheduleFlush();
  }

  /// 已发送但结果不确定（超时、取消、连接中断）。
  void markUncertain(Reservation r) {
    if (r.settled) return;
    r.settled = true;
    for (final key in r.bucketKeys) {
      _buckets[key]?.uncertainAttempts += 1;
    }
    _dirty = true;
    scheduleFlush();
  }

  /// 应用一次失败的上游证据。
  void applyFailure(
    String modelId,
    UpstreamFailure failure,
    DateTime now, {
    Reservation? reservation,
  }) {
    final nowMs = now.toUtc().millisecondsSinceEpoch;
    final policy = _config().policy;
    final spec = _config().models[modelId];
    final retryMs = failure.retryAfterSeconds == null
        ? null
        : nowMs + failure.retryAfterSeconds! * 1000;

    switch (failure.kind) {
      case FailureKind.rpmLimited:
      case FailureKind.tpmLimited:
        final dim = failure.dimension;
        if (dim != null && spec != null) {
          for (final entry in spec.quotaGroups.entries) {
            if (entry.key != dim) continue;
            final b = _bucketFor(entry.value, dim, now);
            final until = retryMs ?? nowMs + 60000;
            b.suspectedBlockedUntilMs = until;
            b.reason = failure.kind.name;
            b.evidence = failure.message;
            b.confidence = 'upstream';
          }
        } else {
          _modelState(modelId).blockedUntilMs = retryMs ?? nowMs + 60000;
          _modelState(modelId).reason = failure.kind.name;
        }
      case FailureKind.dailyExhausted:
        final midnight = clock
            .nextMidnightUtc(now)
            .millisecondsSinceEpoch;
        if (spec != null) {
          for (final entry in spec.quotaGroups.entries) {
            if (entry.key != QuotaDimension.rpd) continue;
            final b = _bucketFor(entry.value, entry.key, now);
            final until = retryMs ?? midnight;
            b.confirmedBlockedUntilMs =
                until > midnight ? until : midnight;
            b.reason = 'dailyExhausted';
            b.evidence = failure.message;
            b.confidence = 'upstream';
          }
        }
      case FailureKind.quotaUnavailable:
        if (spec != null) {
          for (final entry in spec.quotaGroups.entries) {
            final b = _bucketFor(entry.value, entry.key, now);
            b.confirmedBlockedUntilMs = clock
                .nextMidnightUtc(now)
                .millisecondsSinceEpoch;
            b.reason = 'quotaUnavailable';
            b.evidence = failure.message;
            b.confidence = 'upstream';
          }
        }
      case FailureKind.unknown429:
        _modelState(modelId).blockedUntilMs =
            retryMs ?? nowMs + policy.unknown429CooldownMs;
        _modelState(modelId).reason = 'unknown429';
      case FailureKind.transient:
        final m = _modelState(modelId);
        m.consecutiveTransient += 1;
        if (m.consecutiveTransient >= 3) {
          m.transientBlockedUntilMs = nowMs + 30000;
          m.consecutiveTransient = 0;
        }
      case FailureKind.modelUnavailable:
        _modelState(modelId).blockedUntilMs = nowMs + 3600000;
        _modelState(modelId).reason = 'modelUnavailable';
      case FailureKind.modelAccessDenied:
        _modelState(modelId).blockedUntilMs = nowMs + 3600000;
        _modelState(modelId).reason = 'modelAccessDenied';
      case FailureKind.upstreamAccessError:
      case FailureKind.upstreamBillingError:
      case FailureKind.endpointMisconfigured:
        _projectBlockedUntilMs = nowMs + 60000;
        _projectReason = failure.kind.name;
      case FailureKind.repairableParam:
      case FailureKind.invalidRequest:
      case FailureKind.blocked:
      case FailureKind.upstreamProtocolError:
        break;
    }

    if (reservation != null && !reservation.settled) {
      // 上游已返回明确错误：这次请求确实发出去了，按不确定保留计数。
      markUncertain(reservation);
    }
    _dirty = true;
    scheduleFlush();
  }

  /// 记录上游用 400 教会的"该模型不支持这些参数"。
  void learnStrips(String modelId, Iterable<String> params) {
    if (params.isEmpty) return;
    final learned = _modelState(modelId).learnedStrips;
    final before = learned.length;
    learned.addAll(params);
    if (learned.length != before) {
      _dirty = true;
      scheduleFlush();
    }
  }

  /// 该模型已确认不支持的参数（发送前剥离）。
  Set<String> learnedStripsFor(String modelId) =>
      _modelState(modelId).learnedStrips;

  /// 手动清除本地估算（上游确认的封锁不清）。
  bool clearLocalEstimate(String bucketId) {
    final b = _buckets[bucketId];
    if (b == null) return false;
    if (b.confirmedBlockedUntilMs != null) return false;
    b.suspectedBlockedUntilMs = null;
    b.localAttempts = 0;
    b.lastProbeMs = null;
    b.minuteEvents.clear();
    b.tokenEvents.clear();
    b.reason = null;
    b.evidence = null;
    b.confidence = null;
    _dirty = true;
    scheduleFlush();
    return true;
  }

  /// 清空所有本地估算（保留上游确认的封锁）。
  void clearAllLocalEstimates() {
    for (final b in _buckets.values) {
      if (b.confirmedBlockedUntilMs != null) continue;
      b.suspectedBlockedUntilMs = null;
      b.localAttempts = 0;
      b.lastProbeMs = null;
      b.minuteEvents.clear();
      b.tokenEvents.clear();
      b.reason = null;
      b.evidence = null;
      b.confidence = null;
    }
    _models.clear();
    _projectBlockedUntilMs = null;
    _projectReason = null;
    _dirty = true;
    scheduleFlush();
  }

  Map<String, Object?> snapshot(DateTime now) {
    final nowMs = now.toUtc().millisecondsSinceEpoch;
    rollover(now);
    final buckets = <String, Object?>{};
    for (final b in _buckets.values) {
      _pruneMinute(b, nowMs);
      var tpmUsed = 0;
      for (final e in b.tokenEvents) {
        tpmUsed += e.$2;
      }
      buckets[b.key] = {
        ...b.toJson(),
        'minuteUsed': b.minuteEvents.length,
        'tpmUsed': tpmUsed,
        'blockedUntil': _isoOrNull(b.confirmedBlockedUntilMs ??
            b.suspectedBlockedUntilMs),
        'confirmed': b.confirmedBlockedUntilMs != null &&
            nowMs < (b.confirmedBlockedUntilMs ?? 0),
      };
    }
    final models = <String, Object?>{};
    for (final e in _models.entries) {
      final m = e.value;
      final blocked = <int>[
        if (m.blockedUntilMs != null) m.blockedUntilMs!,
        if (m.transientBlockedUntilMs != null) m.transientBlockedUntilMs!,
      ]..sort();
      models[e.key] = {
        ...m.toJson(),
        'blockedUntil': blocked.isEmpty ? null : _isoOrNull(blocked.last),
        'blockedReason': m.reason,
      };
    }
    return {
      'projectBlockedUntil': _isoOrNull(_projectBlockedUntilMs),
      'projectReason': _projectReason,
      'quotaDay': clock.dayKey(now.toUtc()),
      'nextResetAt':
          clock.nextMidnightUtc(now).toIso8601String(),
      'buckets': buckets,
      'models': models,
      'persistError': _lastError,
    };
  }

  static String? _isoOrNull(int? ms) => ms == null
      ? null
      : DateTime.fromMillisecondsSinceEpoch(ms, isUtc: true).toIso8601String();

  Map<String, Object?> toJson() => {
        'schemaVersion': 2,
        'projectRef': _config().projectRef,
        'savedAt': DateTime.now().toUtc().toIso8601String(),
        'quotaDay': clock.dayKey(DateTime.now().toUtc()),
        'buckets': {for (final e in _buckets.entries) e.key: e.value.toJson()},
        'models': {for (final e in _models.entries) e.key: e.value.toJson()},
        'projectBlockedUntilMs': _projectBlockedUntilMs,
        'projectReason': _projectReason,
      };

  void scheduleFlush() {
    if (!_loaded) return;
    _flushChain = _flushChain.then((_) async {
      if (!_dirty) return;
      _dirty = false;
      try {
        await store.write(toJson());
        _lastError = null;
      } catch (e) {
        _lastError = '状态写盘失败：$e';
        _dirty = true;
      }
    });
  }

  Future<void> flushNow() async {
    _dirty = true;
    scheduleFlush();
    await _flushChain;
  }
}

extension _ListExt<T> on List<T> {
  void removeLastWhere(bool Function(T) test, {required T Function() orElse}) {
    for (var i = length - 1; i >= 0; i--) {
      if (test(this[i])) {
        removeAt(i);
        return;
      }
    }
    orElse();
  }
}

/// 状态文件损坏时的降级：保留原文件、返回空状态，由调用方提示运维。
Map<String, Object?>? decodeStateOrNull(String raw) {
  try {
    final decoded = jsonDecode(raw);
    return decoded is Map ? decoded.cast<String, Object?>() : null;
  } catch (_) {
    return null;
  }
}
