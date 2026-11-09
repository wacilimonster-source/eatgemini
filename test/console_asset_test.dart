import 'dart:convert';
import 'dart:io';

import 'package:eatgemini/src/console/server.dart';
import 'package:test/test.dart';

class _FakeHost implements ConsoleHost {
  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw StateError('测试未预期的调用：${invocation.memberName}');
}

/// 用裸 socket 发请求：HttpClient 可能自行归一化 `..`，测不到服务端
/// 的路径穿越防护。
Future<String> _rawGet(ConsoleServer server, String path, String session) async {
  final socket = await Socket.connect('127.0.0.1', server.port);
  socket.write('GET $path HTTP/1.1\r\n'
      'Host: 127.0.0.1:${server.port}\r\n'
      'Cookie: egc_session=$session\r\n'
      'Connection: close\r\n'
      '\r\n');
  final response = await utf8.decoder.bind(socket).join();
  socket.destroy();
  return response;
}

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

void main() {
  test('/ui/ 磁盘回退拒绝路径穿越', () async {
    final server = ConsoleServer(host: _FakeHost(), backendLimitList: const []);
    await server.start();
    addTearDown(server.stop);
    final session = await _launchSession(server);

    // 正常资源仍可读取（内嵌或磁盘回退）。
    final index = await _rawGet(server, '/ui/index.html', session);
    expect(index, startsWith('HTTP/1.1 200'));

    for (final path in [
      '/ui/../../pubspec.yaml',
      '/ui/%2e%2e/%2e%2e/pubspec.yaml',
    ]) {
      final response = await _rawGet(server, path, session);
      expect(response, startsWith('HTTP/1.1 404'),
          reason: '路径穿越必须被拒绝：$path');
      expect(response.contains('name: eatgemini'), isFalse);
    }
  });
}
