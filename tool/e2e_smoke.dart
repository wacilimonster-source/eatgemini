/// 端到端冒烟：真 DPAPI 密钥库 + 假上游 + 完整 HTTP 链路。
///
/// 运行：`dart run tool/e2e_smoke.dart`；退出码 0 = 全部通过。
/// 不访问任何真实网络。
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:eatgemini/src/app/app_controller.dart';
import 'package:eatgemini/src/core/config.dart';

import '../test/support/fake_upstream.dart';

Future<void> main(List<String> args) async {
  final fake = await FakeUpstream.start();
  final dataDir = await Directory.systemTemp.createTemp('eatgemini-e2e');
  var failures = 0;

  void check(bool cond, String name) {
    if (cond) {
      stdout.writeln('  ✓ $name');
    } else {
      failures++;
      stdout.writeln('  ✗ $name');
    }
  }

  try {
    // ---- 准备配置：假上游 + 随机网关端口 ----
    final cfg = defaultConfig()
        .copyWith(
          upstream: UpstreamConfig(baseUrl: fake.baseUrl),
        )
        .copyWith();
    final listen = const ListenConfig(port: 0);
    final cfgJson = jsonDecode(cfg.encode()) as Map<String, Object?>;
    cfgJson['listen'] = listen.toJson();
    File('${dataDir.path}/config.json')
        .writeAsStringSync(jsonEncode(cfgJson), flush: true);

    // ---- 启动应用 ----
    final app = AppController(version: 'smoke');
    final appDone = app.start(AppOptions(
      dataDirOverride: dataDir.path,
      openWindow: false,
    ));

    // 等网关与控制台就绪（start 在初始化完成前不暴露这些字段）
    final deadline = DateTime.now().add(const Duration(seconds: 15));
    var initialized = false;
    while (!initialized && DateTime.now().isBefore(deadline)) {
      await Future<void>.delayed(const Duration(milliseconds: 100));
      try {
        initialized = app.gateway.boundPort != null && app.console.port > 0;
      } catch (_) {
        // 字段尚未初始化：继续等
      }
    }
    check(app.gateway.boundPort != null, '网关已监听');
    check(app.console.port > 0, '控制台已监听（回环随机端口）');
    final gwPort = app.gateway.boundPort ?? 0;
    final consolePort = app.console.port;

    // ---- 鉴权 ----
    final token = app.vault.tokenFor('pockettavern')!.value;
    check(token.startsWith('egw_pt_'), 'pockettavern 令牌已生成');

    final health = await _get('http://127.0.0.1:$gwPort/healthz');
    check(health.$1 == 200 && health.$2.contains('eatgemini'), '/healthz');
    check(health.$2.contains('gemini-3') == false, '/healthz 不泄露模型信息');

    final unauth = await _post(
      'http://127.0.0.1:$gwPort/v1/chat/completions',
      {},
      token: 'wrong-token',
    );
    check(unauth.$1 == 401, '错误令牌返回 401');

    // ---- 密钥流（真 DPAPI）----
    final verify =
        await app.verifyUpstreamKey('SMOKE-FAKE-KEY-000000000000000000000000');
    stdout.writeln('    verify => ' + jsonEncode(verify));
    check(verify['ok'] == true, 'Key 验证走假上游 models');
    final saved = await app.saveUpstreamKey(
      'SMOKE-FAKE-KEY-000000000000000000000000',
      sameProject: true,
    );
    check(saved['ok'] == true, 'Key 已保存');
    final secretsFile = File('${dataDir.path}/secrets.dat');
    final secretsRaw = await secretsFile.readAsString();
    check(!secretsRaw.contains('SMOKE-FAKE-KEY'), 'secrets.dat 不含明文 Key');
    check(!secretsRaw.contains(token), 'secrets.dat 不含明文令牌');
    check(app.appStatus().state == 'ready', '应用状态 ready');

    // ---- 生成链路 ----
    (int, String, Map<String, String>) chat;
    try {
      chat = await _post(
        'http://127.0.0.1:$gwPort/v1/chat/completions',
        {
          'model': 'router:chat',
          'stream': true,
          'messages': [
            {'role': 'user', 'content': '你好'}
          ],
        },
        token: token,
        headers: {'x-router-trace': '1'},
      );
      check(chat.$1 == 200, 'chat 返回 200');
      check(chat.$2.contains('你好'), 'SSE 正文到达');
      check(chat.$2.contains('data: [DONE]'), 'SSE 正常结束');
      final respHeaders = chat.$3;
      check(respHeaders['x-router-model'] != null, 'X-Router-Trace 返回实际模型');
      check(respHeaders['x-request-id'] != null, 'x-request-id 存在');

      final status = await _get(
        'http://127.0.0.1:$gwPort/router/status',
        token: token,
      );
      check(status.$1 == 200, '/router/status');
      check(status.$2.contains('"nextResetAt"'), '/router/status 有重置时间');
      check(status.$2.contains('AIza') == false, '/router/status 不含 Key');

      // 非流式
      final nonStream = await _post(
        'http://127.0.0.1:$gwPort/v1/chat/completions',
        {
          'model': 'gemini-3.5-flash-lite',
          'stream': false,
          'max_tokens': 100,
          'messages': [
            {'role': 'user', 'content': 'hi'}
          ],
        },
        token: token,
      );
      check(nonStream.$1 == 200, '非流式 chat 返回 200');
      check(nonStream.$2.contains('"choices"'), '非流式返回 choices');
    } catch (e) {
      stdout.writeln('    chat 链路异常 => ' + e.toString());
      stdout.writeln('    fake received => ' + jsonEncode(fake.requests));
      stdout.writeln('    app status => ' + app.appStatus().state);
      stdout.writeln('    app logs => ' + app.logger.recent.join(' | '));
      rethrow;
    }

    // ---- 控制台会话与页面 ----
    final launchUrl = app.console.launchUri();
    final sessionClient = HttpClient();
    var cookie = '';
    var pageStatus = 0;
    try {
      final req = await sessionClient.getUrl(launchUrl);
      req.followRedirects = false;
      final resp = await req.close();
      pageStatus = resp.statusCode;
      for (final c in resp.cookies) {
        cookie = '${c.name}=${c.value}';
      }
      await resp.drain<void>();
    } finally {
      sessionClient.close(force: true);
    }
    check(pageStatus == 302 && cookie.isNotEmpty, '启动票据换取会话');

    final page =
        await _getWithCookie('http://127.0.0.1:$consolePort/ui/', cookie);
    check(page.$1 == 200 && page.$2.contains('监控'), '监控页面已内嵌并可访问');
    final csp = page.$3['content-security-policy'] ?? '';
    check(csp.contains("default-src 'self'"), 'CSP 生效');
    final snapApi = await _getWithCookie(
        'http://127.0.0.1:$consolePort/api/snapshot', cookie);
    check(
        snapApi.$1 == 200 && snapApi.$2.contains('csrf'), 'snapshot 返回会话 CSRF');

    final modelsApi = await _getWithCookie(
        'http://127.0.0.1:$consolePort/api/models', cookie);
    final modelRows = (jsonDecode(modelsApi.$2)['models'] as List).cast<Map>();
    check(
        modelsApi.$1 == 200 &&
            modelRows.length == 6 &&
            modelRows.every((m) =>
                m['inputTokenLimit'] == 1048576 &&
                m['outputTokenLimit'] == 65536),
        '模型页面 API 返回全部模型输入上下文与最大输出');

    // ---- 控制台安全 ----
    final noSession = await _get('http://127.0.0.1:$consolePort/api/snapshot');
    check(noSession.$1 == 401, '无会话访问控制台 API 返回 401');
    final badTicket =
        await _get('http://127.0.0.1:$consolePort/ui/launch?t=bad');
    check(badTicket.$1 == 403, '一次性票据校验生效');

    // ---- 诊断导出 ----
    final diagPath = await app.exportDiagnostics();
    final diagRaw = await File(diagPath).readAsString();
    check(diagRaw.contains('SMOKE-FAKE-KEY') == false, '诊断包不含明文 Key');
    check(diagRaw.contains(token) == false, '诊断包不含明文令牌');

    // ---- 退出 ----
    await app.shutdown();
    check(!File('${dataDir.path}/instance.json').existsSync(),
        '退出后删除 instance.json');
    await appDone;
    stdout.writeln(failures == 0 ? 'SMOKE PASS' : 'SMOKE FAIL ($failures)');
    exit(failures == 0 ? 0 : 1);
  } catch (e, st) {
    stdout.writeln('SMOKE ERROR: $e\n$st');
    exit(2);
  } finally {
    await fake.close();
    try {
      await dataDir.delete(recursive: true);
    } catch (_) {}
  }
}

