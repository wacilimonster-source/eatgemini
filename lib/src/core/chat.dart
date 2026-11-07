/// OpenAI Chat Completions 请求的子集解析与参数归一化。
///
/// 规则来源：内核文档 §12、§11.1 的 `tavern_text` 兼容策略。
/// 原则：未知字段拒绝；明确的"中性值"在发送前剥离；真实能力请求本地 400，
/// 不静默丢弃、不跨模型假装实现。
library;

/// 本地拒绝（不消耗上游请求）。
class RequestRejected implements Exception {
  RequestRejected({
    required this.status,
    required this.code,
    required this.message,
    this.param,
  });

  final int status;
  final String code;
  final String message;
  final String? param;

  @override
  String toString() => message;
}

class ChatMessage {
  const ChatMessage({required this.role, required this.content, this.name});

  final String role;
  final String content;
  final String? name;

  Map<String, Object?> toUpstreamJson() => {
        'role': role,
        'content': content,
        if (name != null && name!.isNotEmpty) 'name': name,
      };
}

class ChatRequest {
  const ChatRequest({
    required this.model,
    required this.messages,
    required this.stream,
    required this.includeUsage,
    this.temperature,
    this.topP,
    this.maxTokens,
    this.stop,
    this.reasoningEffort,
    this.frequencyPenalty,
    this.presencePenalty,
    this.topK,
    this.seed,
  });

  final String model;
  final List<ChatMessage> messages;
  final bool stream;
  final bool includeUsage;
  final double? temperature;
  final double? topP;
  final int? maxTokens;
  final List<String>? stop;
  final String? reasoningEffort;
  final double? frequencyPenalty;
  final double? presencePenalty;
  final int? topK;
  final int? seed;

  /// 估算输入 token（中文按 1 字符 ≈ 1 token，ASCII 按 4 字符 ≈ 1 token）。
  int get estimatedInputTokens {
    var n = 0;
    for (final m in messages) {
      n += estimateTokens(m.content);
      n += 4; // 角色与分隔的固定开销
    }
    return n;
  }
}

/// 保守 token 估算：只用于 TPM 预留与警告，不作为硬性拒绝依据。
int estimateTokens(String text) {
  var ascii = 0;
  var wide = 0;
  for (final rune in text.runes) {
    if (rune < 0x80) {
      ascii++;
    } else {
      wide++;
    }
  }
  return (ascii / 4).ceil() + wide;
}

/// 解析请求体。返回值只包含网关会向候选模型转发的字段。
ChatRequest parseChatRequest(Map<String, Object?> body) {
  const known = {
    'model',
    'messages',
    'stream',
    'stream_options',
    'temperature',
    'top_p',
    'max_tokens',
    'max_completion_tokens',
    'stop',
    'n',
    'frequency_penalty',
    'presence_penalty',
    'top_k',
    'seed',
    'logit_bias',
    'logprobs',
    'top_logprobs',
    'user',
    'metadata',
    'response_format',
    'tools',
    'tool_choice',
    'parallel_tool_calls',
    'reasoning_effort',
  };

  for (final key in body.keys) {
    if (!known.contains(key)) {
      throw RequestRejected(
        status: 400,
        code: 'unsupported_parameter',
        message: '不支持的请求字段「$key」。GEMINI网关 只接受文本对话所需的标准字段',
        param: key,
      );
    }
  }

  final model = body['model'];
  if (model is! String || model.trim().isEmpty) {
    throw RequestRejected(
      status: 400,
      code: 'invalid_request',
      message: '缺少 model 字段',
      param: 'model',
    );
  }

  final rawMessages = body['messages'];
  if (rawMessages is! List || rawMessages.isEmpty) {
    throw RequestRejected(
      status: 400,
      code: 'invalid_request',
      message: 'messages 必须是非空数组',
      param: 'messages',
    );
  }
  final messages = <ChatMessage>[];
  for (var i = 0; i < rawMessages.length; i++) {
    final raw = rawMessages[i];
    if (raw is! Map) {
      throw RequestRejected(
        status: 400,
        code: 'invalid_request',
        message: 'messages[$i] 必须是对象',
        param: 'messages',
      );
    }
    final m = raw.cast<String, Object?>();
    final role = (m['role'] ?? '').toString();
    if (role != 'system' && role != 'user' && role != 'assistant') {
      throw RequestRejected(
        status: 400,
        code: 'unsupported_message_role',
        message: '不支持的消息角色「$role」，首期只支持 system / user / assistant',
        param: 'messages[$i].role',
      );
    }
    final content = _contentText(m['content'], i);
    messages.add(ChatMessage(
      role: role,
      content: content,
      name: (m['name'] is String && (m['name'] as String).trim().isNotEmpty)
          ? (m['name'] as String).trim()
          : null,
    ));
  }

  final n = _asInt(body['n']);
  if (n != null && n > 1) {
    throw RequestRejected(
      status: 400,
      code: 'unsupported_parameter',
      message: '不支持多候选生成（n > 1），请在客户端关闭后重试',
      param: 'n',
    );
  }

  final stream = body['stream'] == true;
  var includeUsage = false;
  final streamOptions = body['stream_options'];
  if (streamOptions is Map && streamOptions['include_usage'] == true) {
    includeUsage = true;
  }

  final maxTokens = _positiveInt(
    body['max_completion_tokens'] ?? body['max_tokens'],
    'max_tokens',
  );

  final stop = _stopList(body['stop']);

  final reasoningEffort =
      (body['reasoning_effort'] is String && (body['reasoning_effort'] as String).isNotEmpty)
          ? (body['reasoning_effort'] as String)
          : null;
  if (reasoningEffort != null &&
      !const {'minimal', 'low', 'medium', 'high', 'none'}
          .contains(reasoningEffort)) {
    throw RequestRejected(
      status: 400,
      code: 'invalid_request',
      message: 'reasoning_effort 只能是 minimal / low / medium / high / none',
      param: 'reasoning_effort',
    );
  }

  _rejectUnsupportedNeutralGroups(body);

  return ChatRequest(
    model: model.trim(),
    messages: messages,
    stream: stream,
    includeUsage: includeUsage,
    temperature: _asDouble(body['temperature']),
    topP: _asDouble(body['top_p']),
    maxTokens: maxTokens,
    stop: stop,
    reasoningEffort: reasoningEffort,
    frequencyPenalty: _nonZeroDouble(body['frequency_penalty']),
    presencePenalty: _nonZeroDouble(body['presence_penalty']),
    topK: _positiveInt(body['top_k'], 'top_k'),
    seed: _asInt(body['seed']),
  );
}

