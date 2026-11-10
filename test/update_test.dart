import 'dart:convert';
import 'dart:io';

import 'package:eatgemini/src/desktop/update.dart';
import 'package:test/test.dart';

Map<String, Object?> _release({
  String tag = 'v0.3.0',
  String installer = '',
  String portable = '',
}) =>
    {
      'tag_name': tag,
      'html_url': 'https://github.com/wacilimonster-source/eatgemini/releases/tag/$tag',
      'published_at': '2026-11-10T08:00:00Z',
      'body': '修复若干问题\n新增安装版',
      'assets': [
        {
          'name': 'eatgemini-setup-$tag.exe',
          'browser_download_url': installer,
          'size': 16 * 1024 * 1024,
        },
        {
          'name': 'eatgemini-$tag.exe',
          'browser_download_url': portable,
          'size': 8 * 1024 * 1024,
        },
      ],
    };

void main() {
  group('SemVer', () {
    test('v 前缀、缺位补 0、build 元数据', () {
      expect(SemVer.tryParse('v1.2.3')?.toString(), '1.2.3');
      expect(SemVer.tryParse('1.2')?.toString(), '1.2.0');
      expect(SemVer.tryParse('2.0.1+build.5')?.toString(), '2.0.1');
      expect(SemVer.tryParse('nope'), isNull);
      expect(SemVer.tryParse(''), isNull);
    });

    test('正式版高于预发布，数值比较而非字典序', () {
      expect(SemVer.tryParse('0.2.10')!.compareTo(SemVer.tryParse('0.2.9')!),
          greaterThan(0));
      expect(SemVer.tryParse('1.0.0-rc1')!
              .compareTo(SemVer.tryParse('1.0.0')!),
          lessThan(0));
      expect(SemVer.tryParse('1.0.0')!.compareTo(SemVer.tryParse('1.0.0')!), 0);
    });
  });

  test('GitHub 发布解析：挑出安装版/便携版，忽略非 https 资源', () {
    final release = UpdateRelease.fromGitHub(_release(
      installer:
          'https://github.com/wacilimonster-source/eatgemini/releases/download/v0.3.0/eatgemini-setup-v0.3.0.exe',
      portable: 'https://github.com/o/r/releases/download/v0.3.0/eatgemini-v0.3.0.exe',
    ));
    expect(release, isNotNull);
    expect(release!.version, '0.3.0');
    expect(release.installerUrl, contains('eatgemini-setup-'));
    expect(release.portableUrl, contains('eatgemini-v0.3.0.exe'));
    expect(release.installerSize, 16 * 1024 * 1024);
    expect(release.notes, contains('安装版'));
    expect(UpdateRelease.fromGitHub({'tag_name': 'nightly'}), isNull);
  });

  test('update.json 回退源解析', () {
    final release = UpdateRelease.fromManifest({
      'version': '0.3.1',
      'notes': '紧急修复',
      'publishedAt': '2026-11-10T09:00:00Z',
      'installerUrl': 'https://github.com/o/r/releases/download/v0.3.1/setup.exe',
      'installerSize': 1234,
    });
    expect(release!.version, '0.3.1');
    expect(release.installerSize, 1234);
    expect(release.releaseUrl, contains('github.com'));
  });

  group('UpdateChecker', () {
    late Directory temp;
    setUp(() => temp = Directory.systemTemp.createTempSync('eg-update-'));
    tearDown(() {
      if (temp.existsSync()) temp.deleteSync(recursive: true);
    });

    UpdateChecker checker(
      Future<String> Function(String url, {Map<String, String> headers}) fetch,
      DateTime Function() now,
    ) =>
        UpdateChecker(
          currentVersion: '0.2.3',
          updatesDir: temp,
          fetcher: fetch,
          now: now,
        );

    test('检查成功、24 小时节流、结果落盘', () async {
      var calls = 0;
      var now = DateTime.utc(2026, 11, 10, 12);
      final c = checker((url, {headers = const <String, String>{}}) async {
        calls++;
        return jsonEncode(_release(
          installer:
              'https://github.com/o/r/releases/download/v0.3.0/eatgemini-setup-v0.3.0.exe',
        ));
      }, () => now);

      final first = await c.check();
      expect(first.ok, isTrue);
      expect(first.fromCache, isFalse);
      expect(c.state.latestVersion, '0.3.0');
      expect(c.state.hasUpdate('0.2.3'), isTrue);
      expect(c.describe(autoCheck: false)['hasUpdate'], isTrue);
      expect(calls, 1);

      final second = await c.check();
      expect(second.fromCache, isTrue);
      expect(calls, 1, reason: '24 小时内自动检查必须走缓存');

      now = now.add(const Duration(hours: 25));
      await c.check();
      expect(calls, 2, reason: '超过 24 小时应重新请求');

      await c.check(force: true);
      expect(calls, 3, reason: '手动检查忽略节流');

      final restored = UpdateChecker(
          currentVersion: '0.2.3', updatesDir: temp);
      await restored.load();
      expect(restored.state.latestVersion, '0.3.0');
      expect(restored.state.source, 'releases');
    });

    test('GitHub API 失败时回退 update.json', () async {
      final c = checker((url, {headers = const <String, String>{}}) async {
        if (url.contains('api.github.com')) throw const HttpException('503');
        return jsonEncode({
          'version': '0.3.2',
          'notes': '回退源',
          'installerUrl':
              'https://github.com/o/r/releases/download/v0.3.2/setup.exe',
        });
      }, () => DateTime.utc(2026, 11, 10, 12));
      final result = await c.check(force: true);
      expect(result.ok, isTrue);
      expect(c.state.latestVersion, '0.3.2');
      expect(c.state.source, 'manifest');
      expect(c.state.lastError, isNull);
    });

    test('两个源都失败：记录错误且节流后续请求', () async {
      var calls = 0;
      final c = checker((url, {headers = const <String, String>{}}) async {
        calls++;
        throw const HttpException('offline');
      }, () => DateTime.utc(2026, 11, 10, 12));
      final result = await c.check(force: true);
      expect(result.ok, isFalse);
      expect(result.error, isNotNull);
      expect(c.state.lastCheckedAt, isNotNull);
      final cached = await c.check();
      expect(cached.fromCache, isTrue);
      // 一次检查最多尝试两个源（API + 回退），节流后不应再增加。
      expect(calls, 2, reason: '失败后 24 小时内不应反复重试');
    });

    test('跳过版本后不再提示', () async {
      final c = checker((url, {headers = const <String, String>{}}) async =>
          jsonEncode(_release()), () => DateTime.utc(2026, 11, 10, 12));
      await c.check(force: true);
      expect(c.state.hasUpdate('0.2.3'), isTrue);
      await c.skipVersion('0.3.0');
      expect(c.state.hasUpdate('0.2.3'), isFalse);
      await c.clearSkip();
      expect(c.state.hasUpdate('0.2.3'), isTrue);
    });

    test('下载只接受 GitHub 域名', () async {
      final c = checker((url, {headers = const <String, String>{}}) async =>
          jsonEncode(_release()), () => DateTime.utc(2026, 11, 10, 12));
      await c.load();
      c.state.installerUrl = 'https://evil.example.com/setup.exe';
      await expectLater(c.downloadInstaller(), throwsA(isA<StateError>()));
      c.state.installerUrl = '';
      await expectLater(c.downloadInstaller(), throwsA(isA<StateError>()));
    });
  });
}