Future<(int, String, Map<String, String>)> _getWithCookie(
    String url, String cookie) async {
  final client = HttpClient()..connectionTimeout = const Duration(seconds: 5);
  try {
    final req = await client.getUrl(Uri.parse(url));
    if (cookie.isNotEmpty) req.headers.set('cookie', cookie);
    final resp = await req.close().timeout(const Duration(seconds: 10));
    final body = await resp.transform(utf8.decoder).join();
    final headerMap = <String, String>{};
    resp.headers.forEach((name, values) {
      headerMap[name.toLowerCase()] = values.join(',');
    });
    return (resp.statusCode, body, headerMap);
  } finally {
    client.close(force: true);
  }
}

Future<(int, String, Map<String, String>)> _get(String url,
    {String? token}) async {
  final client = HttpClient()..connectionTimeout = const Duration(seconds: 5);
  try {
    final req = await client.getUrl(Uri.parse(url));
    if (token != null) req.headers.set('authorization', 'Bearer $token');
    final resp = await req.close().timeout(const Duration(seconds: 10));
    final body = await resp.transform(utf8.decoder).join();
    return (
      resp.statusCode,
      body,
      {
        for (final e in resp.headers.toString().split('\n'))
          if (e.contains(':'))
            e.split(':').first.trim().toLowerCase():
                e.substring(e.indexOf(':') + 1).trim()
      }
    );
  } finally {
    client.close(force: true);
  }
}

Future<(int, String, Map<String, String>)> _post(
  String url,
  Map<String, Object?> body, {
  String? token,
  Map<String, String> headers = const {},
}) async {
  final client = HttpClient()..connectionTimeout = const Duration(seconds: 5);
  try {
    final req = await client.postUrl(Uri.parse(url));
    req.headers.contentType = ContentType.json;
    if (token != null) req.headers.set('authorization', 'Bearer $token');
    headers.forEach(req.headers.set);
    req.add(utf8.encode(jsonEncode(body)));
    final resp = await req.close().timeout(const Duration(seconds: 20));
    final text = await resp.transform(utf8.decoder).join();
    return (
      resp.statusCode,
      text,
      {
        for (final e in resp.headers.toString().split('\n'))
          if (e.contains(':'))
            e.split(':').first.trim().toLowerCase():
                e.substring(e.indexOf(':') + 1).trim()
      }
    );
  } finally {
    client.close(force: true);
  }
}
