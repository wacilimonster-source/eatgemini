/// 假上游：可脚本化的 Gemini OpenAI 兼容端点，用于合约测试。
///
/// 只在本机回环监听，不消耗任何真实额度。
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

class FakeUpstream {
  FakeUpstream._(this._server, this.baseUrl);

  final HttpServer _server;

  /// 以 `/` 结尾，可直接填进 upstream.baseUrl。
  final String baseUrl;

  final List<HttpRequest> received = [];
  final List<Map<String, Object?>> requests = [];

  /// 按顺序消费的响应脚本；为空时使用 [defaultHandler]。
  final List<FakeResponse> script = [];

  /// 下游 SSE 帧脚本（每个元素编码为一条 data 帧）。
  Future<void> Function(HttpRequest request, Map<String, Object?> body)?
      defaultHandler;
  Future<void> Function(HttpRequest request, Map<String, Object?> body)?
      chatHandler;

  static Future<FakeUpstream> start() async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final fake = FakeUpstream._(
      server,
      'http://127.0.0.1:${server.port}/v1beta/openai/',
    );
    unawaited(fake._loop());
    return fake;
  }

  Future<void> _loop() async {
    await for (final req in _server) {
      unawaited(_handle(req));
    }
  }

  Future<void> _handle(HttpRequest req) async {
    final raw = await utf8.decoder.bind(req).join();
    Map<String, Object?> body = {};
    if (raw.trim().isNotEmpty) {
      try {
        body = (jsonDecode(raw) as Map).cast<String, Object?>();
      } catch (_) {}
    }
    requests.add(body);
    received.add(req);

    if (req.uri.path.endsWith('/models')) {
      final handler = defaultHandler;
      if (handler != null) {
        await handler(req, body);
        return;
      }
      req.response.statusCode = 200;
      req.response.headers.contentType =
          ContentType('application', 'json', charset: 'utf-8');
      req.response.write(jsonEncode({
        'object': 'list',
        'data': [
          {'id': 'gemini-3.8-flash', 'object': 'model'},
          {'id': 'gemini-3.5-flash-lite', 'object': 'model'},
        ],
      }));
      await req.response.close();
      return;
    }

    if (req.uri.path.endsWith('/chat/completions')) {
      if (script.isNotEmpty) {
        final next = script.removeAt(0);
        await next.write(req);
        return;
      }
      final handler = chatHandler;
      if (handler != null) {
        await handler(req, body);
        return;
      }
      final model = (body['model'] ?? 'gemini-3.8-flash').toString();
      if (body['stream'] == true) {
        await writeStream(req, ['你好', '，世界'], model: model);
      } else {
        req.response.statusCode = 200;
        req.response.headers.contentType = ContentType.json;
        req.response.write(jsonEncode({
          'id': 'chatcmpl_test',
          'model': model,
          'choices': [
            {
              'index': 0,
              'message': {'role': 'assistant', 'content': '你好，世界'},
              'finish_reason': 'stop',
            }
          ],
        }));
        await req.response.close();
      }
      return;
    }

    req.response.statusCode = 404;
    await req.response.close();
  }

  Future<void> close() => _server.close(force: true);
}

class FakeResponse {
  FakeResponse(this._writer);

  final Future<void> Function(HttpRequest req) _writer;

  Future<void> write(HttpRequest req) => _writer(req);
}

/// 一组辅助：以 SSE 写出正文。
Future<void> writeStream(
  HttpRequest req,
  List<String> pieces, {
  String model = 'gemini-3.8-flash',
  String finishReason = 'stop',
  bool includeDone = true,
  bool includeUsage = true,
  int? statusCode,
}) async {
  req.response.statusCode = statusCode ?? 200;
  req.response.headers.set('content-type', 'text/event-stream; charset=utf-8');
  req.response.headers.set('cache-control', 'no-cache');
  req.response.headers.set('x-router-model', model);
  await req.response.flush();

  void frame(Map<String, Object?> payload) {
    req.response.write('data: ${jsonEncode(payload)}\n\n');
  }

  frame({
    'id': 'chatcmpl_test',
    'object': 'chat.completion.chunk',
    'model': model,
    'choices': [
      {
        'index': 0,
        'delta': {'role': 'assistant'},
        'finish_reason': null,
      }
    ],
  });

  for (final piece in pieces) {
    frame({
      'id': 'chatcmpl_test',
      'object': 'chat.completion.chunk',
      'model': model,
      'choices': [
        {
          'index': 0,
          'delta': {'content': piece},
          'finish_reason': null,
        }
      ],
    });
    await req.response.flush();
  }

  frame({
    'id': 'chatcmpl_test',
    'object': 'chat.completion.chunk',
    'model': model,
    'choices': [
      {
        'index': 0,
        'delta': const <String, Object?>{},
        'finish_reason': finishReason,
      }
    ],
  });

  if (includeUsage) {
    frame({
      'id': 'chatcmpl_test',
      'object': 'chat.completion.chunk',
      'model': model,
      'choices': const <Object?>[],
      'usage': {'prompt_tokens': 12, 'completion_tokens': 7, 'total_tokens': 19},
    });
  }
  if (includeDone) {
    req.response.write('data: [DONE]\n\n');
  }
  await req.response.close();
}

/// 写一个错误响应。
Future<void> writeError(
  HttpRequest req,
  int status, {
  String message = 'quota exceeded',
  String? code,
  Object? details,
  Map<String, String> headers = const {},
}) async {
  req.response.statusCode = status;
  headers.forEach(req.response.headers.set);
  req.response.headers.contentType =
      ContentType('application', 'json', charset: 'utf-8');
  req.response.write(jsonEncode({
    'error': {
      'message': message,
      'code': code,
      'status': code,
      if (details != null) 'details': details,
    }
  }));
  await req.response.close();
}
