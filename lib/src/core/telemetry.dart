/// 请求摘要与事件：网关 → 应用层的唯一数据出口。
///
/// 只包含元数据，绝不含 prompt 或回复正文（内核文档 §13.3）。
library;

import '../core/router_engine.dart';

class RequestSummary {
  RequestSummary({
    required this.requestId,
    required this.clientId,
    required this.requestedModel,
    required this.stream,
    required this.startedAt,
    required this.outcome,
    required this.httpStatus,
    required this.upstreamAttempts,
    required this.fellBack,
    required this.cancelled,
    required this.totalMs,
    this.profile,
    this.servedModel,
    this.errorCode,
    this.streamErrorCode,
    this.routeDiagnostics,
    this.firstEventMs,
    this.remoteIp,
    this.transforms = const [],
    this.skipped = const [],
    this.usage,
  });

  final String requestId;
  final String clientId;
  final String requestedModel;
  final String? profile;
  final String? servedModel;
  final bool stream;
  final DateTime startedAt;
  final String outcome;
  final int httpStatus;
  final String? errorCode;

  /// 提交后断流：已返回 200 并转发途中，上游流不完整或出错时下发的错误帧码。
  final String? streamErrorCode;
  final Map<String, Object?>? routeDiagnostics;
  final int upstreamAttempts;
  final bool fellBack;
  final bool cancelled;
  final int totalMs;
  final int? firstEventMs;
  final String? remoteIp;
  final List<String> transforms;
  final List<String> skipped;
  final Map<String, Object?>? usage;

  Map<String, Object?> toJson() => {
        'requestId': requestId,
        'client': clientId,
        if (remoteIp != null) 'remoteIp': remoteIp,
        'startedAt': startedAt.toUtc().toIso8601String(),
        'requestedModel': requestedModel,
        if (profile != null) 'profile': profile,
        'stream': stream,
        'outcome': outcome,
        'httpStatus': httpStatus,
        if (errorCode != null) 'errorCode': errorCode,
        if (streamErrorCode != null) 'streamErrorCode': streamErrorCode,
        if (routeDiagnostics != null) 'routeDiagnostics': routeDiagnostics,
        if (servedModel != null) 'servedModel': servedModel,
        'fellBack': fellBack,
        'attempts': upstreamAttempts,
        'firstEventMs': firstEventMs,
        'totalMs': totalMs,
        if (usage != null) 'usage': usage,
        'transforms': transforms,
        'skipped': skipped,
        'cancelled': cancelled,
      };
}

/// 网关向应用层广播事件（控制台 SSE 的输入）。
typedef EventSink = void Function(String event, Map<String, Object?> data);

/// 令牌 → clientId。令牌比较必须是常量时间，避免时序侧信道。
abstract interface class TokenDirectory {
  String? clientIdForToken(String token);
}

class StaticTokenDirectory implements TokenDirectory {
  StaticTokenDirectory(this._tokens);

  /// clientId → token
  final Map<String, String> _tokens;

  @override
  String? clientIdForToken(String token) {
    String? matched;
    for (final e in _tokens.entries) {
      final a = e.value;
      final b = token;
      var localDiff = a.length ^ b.length;
      final len = a.length > b.length ? a.length : b.length;
      for (var i = 0; i < len; i++) {
        final ca = i < a.length ? a.codeUnitAt(i) : 0;
        final cb = i < b.length ? b.codeUnitAt(i) : 0;
        localDiff |= ca ^ cb;
      }
      // 每个令牌独立判断：不能把其他条目的差异累加进来（G12）。
      if (localDiff == 0) matched = e.key;
    }
    return matched;
  }
}

class AppStatus {
  const AppStatus(this.state, [this.reason]);

  /// starting / needs_key / config_error / port_conflict / ready / degraded /
  /// persist_error / stopping
  final String state;
  final String? reason;
}

/// 每个客户端的尝试事件流（控制台实时刷新用）。
typedef AttemptSink = void Function(AttemptEvent event);

/// 取消：把「客户端断开」变成引擎能感知的信号。
class RequestAbortRegistry {
  final Map<String, AbortToken> _tokens = {};

  AbortToken register(String requestId) => _tokens[requestId] = AbortToken();

  void abort(String requestId) => _tokens.remove(requestId)?.abort();

  void unregister(String requestId) => _tokens.remove(requestId);
}
