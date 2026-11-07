import 'dart:convert';
import 'dart:io';

import 'package:eatgemini/src/adapters/transport.dart';
import 'package:eatgemini/src/core/chat.dart';
import 'package:eatgemini/src/core/config.dart';
import 'package:eatgemini/src/core/router_engine.dart';
import 'package:eatgemini/src/quota/quota.dart';
import 'package:test/test.dart';

import 'support/fake_upstream.dart';

void main() {
  late FakeUpstream fake;
  late RouterConfig config;
  late QuotaManager quota;
  late RouterEngine engine;

  setUp(() async {
    fake = await FakeUpstream.start();
    config = defaultConfig().copyWith(
      upstream: UpstreamConfig(baseUrl: fake.baseUrl),
    );
    quota = QuotaManager(config: () => config, store: MemoryStateStore());
    engine = RouterEngine(
      config: () => config,
      transport: DartIoTransport(config: () => config),
      quota: quota,
      upstreamApiKey: () => 'TESTKEY-FAKE-00000000000000000000000000',
    );
  });

  tearDown(() async {
    await fake.close();
  });

  RouteInput input(String model,
      {bool stream = true, Map<String, Object?>? extra}) {
    final body = <String, Object?>{
      'model': model,
      'messages': [
        {'role': 'user', 'content': '你好'}
      ],
      'stream': stream,
      if (extra != null) ...extra,
    };
    return RouteInput(
      clientId: 'pockettavern',
      client: config.auth.clients['pockettavern']!,
      request: parseChatRequest(body),
      requestId: 'req_test',
      startedAt: DateTime.now(),
    );
  }

  test('流式：首个合法事件前完成提交，正文与 [DONE] 正确', () async {
    final result = await engine.route(input('router:chat'));
    expect(result, isA<RouteStreamResult>());
    final stream = result as RouteStreamResult;
    final text = await stream.body.transform(utf8.decoder).join();
    expect(text, contains('你好'));
    expect(text, contains('世界'));
    expect(text, contains('data: [DONE]'));
    expect(stream.trace.servedModel, 'gemini-3.8-flash');

    // 上游收到的是白名单字段
    final sent = fake.requests.single;
    expect(sent['stream'], isTrue);
    expect(sent['stream_options'], {'include_usage': true});
    expect(sent.containsKey('tools'), isFalse);
  });

  test('日配额耗尽时换下一个模型', () async {
    fake.script.add(FakeResponse((req) => writeError(
          req,
          429,
          message: 'Quota exceeded',
          code: 'RESOURCE_EXHAUSTED',
          details: [
            {
              '@type': 'google.rpc.QuotaFailure',
              'violations': [
                {
                  'quotaId':
                      'GenerateRequestsPerDayPerProjectPerModel-FreeTier',
                  'limit': 20,
                }
              ]
            }
          ],
        )));

    final result = await engine.route(input('router:chat'));
    expect(result, isA<RouteStreamResult>());
    final stream = result as RouteStreamResult;
    final text = await stream.body.transform(utf8.decoder).join();
    expect(text, contains('你好'));

    expect(stream.trace.upstreamAttempts, 2);
    expect(stream.trace.fellBack, isTrue);
    expect(stream.trace.servedModel, 'gemini-3.6-flash');
    expect(fake.requests[0]['model'], 'gemini-3.8-flash');
    expect(fake.requests[1]['model'], 'gemini-3.6-flash');
  });

  test('提交后断流：发 SSE error，不伪造完成', () async {
    fake.chatHandler = (req, body) async {
      req.response.statusCode = 200;
      req.response.headers
          .set('content-type', 'text/event-stream; charset=utf-8');
      req.response.write('data: ${jsonEncode({
            'model': 'gemini-3.8-flash',
            'choices': [
              {
                'index': 0,
                'delta': {'content': '半截'},
                'finish_reason': null,
              }
            ],
          })}\n\n');
      await req.response.flush();
      await req.response.close();
    };

    final result = await engine.route(input('router:chat'));
    expect(result, isA<RouteStreamResult>());
    final text =
        await (result as RouteStreamResult).body.transform(utf8.decoder).join();
    expect(text, contains('半截'));
    expect(text, contains('incomplete_stream'));
    expect(text, isNot(contains('data: [DONE]')));
  });

  test('只有一个结束标记没有完成帧：不当作成功', () async {
    fake.chatHandler = (req, body) async {
      req.response.statusCode = 200;
      req.response.headers
          .set('content-type', 'text/event-stream; charset=utf-8');
      req.response.write('data: [DONE]\n\n');
      await req.response.close();
    };

    final result = await engine.route(input('router:chat'));
    // 首帧前就结束 → 视为失败，尝试下一个模型；6 个模型都失败后返回错误
    expect(result, isA<RouteErrorResult>());
    expect(quota.snapshot(DateTime.now())['persistError'], isNull);
  });

  test('非流式：完整 JSON 才算成功', () async {
    fake.chatHandler = (req, body) async {
      req.response.statusCode = 200;
      req.response.headers.contentType = ContentType.json;
      req.response.write(jsonEncode({
        'id': 'x',
        'model': 'gemini-3.8-flash',
        'choices': [
          {
            'index': 0,
            'message': {'role': 'assistant', 'content': '完整回复'},
            'finish_reason': 'stop',
          }
        ],
      }));
      await req.response.close();
    };

    final result = await engine.route(input('router:chat', stream: false));
    expect(result, isA<RouteJsonResult>());
    final json = (result as RouteJsonResult).json;
    expect((json['choices'] as List).length, 1);
  });

  test('401 直接终止，不逐模型重试', () async {
    fake.chatHandler = (req, body) async {
      await writeError(req, 401,
          message: 'API key not valid', code: 'INVALID_ARGUMENT');
    };

    final result = await engine.route(input('router:chat'));
    expect(result, isA<RouteErrorResult>());
    final err = result as RouteErrorResult;
    expect(err.status, 502);
    expect(err.code, 'upstream_access_error');
    expect(fake.requests.length, 1);
  });

  test('可修复参数：去掉该字段后同模型重试一次', () async {
    fake.script.add(FakeResponse((req) async {
      await writeError(req, 400,
          message: 'temperature is not supported for this model',
          code: 'INVALID_ARGUMENT');
    }));
    // 假上游的错误里没有 param 字段时无法修复；这里手动构造带 param 的响应
    fake.script.clear();
    fake.script.add(FakeResponse((req) async {
      req.response.statusCode = 400;
      req.response.headers.contentType = ContentType.json;
      req.response.write(jsonEncode({
        'error': {
          'message': 'temperature is not supported',
          'param': 'temperature',
          'code': 'INVALID_ARGUMENT',
        }
      }));
      await req.response.close();
    }));

    final result = await engine.route(input('gemini-3.5-flash-lite'));
    expect(result, isA<RouteStreamResult>());
    expect(fake.requests.length, 2);
    expect(fake.requests[0].containsKey('temperature'), isFalse,
        reason: '默认请求不带 temperature');
    expect(fake.requests[1].containsKey('temperature'), isFalse);
  });

  test('temperature 在可修复后确实被移除', () async {
    fake.script.add(FakeResponse((req) async {
      req.response.statusCode = 400;
      req.response.headers.contentType = ContentType.json;
      req.response.write(jsonEncode({
        'error': {'message': 'unsupported', 'param': 'temperature'}
      }));
      await req.response.close();
    }));

    final result = await engine.route(
      input('gemini-3.5-flash-lite', extra: {'temperature': 0.7}),
    );
    expect(result, isA<RouteStreamResult>());
    expect(fake.requests.first['temperature'], 0.7);
    expect(fake.requests[1].containsKey('temperature'), isFalse);
  });

  test('未知模型本地拒绝，不发上游', () async {
    final result = await engine.route(input('gpt-4o'));
    expect(result, isA<RouteErrorResult>());
    expect((result as RouteErrorResult).status, 404);
    expect(fake.requests, isEmpty);
  });

  test('模型未核验的思考参数被丢弃并记录', () async {
    // gemini-2.5-flash-lite 的 reasoningEfforts 只有 low/high
    final result = await engine.route(input(
      'gemini-2.5-flash-lite',
      extra: {'reasoning_effort': 'minimal'},
    ));
    expect(result, isA<RouteStreamResult>());
    final sent = fake.requests.single;
    expect(sent.containsKey('reasoning_effort'), isFalse);
    expect((result as RouteStreamResult).trace.transforms,
        contains('drop:reasoning_effort(unsupported)'));
  });

  test('reasoning_effort 受支持时原样发送', () async {
    final result = await engine.route(input(
      'gemini-3.8-flash',
      extra: {'reasoning_effort': 'low'},
    ));
    expect(result, isA<RouteStreamResult>());
    expect(fake.requests.single['reasoning_effort'], 'low');
  });

  test('penalty 400：剥掉两个惩罚项重试一次，并跨请求记住', () async {
    // 第一次带 penalty 的请求被上游拒绝（酒馆会发非零惩罚项）
    fake.script.add(FakeResponse((req) async {
      req.response.statusCode = 400;
      req.response.headers.contentType = ContentType.json;
      req.response.write(jsonEncode({
        'error': {
          'code': 400,
          'message': 'Penalty is not enabled for this model',
          'status': 'INVALID_ARGUMENT',
        }
      }));
      await req.response.close();
    }));

    final first = await engine.route(
      input('gemini-3.5-flash-lite',
          extra: {'frequency_penalty': 0.7, 'presence_penalty': 0.3}),
    );
    expect(first, isA<RouteStreamResult>());
    expect(fake.requests.length, 2);
    expect(fake.requests[0]['frequency_penalty'], 0.7);
    expect(fake.requests[0]['presence_penalty'], 0.3);
    expect(fake.requests[1].containsKey('frequency_penalty'), isFalse);
    expect(fake.requests[1].containsKey('presence_penalty'), isFalse);

    // 学到的剥离对后续请求生效（不再浪费一次 400）
    fake.requests.clear();
    final second = await engine.route(
      input('gemini-3.5-flash-lite',
          extra: {'frequency_penalty': 0.7, 'presence_penalty': 0.3}),
    );
    expect(second, isA<RouteStreamResult>());
    expect(fake.requests.single.containsKey('frequency_penalty'), isFalse);
    expect(fake.requests.single.containsKey('presence_penalty'), isFalse);
    expect(quota.learnedStripsFor('gemini-3.5-flash-lite'),
        containsAll(['frequency_penalty', 'presence_penalty']));
  });

  test('max_tokens 不超过模型输出上限', () async {
    await engine.route(input('gemini-3.8-flash',
        stream: false, extra: {'max_tokens': 100000}));
    expect(fake.requests.single['max_tokens'], 65536);
  });

  test('所有内置模型未指定输出长度时均使用模型最大额度', () async {
    for (final model in config.models.keys) {
      await engine.route(input(model, stream: false));
      expect(fake.requests.last['max_tokens'], 65536, reason: model);
    }
  });

  test('客户端明确给出的较小输出长度会保留', () async {
    await engine.route(input('gemini-3.8-flash',
        stream: false, extra: {'max_completion_tokens': 12000}));
    expect(fake.requests.single['max_tokens'], 12000);
  });

  test('未知输出额度不擅自添加默认限制', () async {
    final cfg = config.toJson();
    ((cfg['models'] as Map)['gemini-3.8-flash'] as Map)
        .remove('outputTokenLimit');
    config = decodeConfig(cfg);
    await engine.route(input('gemini-3.8-flash', stream: false));
    expect(fake.requests.single.containsKey('max_tokens'), isFalse);
  });

  test('上游不接受 max_tokens 时修复重试不会崩溃', () async {
    fake.script.add(FakeResponse((req) async {
      req.response.statusCode = 400;
      req.response.headers.contentType = ContentType.json;
      req.response.write(jsonEncode({'error': {
        'message': 'Unknown parameter: max_tokens', 'param': 'max_tokens',
      }}));
      await req.response.close();
    }));
    final result = await engine.route(input('gemini-3.8-flash', stream: false));
    expect(result, isA<RouteJsonResult>());
    expect(fake.requests.length, 2);
    expect(fake.requests.last.containsKey('max_tokens'), isFalse);
  });

  test('默认流式生成超过旧 4 分钟总截止仍可完成', () async {
    var now = DateTime.now();
    engine = RouterEngine(
      config: () => config,
      transport: DartIoTransport(config: () => config),
      quota: quota, upstreamApiKey: () => 'test', clock: () => now,
    );
    fake.chatHandler = (req, body) async {
      now = now.add(const Duration(minutes: 5));
      await writeStream(req, ['完整回复']);
    };
    final result = await engine.route(input('gemini-3.8-flash'));
    expect(result, isA<RouteStreamResult>());
    final text = await (result as RouteStreamResult).body.transform(utf8.decoder).join();
    expect(text, contains('完整回复'));
    expect(text, contains('data: [DONE]'));
    expect(text, isNot(contains('gateway_deadline')));
  });

  test('非流式响应超过旧 8MB 缓冲上限仍完整交付', () async {
    final content = '长' * (3 * 1024 * 1024);
    fake.chatHandler = (req, body) async {
      req.response.headers.contentType = ContentType.json;
      req.response.write(jsonEncode({
        'choices': [
          {
            'message': {'role': 'assistant', 'content': content},
            'finish_reason': 'length'
          }
        ],
      }));
      await req.response.close();
    };
    final result = await engine.route(input('gemini-3.8-flash', stream: false));
    expect(result, isA<RouteJsonResult>());
    final json = result as RouteJsonResult;
    expect(json.json['choices'], [
      {
        'message': {'role': 'assistant', 'content': content},
        'finish_reason': 'length'
      }
    ]);
  });
}
