import 'dart:convert';

import 'package:eatgemini/src/core/config.dart';
import 'package:test/test.dart';

void main() {
  group('默认配置', () {
    test('默认配置可以通过校验并往返', () {
      final cfg = defaultConfig();
      final round = parseConfig(cfg.encode());
      expect(round.profiles['chat']!.first, 'gemini-3.8-flash');
      expect(round.models.length, 6);
      expect(round.policy.requestDeadlineMs, 0);
      expect(round.policy.maxRequestBytes, 0);
      expect(round.policy.maxBufferedResponseBytes, 0);
      expect(round.compatibility['tavern_text']!.defaultMaxOutputTokens, 0);
      expect(round.policy.routingDeadlineMs, 60000);
      expect(round.auth.clients['pockettavern']!.allowedProfiles,
          contains('chat'));
    });

    test('默认配置不含任何密钥字段', () {
      final text = defaultConfig().encode();
      expect(text.contains('apiKeyEnv'), isFalse);
      expect(text.contains('tokenEnv'), isFalse);
      expect(text.contains('AIza'), isFalse);
    });
  });

  group('校验', () {
    Map<String, Object?> base() =>
        jsonDecode(defaultConfig().encode()) as Map<String, Object?>;

    test('引用不存在的模型会报错', () {
      final json = base();
      (json['profiles'] as Map)['chat'] = ['no-such-model'];
      expect(
        () => decodeConfig(json),
        throwsA(isA<ConfigException>()),
      );
    });

    test('非 https 的公网地址被拒绝', () {
      final json = base();
      (json['upstream'] as Map)['baseUrl'] = 'http://example.com/v1/';
      expect(() => decodeConfig(json), throwsA(isA<ConfigException>()));
    });

    test('本机回环允许 http（调试用）', () {
      final json = base();
      (json['upstream'] as Map)['baseUrl'] = 'http://127.0.0.1:9999/v1/';
      final cfg = decodeConfig(json);
      expect(cfg.upstream.baseUrl, contains('127.0.0.1'));
    });

    test('v2 配置被明确拒绝并提示迁移', () {
      final json = base();
      json['version'] = 2;
      expect(
        () => decodeConfig(json),
        throwsA(predicate((e) =>
            e is ConfigException && e.messages.any((m) => m.contains('v2')))),
      );
    });

    test('配额为负数会报错', () {
      final json = base();
      ((json['quotaGroups'] as Map)['flash38'] as Map)['rpm'] = -1;
      expect(() => decodeConfig(json), throwsA(isA<ConfigException>()));
    });

    test('routingDeadline 大于 requestDeadline 会报错', () {
      final json = base();
      ((json['policy'] as Map))['routingDeadlineMs'] = 300000;
      ((json['policy'] as Map))['requestDeadlineMs'] = 240000;
      expect(() => decodeConfig(json), throwsA(isA<ConfigException>()));
    });

    test('禁用的模型不会让校验失败，但全部禁用会', () {
      final json = base();
      for (final model in (json['models'] as Map).values) {
        (model as Map)['enabled'] = false;
      }
      expect(() => decodeConfig(json), throwsA(isA<ConfigException>()));
    });

    test('默认档位必须存在', () {
      final json = base();
      ((json['policy'] as Map))['defaultProfile'] = 'nope';
      expect(() => decodeConfig(json), throwsA(isA<ConfigException>()));
    });
  });
}
