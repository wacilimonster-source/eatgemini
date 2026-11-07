/// 上游错误分类。
///
/// 规则来源：内核文档 §7。分类顺序固定为
/// HTTP envelope → 结构化 details/metric → 已核验文案规则 → unknown，
/// 任何一层拿不到证据就落到更保守的类别，不凭单个单词猜日额度。
library;

import 'dart:convert';

import 'config.dart';

enum FailureKind {
  rpmLimited,
  tpmLimited,
  dailyExhausted,
  quotaUnavailable,
  unknown429,
  transient,
  modelUnavailable,
  endpointMisconfigured,
  upstreamAccessError,
  modelAccessDenied,
  upstreamBillingError,
  repairableParam,
  invalidRequest,
  blocked,
  upstreamProtocolError,
}

extension FailureKindX on FailureKind {
  /// 是否值得换下一个候选模型。
  bool get tryNextModel => switch (this) {
        FailureKind.rpmLimited ||
        FailureKind.tpmLimited ||
        FailureKind.dailyExhausted ||
        FailureKind.quotaUnavailable ||
        FailureKind.unknown429 ||
        FailureKind.transient ||
        FailureKind.modelUnavailable ||
        FailureKind.modelAccessDenied ||
        FailureKind.repairableParam ||
        FailureKind.upstreamProtocolError =>
          true,
        _ => false,
      };

  /// 是否属于项目/端点级问题（不再逐模型试）。
  bool get scopeWide => this == FailureKind.upstreamAccessError ||
      this == FailureKind.upstreamBillingError ||
      this == FailureKind.endpointMisconfigured;

  String get code => name;
}

class UpstreamFailure {
  const UpstreamFailure({
    required this.kind,
    required this.status,
    required this.message,
    this.code,
    this.dimension,
    this.param,
    this.retryAfterSeconds,
    this.quotaLimitZero = false,
  });

  final FailureKind kind;
  final int status;
  final String message;
  final String? code;
  final QuotaDimension? dimension;
  final String? param;
  final int? retryAfterSeconds;
  final bool quotaLimitZero;
}

/// 可从错误里得到的恢复时间（秒）。`null` 表示未知。
int? parseRetryAfterSeconds(Map<String, String> headers) {
  final raw = headers['retry-after'] ?? headers['Retry-After'];
  if (raw == null) return null;
  final seconds = int.tryParse(raw.trim());
  if (seconds != null) return seconds < 0 ? 0 : seconds;
  try {
    final at = DateTime.parse(raw);
    final diff = at.toUtc().difference(DateTime.now().toUtc()).inSeconds;
    return diff > 0 ? diff : 0;
  } catch (_) {
    return null;
  }
}

/// 分类一个非 2xx 响应。
///
/// [headers] 的键统一小写；[body] 为已解码的原始文本（可能为空或 HTML）。
UpstreamFailure classifyUpstreamError({
  required int status,
  required Map<String, String> headers,
  required String body,
}) {
  final envelope = _tryParseEnvelope(body);
  final message = envelope.message;
  final lower = message.toLowerCase();
  final retryAfter = parseRetryAfterSeconds(headers);

  if (status == 429) {
    final dim = _dimensionFromEvidence(envelope);
    if (envelope.limitZero) {
      return UpstreamFailure(
        kind: FailureKind.quotaUnavailable,
        status: status,
        message: '该项目或模型没有可用配额',
        code: envelope.code,
        retryAfterSeconds: retryAfter,
      );
    }
    if (dim != null) {
      return UpstreamFailure(
        kind: dim == QuotaDimension.rpd
            ? FailureKind.dailyExhausted
            : dim == QuotaDimension.rpm
                ? FailureKind.rpmLimited
                : FailureKind.tpmLimited,
        status: status,
        message: message,
        code: envelope.code,
        dimension: dim,
        retryAfterSeconds: retryAfter,
      );
    }
    if (lower.contains('quota') ||
        lower.contains('resource_exhausted') ||
        envelope.code?.toUpperCase() == 'RESOURCE_EXHAUSTED') {
      // 只有"配额"字样、没有维度证据：短冷却，不封到次日。
      return UpstreamFailure(
        kind: FailureKind.unknown429,
        status: status,
        message: message,
        code: envelope.code,
        retryAfterSeconds: retryAfter,
      );
    }
    return UpstreamFailure(
      kind: FailureKind.unknown429,
      status: status,
      message: message,
      code: envelope.code,
      retryAfterSeconds: retryAfter,
    );
  }

  if (status == 402) {
    return UpstreamFailure(
      kind: FailureKind.upstreamBillingError,
      status: status,
      message: message,
      code: envelope.code,
      retryAfterSeconds: retryAfter,
    );
  }

  if (status == 401) {
    return UpstreamFailure(
      kind: FailureKind.upstreamAccessError,
      status: status,
      message: message,
      code: envelope.code,
    );
  }

  if (status == 403) {
    final modelSpecific = lower.contains('model') &&
        (lower.contains('not have access') ||
            lower.contains('permission') ||
            lower.contains('not supported') ||
            lower.contains('does not support'));
    return UpstreamFailure(
      kind: modelSpecific
          ? FailureKind.modelAccessDenied
          : FailureKind.upstreamAccessError,
      status: status,
      message: message,
      code: envelope.code,
    );
  }

  if (status == 404) {
    if (body.trim().isEmpty || _looksLikeHtml(body)) {
      return const UpstreamFailure(
        kind: FailureKind.endpointMisconfigured,
        status: 404,
        message: '上游地址返回了网页而不是 API 响应，请检查 baseUrl',
      );
    }
    if (lower.contains('model')) {
      return UpstreamFailure(
        kind: FailureKind.modelUnavailable,
        status: status,
        message: message,
        code: envelope.code,
      );
    }
    return UpstreamFailure(
      kind: FailureKind.invalidRequest,
      status: status,
      message: message,
      code: envelope.code,
    );
  }

  if (status == 400 || status == 422) {
    if (lower.contains('safety') ||
        lower.contains('blocked') ||
        lower.contains('recitation') ||
        lower.contains('content_policy')) {
      return UpstreamFailure(
        kind: FailureKind.blocked,
        status: status,
        message: message,
        code: envelope.code,
      );
    }
    if (lower.contains('penalty')) {
      // Gemini 3 系对 penalty 直接 400（"Penalty is not enabled for this
      // model"），错误体没有 param 字段；用合成的 'penalty' 组键，
      // 由选路层剥掉 frequency/presence 两个参数后重试。
      return UpstreamFailure(
        kind: FailureKind.repairableParam,
        status: status,
        message: message,
        code: envelope.code,
        param: 'penalty',
      );
    }
    if (lower.contains('context') &&
        (lower.contains('too long') ||
            lower.contains('exceed') ||
            lower.contains('length'))) {
      return UpstreamFailure(
        kind: FailureKind.invalidRequest,
        status: status,
        message: '输入超过了模型上下文上限',
        code: 'context_length_exceeded',
      );
    }
    final param = envelope.param;
    if (param != null && _repairableParams.contains(param)) {
      return UpstreamFailure(
        kind: FailureKind.repairableParam,
        status: status,
        message: message,
        code: envelope.code,
        param: param,
      );
    }
    return UpstreamFailure(
      kind: FailureKind.invalidRequest,
      status: status,
      message: message,
      code: envelope.code,
      param: param,
    );
  }

  if (status == 408 || status >= 500) {
    return UpstreamFailure(
      kind: FailureKind.transient,
      status: status,
      message: message,
      code: envelope.code,
      retryAfterSeconds: retryAfter,
    );
  }

  if (status == 413) {
    return UpstreamFailure(
      kind: FailureKind.invalidRequest,
      status: status,
      message: '请求体超过上游大小限制',
      code: 'request_too_large',
    );
  }

  return UpstreamFailure(
    kind: FailureKind.upstreamProtocolError,
    status: status,
    message: message.isEmpty ? 'HTTP $status' : message,
    code: envelope.code,
  );
}

