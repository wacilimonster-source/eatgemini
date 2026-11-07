import 'dart:convert';
import 'dart:io';

import 'package:eatgemini/src/adapters/transport.dart';
import 'package:eatgemini/src/core/config.dart';
import 'package:eatgemini/src/core/router_engine.dart';
import 'package:eatgemini/src/core/telemetry.dart';
import 'package:eatgemini/src/http/gateway_server.dart';
import 'package:eatgemini/src/quota/quota.dart';
import 'package:test/test.dart';

import 'support/fake_upstream.dart';

void main() {
  late FakeUpstream fake;
  late RouterConfig config;
  late GatewayServer server;
  late HttpClient client;
  bool configured = true;

  setUp(() async {
    fake = await FakeUpstream.start();
    config = defaultConfig().copyWith(
      upstream: UpstreamConfig(baseUrl: fake.baseUrl),
      listen: const ListenConfig(port: 0),
    );
    final quota = QuotaManager(config: () => config, store: MemoryStateStore());
    final transport = DartIoTransport(config: () => config);
    final engine = RouterEngine(
      config: () => config,
      transport: transport,
      quota: quota,
      upstreamApiKey: () => 'FAKE-TEST-KEY',
    );
    server = GatewayServer(
      config: () => config,
      engine: () => engine,
      quota: quota,
      tokens: StaticTokenDirectory(const {'pockettavern': 'tok_pt_test'}),
      appStatus: () => configured
          ? const AppStatus('ready')
          : const AppStatus('needs_key', '还没有配置 Google API Key'),
      upstreamConfigured: () => configured,
      appVersion: 'test',
    );
    await server.start(config.listen);
    client = HttpClient();
  });

  tearDown(() async {
    await server.stop();
    await fake.close();
    client.close(force: true);
  });

  Future<(HttpClientResponse, String)> get(String path, {String? token}) async {
    final req = await client
        .getUrl(Uri.parse('http://127.0.0.1:${server.boundPort}$path'));
    if (token != null) req.headers.set('authorization', 'Bearer $token');
    final resp = await req.close();
    return (resp, await resp.transform(utf8.decoder).join());
  }

  Future<(HttpClientResponse, String)> post(
    String path,
    Map<String, Object?> body, {
    String? token,
    Map<String, String> headers = const {},
  }) async {
    final req = await client
        .postUrl(Uri.parse('http://127.0.0.1:${server.boundPort}$path'));
    req.headers.contentType = ContentType.json;
    if (token != null) req.headers.set('authorization', 'Bearer $token');
    headers.forEach(req.headers.set);
    req.add(utf8.encode(jsonEncode(body)));
    final resp = await req.close();
    return (resp, await resp.transform(utf8.decoder).join());
  }

  test('/healthz 不需要鉴权且不泄露内部状态', () async {
    final (resp, body) = await get('/healthz');
    expect(resp.statusCode, 200);
    expect(jsonDecode(body)['app'], 'eatgemini');
    expect(jsonDecode(body)['api'], kApiVersion);
    expect(body.contains('gemini-3'), isFalse);
  });

  test('无令牌 / 错令牌 → 401', () async {
    final (resp1, _) = await get('/v1/models');
    expect(resp1.statusCode, 401);
    final (resp2, body2) = await get('/v1/models', token: 'wrong');
    expect(resp2.statusCode, 401);
    expect(jsonDecode(body2)['error']['code'], 'invalid_client_token');
  });

  test('/v1/models 列出别名与允许的模型', () async {
    final (resp, body) = await get('/v1/models', token: 'tok_pt_test');
    expect(resp.statusCode, 200);
    final data = (jsonDecode(body)['data'] as List).cast<Map>();
    final ids = data.map((m) => m['id']).toList();
    expect(ids, contains('auto'));
    expect(ids, contains('router:chat'));
    expect(ids, contains('gemini-3.8-flash'));
    final flash = data.firstWhere((m) => m['id'] == 'gemini-3.8-flash');
    expect(flash['context_window'], 1048576);
    expect(flash['max_output_tokens'], 65536);
  });

  test('chat：流式请求原样转出并带请求 ID', () async {
    final (resp, body) = await post(
      '/v1/chat/completions',
      {
        'model': 'router:chat',
        'stream': true,
        'messages': [
          {'role': 'user', 'content': 'hi'}
        ],
      },
      token: 'tok_pt_test',
    );
    expect(resp.statusCode, 200);
    expect(resp.headers.value('x-request-id'), isNotNull);
    expect(body, contains('你好'));
    expect(body, contains('data: [DONE]'));
  });

  test('chat：重复斜杠路径（/v1//chat/completions）按归一路由处理', () async {
    // 契约：/v1 与 /v1/ 两种 baseUrl 都可用。客户端朴素拼接（酒馆 custom
    // 分支 `${apiUrl}/chat/completions`）+ 带尾斜杠的 baseUrl 会产生双斜杠，
    // 不应被 404「未知路径」拒绝。
    final (resp, body) = await post(
      '/v1//chat/completions',
      {
        'model': 'router:chat',
        'stream': true,
        'messages': [
          {'role': 'user', 'content': 'hi'}
        ],
      },
      token: 'tok_pt_test',
    );
    expect(resp.statusCode, 200);
    expect(body, contains('data: [DONE]'));
  });

  test('chat：X-Router-Trace 返回实际模型与尝试数', () async {
    final (resp, _) = await post(
      '/v1/chat/completions',
      {
        'model': 'router:chat',
        'stream': false,
        'messages': [
          {'role': 'user', 'content': 'hi'}
        ],
      },
      token: 'tok_pt_test',
      headers: {'x-router-trace': '1'},
    );
    expect(resp.statusCode, 200);
    expect(resp.headers.value('x-router-model'), isNotNull);
  });

  test('未配置 Key 时返回 503 gateway_needs_key', () async {
    configured = false;
    final (resp, body) = await post(
      '/v1/chat/completions',
      {
        'model': 'router:chat',
        'stream': true,
        'messages': [
          {'role': 'user', 'content': 'hi'}
        ],
      },
      token: 'tok_pt_test',
    );
    expect(resp.statusCode, 503);
    expect(jsonDecode(body)['error']['code'], 'gateway_needs_key');
    configured = true; // 恢复，避免影响后续用例
  });

  test('/router/status 需要令牌且不返回项目与密钥信息', () async {
    final (resp, body) = await get('/router/status', token: 'tok_pt_test');
    expect(resp.statusCode, 200);
    expect(body.contains('projectRef'), isFalse);
    expect(body.contains('AIza'), isFalse);
    final json = jsonDecode(body) as Map<String, Object?>;
    expect((json['profiles'] as List).isNotEmpty, isTrue);
  });

  test('正常小请求不受大小限制影响', () async {
    final (resp, body) = await post(
      '/v1/chat/completions',
      {
        'model': 'router:chat',
        'stream': true,
        'messages': [
          {'role': 'user', 'content': 'x' * 100}
        ],
      },
      token: 'tok_pt_test',
    );
    expect(resp.statusCode, 200);
    expect(body, contains('你好'));
  });

  test('超过 maxRequestBytes 的请求 → 413，不发上游', () async {
    final cfg = config.toJson();
    (cfg['policy'] as Map)['maxRequestBytes'] = 2 * 1024 * 1024;
    config = decodeConfig(cfg);
    final requestsBefore = fake.requests.length;
    final (resp, body) = await post(
      '/v1/chat/completions',
      {
        'model': 'router:chat',
        'stream': true,
        'messages': [
          {'role': 'user', 'content': 'x' * (2 * 1024 * 1024 + 1)}
        ],
      },
      token: 'tok_pt_test',
    );
    expect(resp.statusCode, 413);
    expect(jsonDecode(body)['error']['code'], 'request_too_large');
    expect(fake.requests.length, requestsBefore);
  });

  test('默认完整转发超过旧 2MB 上限的多条历史消息', () async {
    final cfg = config.toJson();
    for (final group in (cfg['quotaGroups'] as Map).values) {
      (group as Map)['tpm'] = null;
    }
    config = decodeConfig(cfg);
    final history = [
      {'role': 'system', 'content': '保留系统提示'},
      {'role': 'user', 'content': '中' * 750000},
      {'role': 'assistant', 'content': '保留历史回复'},
      {'role': 'user', 'content': '保留最后问题'},
    ];
    final (resp, _) = await post(
        '/v1/chat/completions',
        {
          'model': 'router:chat',
          'messages': history,
          'stream': false,
        },
        token: 'tok_pt_test');
    expect(resp.statusCode, 200);
    expect(fake.requests.single['messages'], history);
    expect(fake.requests.single['max_tokens'], 65536);
  });
}
