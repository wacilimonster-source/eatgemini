/// SSE 解析与规范化输出。
///
/// 上游按 SSE 事件边界解析（UTF-8 跨包、CRLF、多行 data、注释）；
/// 下游统一编码为一行紧凑 JSON 的 `data: {...}\n\n`（内核文档 §8）。
library;

import 'dart:convert';

class SseProtocolException implements Exception {
  SseProtocolException(this.message);

  final String message;

  @override
  String toString() => message;
}

class SseEvent {
  const SseEvent({required this.data, this.isDone = false});

  final String data;
  final bool isDone;
}

/// 把字节流解码成 SSE 事件。事件之间的空行、注释与 `event:`/`id:` 字段忽略。
Stream<SseEvent> decodeSse(
  Stream<List<int>> bytes, {
  int maxEventBytes = 0,
}) async* {
  final lines = bytes
      .transform(const Utf8Decoder(allowMalformed: true))
      .transform(const LineSplitter());
  final dataLines = <String>[];
  var size = 0;

  await for (final line in lines) {
    if (line.isEmpty) {
      if (dataLines.isEmpty) continue;
      final payload = dataLines.join('\n');
      dataLines.clear();
      size = 0;
      if (payload.trim() == '[DONE]') {
        yield const SseEvent(data: '', isDone: true);
      } else {
        yield SseEvent(data: payload);
      }
      continue;
    }
    if (line.startsWith(':')) continue; // 保活注释
    if (!line.startsWith('data:')) continue;
    var value = line.substring(5);
    if (value.startsWith(' ')) value = value.substring(1);
    if (value.trim() == '[DONE]') {
      if (dataLines.isNotEmpty) {
        yield SseEvent(data: dataLines.join('\n'));
        dataLines.clear();
        size = 0;
      }
      yield const SseEvent(data: '', isDone: true);
      continue;
    }
    dataLines.add(value);
    size += value.length;
    if (maxEventBytes > 0 && size > maxEventBytes) {
      throw SseProtocolException('上游单个 SSE 事件超过大小上限');
    }
  }

  // 上游没发结束空行就断开：把残留按已收到处理，由选路层判断是否完整。
  if (dataLines.isNotEmpty) {
    yield SseEvent(data: dataLines.join('\n'));
  }
}

String encodeDownstreamData(Map<String, Object?> payload) =>
    'data: ${jsonEncode(payload)}\n\n';

const String kDownstreamDone = 'data: [DONE]\n\n';

Map<String, Object?> sseErrorPayload({
  required String message,
  required String code,
  String? requestId,
  int? retryAfterSeconds,
}) =>
    {
      'error': {
        'message': message,
        'type': 'gateway_error',
        'code': code,
        'param': null,
        if (requestId != null) 'request_id': requestId,
        if (retryAfterSeconds != null) 'retry_after_seconds': retryAfterSeconds,
      }
    };