const Set<String> _repairableParams = {
  'temperature',
  'top_p',
  'top_k',
  'max_tokens',
  'max_completion_tokens',
  'stop',
  'reasoning_effort',
  'seed',
  'frequency_penalty',
  'presence_penalty',
};

class _Envelope {
  const _Envelope({
    this.message = '',
    this.code,
    this.param,
    this.dimensionEvidence = '',
    this.limitZero = false,
  });

  final String message;
  final String? code;
  final String? param;
  final String dimensionEvidence;
  final bool limitZero;
}

_Envelope _tryParseEnvelope(String body) {
  if (body.trim().isEmpty) return const _Envelope();
  Object? decoded;
  try {
    decoded = jsonDecode(body);
  } catch (_) {
    return _Envelope(message: _clip(body));
  }
  if (decoded is! Map) return _Envelope(message: _clip(body));
  final error = decoded['error'];
  final map = error is Map ? error.cast<String, Object?>() : decoded;
  final message = (map['message'] ?? map['msg'] ?? '').toString();
  final code = map['code']?.toString() ?? map['status']?.toString();
  final param = map['param']?.toString();
  final evidence = StringBuffer();
  var limitZero = false;

  void visit(Object? node, int depth) {
    if (depth > 6 || node == null) return;
    if (node is Map) {
      for (final e in node.entries) {
        final k = e.key.toString().toLowerCase();
        final v = e.value;
        if (k == 'limit' && v is num && v == 0) limitZero = true;
        if (v is String) {
          const evidenceKeys = {
            'quotaid',
            'metric',
            'quota_metric',
            'reason',
            'description',
            'domain',
          };
          if (evidenceKeys.contains(k)) evidence.writeln(v);
        }
        visit(v, depth + 1);
      }
    } else if (node is List) {
      for (final item in node) {
        visit(item, depth + 1);
      }
    }
  }

  visit(map['details'], 0);
  evidence.writeln(message);
  return _Envelope(
    message: message,
    code: code,
    param: param,
    dimensionEvidence: evidence.toString().toLowerCase(),
    limitZero: limitZero,
  );
}

QuotaDimension? _dimensionFromEvidence(_Envelope e) {
  final text = e.dimensionEvidence;
  if (text.isEmpty) return null;
  // 输入 token 的每分钟限制优先，避免把 "per minute" 误判成请求数。
  if (text.contains('input_token') ||
      text.contains('inputtoken') ||
      text.contains('tokens per minute') ||
      text.contains('tpm')) {
    return QuotaDimension.tpm;
  }
  if (text.contains('perday') ||
      text.contains('per day') ||
      text.contains('per_day') ||
      text.contains('daily') ||
      text.contains('requests per day')) {
    return QuotaDimension.rpd;
  }
  if (text.contains('perminute') ||
      text.contains('per minute') ||
      text.contains('per_minute') ||
      text.contains('requests per minute') ||
      text.contains('rpm')) {
    return QuotaDimension.rpm;
  }
  return null;
}

bool _looksLikeHtml(String body) {
  final t = body.trimLeft().toLowerCase();
  return t.startsWith('<!doctype') || t.startsWith('<html') || t.startsWith('<');
}

String _clip(String s) {
  final t = s.trim().replaceAll(RegExp(r'\s+'), ' ');
  return t.length > 300 ? '${t.substring(0, 300)}…' : t;
}
