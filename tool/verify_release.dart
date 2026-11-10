/// 发布物校验：GUI 子系统、不含开发者密钥、版本号正确（桌面文档 §12.2）。
///
/// 用法：`dart run tool/verify_release.dart build/eatgemini.exe --version 1.0.0`
library;

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:eatgemini/src/desktop/setup_payload.dart';

Future<void> main(List<String> args) async {
  if (args.isEmpty) {
    stderr.writeln('用法：dart run tool/verify_release.dart <exe> [--version x.y.z]');
    exit(1);
  }
  final path = args[0];
  final versionIndex = args.indexOf('--version');
  final expectedVersion =
      versionIndex >= 0 && versionIndex + 1 < args.length ? args[versionIndex + 1] : null;

  var failures = 0;
  void check(bool ok, String name) {
    stdout.writeln('  ${ok ? '✓' : '✗'} $name');
    if (!ok) failures++;
  }

  final bytes = await File(path).readAsBytes();

  // ---- 子系统 ----
  final peOffset = ByteData.sublistView(bytes, 0x3C, 0x40)
      .getUint32(0, Endian.little);
  final subsystem = ByteData.sublistView(bytes, peOffset + 24 + 68)
      .getUint16(0, Endian.little);
  check(subsystem == 2, 'PE 子系统为 GUI（当前 $subsystem）');

  // ---- 密钥扫描 ----
  final text = utf8.decode(bytes, allowMalformed: true);
  final googleKey = RegExp(r'AIza[0-9A-Za-z_\-]{30,}');
  final clientToken = RegExp(r'egw_(?:st|pt)_[0-9A-Za-z_\-]{43}');
  final googleMatches = googleKey.allMatches(text).toList();
  final tokenMatches = clientToken.allMatches(text).toList();
  check(googleMatches.isEmpty, '不含 Google API Key 模式（命中 ${googleMatches.length}）');
  check(tokenMatches.isEmpty, '不含客户端令牌模式（命中 ${tokenMatches.length}）');

  // ---- 界面资源无外链 ----
  // 资源以 Dart 字符串常量内嵌；检查整体二进制中的外链模式（排除 Dart SDK 自带的字符串）。
  final external = RegExp(
    r'https://(?!generativelanguage\.googleapis\.com)[a-z0-9.-]+',
    caseSensitive: false,
  );
  final hits = external
      .allMatches(text)
      .map((m) => m.group(0) ?? '')
      .where((h) => h.isNotEmpty)
      .toSet()
      .toList();
  // 允许清单：Dart 运行时/文档中出现、与运行行为无关的地址。
  const allow = {
    'https://dart.dev',
    'https://api.dart.dev',
    'https://github.com',
    // 检查更新：只有用户主动检查/开启自动检查才会访问这两个域名。
    'https://api.github.com',
    'https://raw.githubusercontent.com',
    'https://pub.dev',
    'https://storage.googleapis.com',
    'https://fonts.googleapis.com',
    'https://fonts.gstatic.com',
    'https://www.google.com',
    'https://schemas.google.com',
    'https://developer.mozilla.org',
    'https://tools.ietf.org',
    'https://www.rfc-editor.org',
    'https://aomedia.org',
    'https://chromium.googlesource.com',
    'https://issues.chromium.org',
    'https://dartbug.com',
    'https://learn.microsoft.com',
  };
  final unexpected = hits
      .where((h) => !allow.any((a) => h.startsWith(a)))
      .toSet()
      .toList();
  check(unexpected.isEmpty, '界面资源不含未允许的外链（${unexpected.take(5).join(', ')}）');

  // ---- 版本 ----
  if (expectedVersion != null) {
    final tmp = File(
        '${Directory.systemTemp.path}/eatgemini-version-${DateTime.now().millisecondsSinceEpoch}');
    final result = await Process.run(
      path,
      ['--version', '--version-out', tmp.path],
      stdoutEncoding: utf8,
    );
    final ok = tmp.existsSync() &&
        File(tmp.path).readAsStringSync().contains(expectedVersion);
    check(ok, '--version 输出 $expectedVersion（exit ${result.exitCode}）');
    try {
      tmp.deleteSync();
    } catch (_) {}
  }

  // ---- 安装版：尾部 payload 完整 ----
  if (args.contains('--expect-payload')) {
    final bundle = readSetupBundle(path);
    final valid = bundle != null &&
        bundle.payload.length > 0x40 &&
        bundle.payload[0] == 0x4D &&
        bundle.payload[1] == 0x5A;
    check(valid,
        '安装版含完整的内嵌程序（${bundle?.payload.length ?? 0} 字节）');
  }

  final size = bytes.length / (1024 * 1024);
  stdout.writeln('  体积：${size.toStringAsFixed(1)} MB');
  check(size < 25, '体积 ≤ 25 MB');

  if (failures > 0) {
    stdout.writeln('VERIFY FAIL（$failures）');
    exit(1);
  }
  stdout.writeln('VERIFY PASS');
}
