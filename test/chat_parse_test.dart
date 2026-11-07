import 'package:eatgemini/src/core/chat.dart';
import 'package:test/test.dart';

void main() {
  group('请求解析', () {
    test('最小请求可用', () {
      final req = parseChatRequest({
        'model': 'router:chat',
        'messages': [
          {'role': 'user', 'content': '你好'}
        ],
      });
      expect(req.stream, isFalse);
      expect(req.messages.single.content, '你好');
      expect(req.maxTokens, isNull);
    });

    test('未知字段被拒绝并指出字段名', () {
      expect(
        () => parseChatRequest({
          'model': 'router:chat',
          'messages': [
            {'role': 'user', 'content': 'hi'}
          ],
          'bogus_field': 1,
        }),
        throwsA(predicate(
            (e) => e is RequestRejected && e.param == 'bogus_field')),
      );
    });

    test('图片内容被拒绝而不是抽取文字', () {
      expect(
        () => parseChatRequest({
          'model': 'router:chat',
          'messages': [
            {
              'role': 'user',
              'content': [
                {'type': 'text', 'text': '看看'},
                {'type': 'image_url', 'image_url': {'url': 'http://x'}},
              ]
            }
          ],
        }),
        throwsA(predicate((e) =>
            e is RequestRejected &&
            e.code == 'unsupported_content' &&
            e.message.contains('image_url'))),
      );
    });

    test('纯文本片段数组按顺序拼接', () {
      final req = parseChatRequest({
        'model': 'router:chat',
        'messages': [
          {
            'role': 'user',
            'content': [
              {'type': 'text', 'text': 'a'},
              {'type': 'text', 'text': 'b'},
            ]
          }
        ],
      });
      expect(req.messages.single.content, 'ab');
    });

    test('n > 1 被拒绝', () {
      expect(
        () => parseChatRequest({
          'model': 'router:chat',
          'messages': [
            {'role': 'user', 'content': 'hi'}
          ],
          'n': 2,
        }),
        throwsA(predicate((e) => e is RequestRejected && e.param == 'n')),
      );
    });

    test('空 logit_bias 视为未启用，非空拒绝', () {
      final ok = parseChatRequest({
        'model': 'router:chat',
        'messages': [
          {'role': 'user', 'content': 'hi'}
        ],
        'logit_bias': <String, Object?>{},
      });
      expect(ok.messages, isNotEmpty);

      expect(
        () => parseChatRequest({
          'model': 'router:chat',
          'messages': [
            {'role': 'user', 'content': 'hi'}
          ],
          'logit_bias': {'123': 5},
        }),
        throwsA(predicate((e) => e is RequestRejected && e.param == 'logit_bias')),
      );
    });

    test('真实工具调用被拒绝，空 tools 可以通过', () {
      final ok = parseChatRequest({
        'model': 'router:chat',
        'messages': [
          {'role': 'user', 'content': 'hi'}
        ],
        'tools': const <Object?>[],
        'tool_choice': 'none',
      });
      expect(ok.model, 'router:chat');

      expect(
        () => parseChatRequest({
          'model': 'router:chat',
          'messages': [
            {'role': 'user', 'content': 'hi'}
          ],
          'tools': [
            {'type': 'function', 'function': {'name': 'f'}}
          ],
        }),
        throwsA(predicate((e) => e is RequestRejected && e.param == 'tools')),
      );
    });

    test('max_completion_tokens 优先于 max_tokens', () {
      final req = parseChatRequest({
        'model': 'router:chat',
        'messages': [
          {'role': 'user', 'content': 'hi'}
        ],
        'max_tokens': 100,
        'max_completion_tokens': 200,
      });
      expect(req.maxTokens, 200);
    });

    test('max_tokens 为 0 或负数被拒绝', () {
      expect(
        () => parseChatRequest({
          'model': 'router:chat',
          'messages': [
            {'role': 'user', 'content': 'hi'}
          ],
          'max_tokens': 0,
        }),
        throwsA(isA<RequestRejected>()),
      );
    });

    test('tool / developer 角色被拒绝', () {
      expect(
        () => parseChatRequest({
          'model': 'router:chat',
          'messages': [
            {'role': 'tool', 'content': 'x'}
          ],
        }),
        throwsA(predicate((e) => e is RequestRejected && e.code == 'unsupported_message_role')),
      );
    });

    test('多 system 与连续同角色保留顺序', () {
      final req = parseChatRequest({
        'model': 'router:chat',
        'messages': [
          {'role': 'system', 'content': 's1'},
          {'role': 'system', 'content': 's2'},
          {'role': 'user', 'content': 'u1', 'name': '张三'},
          {'role': 'user', 'content': 'u2'},
          {'role': 'assistant', 'content': ''},
        ],
      });
      expect(req.messages.map((m) => m.role).toList(),
          ['system', 'system', 'user', 'user', 'assistant']);
      expect(req.messages[2].name, '张三');
      expect(req.messages.last.content, '');
    });

    test('token 估算：中文按字、ASCII 按 4 字符', () {
      expect(estimateTokens('abcd'), 1);
      expect(estimateTokens('中文'), 2);
    });
  });
}
