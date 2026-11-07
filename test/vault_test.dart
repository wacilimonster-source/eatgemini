import 'dart:convert';
import 'dart:io';

import 'package:eatgemini/src/observe/observability.dart';
import 'package:eatgemini/src/secrets/dpapi.dart';
import 'package:eatgemini/src/secrets/vault.dart';
import 'package:test/test.dart';

void main() {
  late Directory dir;

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('eatgemini-vault');
  });

  tearDown(() async {
    await dir.delete(recursive: true);
  });

  test('首次加载生成客户端令牌并加密保存', () async {
    final vault = SecretVault(
      directory: dir,
      dpapi: FakeDpapi(),
      clientIds: const ['sillytavern', 'pockettavern'],
      redactor: Redactor(),
    );
    final result = await vault.load();
    expect(result.ok, isTrue);
    expect(vault.tokens.length, 2);
    expect(vault.tokenFor('sillytavern')!.value.startsWith('egw_st_'), isTrue);
    expect(vault.tokenFor('pockettavern')!.value.startsWith('egw_pt_'), isTrue);
    expect(File('${dir.path}/secrets.dat').existsSync(), isTrue);

    // 文件里没有明文令牌
    final raw = File('${dir.path}/secrets.dat').readAsStringSync();
    expect(raw.contains(vault.tokenFor('sillytavern')!.value), isFalse);
  });

  test('同一目录重新加载得到相同令牌', () async {
    final vault1 = SecretVault(
        directory: dir, dpapi: FakeDpapi(), clientIds: const ['pockettavern']);
    await vault1.load();
    final token1 = vault1.tokenFor('pockettavern')!.value;

    final vault2 = SecretVault(
        directory: dir, dpapi: FakeDpapi(), clientIds: const ['pockettavern']);
    await vault2.load();
    expect(vault2.tokenFor('pockettavern')!.value, token1);
  });

  test('保存上游 Key 后 describe 不泄露明文', () async {
    final vault = SecretVault(
      directory: dir,
      dpapi: FakeDpapi(),
      clientIds: const ['pockettavern'],
      redactor: Redactor(),
    );
    await vault.load();
    const key = 'FAKE-KEY-DPAPI-000000000000000000000000';
    await vault.setUpstreamKey(key, verifyResult: 'ok');

    final described = jsonEncode(vault.describe());
    expect(described.contains(key), isFalse);
    expect(vault.upstreamKey!.value, key);
    expect(vault.upstreamSource, 'vault');
  });

  test('备份文件在损坏时被使用', () async {
    final vault1 = SecretVault(
        directory: dir, dpapi: FakeDpapi(), clientIds: const ['pockettavern']);
    await vault1.load();
    await vault1.setUpstreamKey('FAKE-TEST-KEY-000000000000000000000000',
        verifyResult: 'ok');
    // 再次保存会产生 .bak
    await vault1.rotateToken('pockettavern');

    final main = File('${dir.path}/secrets.dat');
    main.writeAsStringSync('not json', flush: true);

    final vault2 = SecretVault(
        directory: dir, dpapi: FakeDpapi(), clientIds: const ['pockettavern']);
    final result = await vault2.load();
    expect(result.ok, isTrue);
    expect(vault2.upstreamKey, isNotNull);
  });

  test('无法解密时隔离旧文件并重新生成令牌', () async {
    final vault1 = SecretVault(
        directory: dir, dpapi: FakeDpapi(), clientIds: const ['pockettavern']);
    await vault1.load();
    final oldToken = vault1.tokenFor('pockettavern')!.value;

    final vault2 = SecretVault(
      directory: dir,
      dpapi: FakeDpapi(failOnUnprotect: true),
      clientIds: const ['pockettavern'],
    );
    final result = await vault2.load();
    expect(result.ok, isFalse);
    expect(result.renamedTo, isNotNull);
    expect(result.message, contains('无法解开'));

    // 新令牌与旧的不同，旧文件被改名保留
    final files = dir.listSync().map((f) => f.path).toList();
    expect(
      files.any((p) => p.contains('.unreadable-')),
      isTrue,
      reason: files.join('\n'),
    );
    expect(vault2.tokenFor('pockettavern')!.value, isNot(oldToken));
  });

  test('Redactor 覆盖所有形态', () {
    final redactor = Redactor();
    redactor.register('FAKE-SECRET-KEY-000000000000000000000000', 'upstream');
    final out = redactor.redact(
      'Authorization: Bearer egw_pt_abcdefghijklmnopqrstuvwxyz12 '
      'key=FAKE-SECRET-KEY-000000000000000000000000 proxy=http://user:pass@host',
    );
    expect(out.contains('FAKE-SECRET-KEY'), isFalse);
    expect(out.contains('egw_pt_abcdefghijklmnopqrst'), isFalse);
    expect(out.contains('user:pass'), isFalse);
    expect(out.contains('[REDACTED'), isTrue);
  });
}
