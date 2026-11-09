/// 控制台 SSE 连接生命周期回归测试（Windows dart:io 坑位）。
///
/// 客户端断开后，HttpResponse 的写入会静默成功、`res.done` 永不完成；
/// 修复走 `detachSocket` 原生 socket 的 onDone/onError。本测试用真实
/// socket 连接后暴力断开，断言 `sseConnections` 能回落到 0——
/// 这是托盘关窗检测（§4.4）的地基。
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:eatgemini/src/console/server.dart';
import 'package:test/test.dart';

/// 只实现测试路径真正用到的成员（events），其余一律视为测试错误。
class _FakeHost implements ConsoleHost {
  final controller =
      StreamController<(String, Map<String, Object?>)>.broadcast();

  @override
  Stream<(String, Map<String, Object?>)> events() => controller.stream;

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw StateError('测试未预期的调用：${invocation.memberName}');
}

/// SSE 裸 socket 客户端：累积收到的字节，可按标记等待。
class _SseClient {
  _SseClient._(this.socket) {
    socket.listen((chunk) {
      _buffer.write(utf8.decode(chunk, allowMalformed: true));
      final text = _buffer.toString();
      for (final e in _waiters.entries) {
        if (!e.value.isCompleted && text.contains(e.key)) {
          e.value.complete();
        }
      }
    });
  }

  final Socket socket;
  final StringBuffer _buffer = StringBuffer();
  final Map<String, Completer<void>> _waiters = {};

  Future<void> waitMarker(String marker,
      {Duration limit = const Duration(seconds: 5)}) {
    if (_buffer.toString().contains(marker)) return Future.value();
    final c = _waiters.putIfAbsent(marker, Completer<void>.new);
    return c.future.timeout(limit);
  }

  void destroy() => socket.destroy();
}

/// 取会话 Cookie（launch 302 的 Set-Cookie；禁止 HttpClient 自动跟随，
/// 否则中间响应上的 Set-Cookie 拿不到）。
Future<String> _launchSession(ConsoleServer server) async {
  final client = HttpClient()..connectionTimeout = const Duration(seconds: 5);
  final req = await client.getUrl(Uri.parse(
      'http://127.0.0.1:${server.port}/ui/launch?t=${server.createLaunchTicket()}'))
    ..followRedirects = false;
  final resp = await req.close();
  expect(resp.statusCode, 302);
  final cookie = resp.headers.value('set-cookie')!;
  await resp.drain<void>();
  client.close(force: true);
  return RegExp(r'egc_session=([^;]+)').firstMatch(cookie)!.group(1)!;
}

Future<_SseClient> _openSse(ConsoleServer server, String session) async {
  final socket = await Socket.connect('127.0.0.1', server.port);
  socket.write('GET /api/events HTTP/1.1\r\n'
      'Host: 127.0.0.1:${server.port}\r\n'
      'Cookie: egc_session=$session\r\n'
      '\r\n');
  final client = _SseClient._(socket);
  await client.waitMarker('event: hello');
  return client;
}

/// 轮询直到条件满足或超时。
Future<void> _waitFor(bool Function() cond, {String reason = '等待条件超时'}) async {
  final deadline = DateTime.now().add(const Duration(seconds: 5));
  while (!cond() && DateTime.now().isBefore(deadline)) {
    await Future<void>.delayed(const Duration(milliseconds: 50));
  }
  expect(cond(), isTrue, reason: reason);
}

void main() {
  test('客户端断开后 sseConnections 回落（关窗检测地基）', () async {
    final host = _FakeHost();
    final server = ConsoleServer(host: host, backendLimitList: const []);
    await server.start();

    final session = await _launchSession(server);
    final a = await _openSse(server, session);
    final b = await _openSse(server, session);
    expect(server.sseConnections, 2);

    // 事件推送经裸 socket 可见（detach 后写入路径正确）。
    final marker = b.waitMarker('config.changed');
    host.controller.add(('config.changed', {'revision': 2}));
    await marker;

    // 客户端暴力断开 → 计数回落（Windows 上修复前永远不会）。
    a.destroy();
    await _waitFor(() => server.sseConnections == 1);
    b.destroy();
    await _waitFor(() => server.sseConnections == 0,
        reason: '客户端断开后 SSE 计数必须回落，否则托盘关窗检测失效');

    await server.stop();
    await host.controller.close();
  });
}