/// 非文本内容、真实工具调用、真实日志概率、结构化输出：首期一律明确拒绝。
void _rejectUnsupportedNeutralGroups(Map<String, Object?> body) {
  final logitBias = body['logit_bias'];
  if (logitBias is Map && logitBias.isNotEmpty) {
    throw RequestRejected(
      status: 400,
      code: 'unsupported_parameter',
      message: '暂不支持 logit_bias（非空）',
      param: 'logit_bias',
    );
  }
  if (body['logprobs'] == true) {
    throw RequestRejected(
      status: 400,
      code: 'unsupported_parameter',
      message: '暂不支持 logprobs',
      param: 'logprobs',
    );
  }
  final topLogprobs = body['top_logprobs'];
  if (topLogprobs is num && topLogprobs > 0) {
    throw RequestRejected(
      status: 400,
      code: 'unsupported_parameter',
      message: '暂不支持 top_logprobs',
      param: 'top_logprobs',
    );
  }
  final responseFormat = body['response_format'];
  if (responseFormat is Map) {
    final type = responseFormat['type']?.toString();
    if (type != null && type != 'text') {
      throw RequestRejected(
        status: 400,
        code: 'unsupported_parameter',
        message: '暂不支持结构化输出（response_format=$type）',
        param: 'response_format',
      );
    }
  }
  final tools = body['tools'];
  final toolChoice = body['tool_choice'];
  final hasTools = tools is List && tools.isNotEmpty;
  final choiceRequestsTools = toolChoice is Map;
  final parallel = body['parallel_tool_calls'];
  if (hasTools || choiceRequestsTools) {
    throw RequestRejected(
      status: 400,
      code: 'unsupported_parameter',
      message: '暂不支持工具调用（tools / tool_choice）',
      param: hasTools ? 'tools' : 'tool_choice',
    );
  }
  if (parallel == true) {
    throw RequestRejected(
      status: 400,
      code: 'unsupported_parameter',
      message: '暂不支持 parallel_tool_calls',
      param: 'parallel_tool_calls',
    );
  }
}

String _contentText(Object? content, int index) {
  if (content == null) return '';
  if (content is String) return content;
  if (content is List) {
    final buf = StringBuffer();
    for (final part in content) {
      if (part is! Map) {
        throw RequestRejected(
          status: 400,
          code: 'unsupported_content',
          message: 'messages[$index].content 包含无法识别的片段',
          param: 'messages[$index].content',
        );
      }
      final type = part['type']?.toString();
      final text = part['text'];
      if (type == 'text' && text is String) {
        buf.write(text);
      } else {
        throw RequestRejected(
          status: 400,
          code: 'unsupported_content',
          message: '首期只支持纯文本消息，不支持 content 片段类型「${type ?? 'unknown'}」'
              '（图片、音频、文件等）',
          param: 'messages[$index].content',
        );
      }
    }
    return buf.toString();
  }
  throw RequestRejected(
    status: 400,
    code: 'unsupported_content',
    message: 'messages[$index].content 必须是字符串或文本片段数组',
    param: 'messages[$index].content',
  );
}

List<String>? _stopList(Object? raw) {
  if (raw == null) return null;
  if (raw is String) return raw.isEmpty ? null : [raw];
  if (raw is List) {
    final list = raw
        .whereType<String>()
        .where((s) => s.isNotEmpty)
        .toList(growable: false);
    return list.isEmpty ? null : list;
  }
  throw RequestRejected(
    status: 400,
    code: 'invalid_request',
    message: 'stop 必须是字符串或字符串数组',
    param: 'stop',
  );
}

int? _positiveInt(Object? v, String param) {
  if (v == null) return null;
  if (v is! num) {
    throw RequestRejected(
      status: 400,
      code: 'invalid_request',
      message: '$param 必须是数字',
      param: param,
    );
  }
  final n = v.toInt();
  if (n <= 0) {
    throw RequestRejected(
      status: 400,
      code: 'invalid_request',
      message: '$param 必须大于 0（客户端不限制时应省略该字段）',
      param: param,
    );
  }
  return n;
}

int? _asInt(Object? v) {
  if (v == null) return null;
  if (v is num) return v.toInt();
  if (v is String) return int.tryParse(v);
  return null;
}

double? _asDouble(Object? v) {
  if (v == null) return null;
  if (v is num) return v.toDouble();
  if (v is String) return double.tryParse(v);
  return null;
}

/// 0 视为"未设置"（OpenAI 风格的惩罚项默认值）。
double? _nonZeroDouble(Object? v) {
  final d = _asDouble(v);
  if (d == null || d == 0) return null;
  return d;
}
