/// 生成仓库根目录用的 update.json（检查更新的回退源）。
///
/// 用法：dart run tool/make_update_manifest.dart --version 0.2.4
///       [--out build/update.json] [--notes "..."] [--tag v0.2.4]
/// 发布时把该文件提交到 main 分支根目录，客户端即可在 GitHub API
/// 被限流时从 raw.githubusercontent.com 读到同一份信息。
library;

import 'dart:convert';
import 'dart:io';

const String _owner = 'wacilimonster-source';
const String _repo = 'eatgemini';

Future<void> main(List<String> args) async {
  String? flag(String name) {
    final i = args.indexOf(name);
    return (i >= 0 && i + 1 < args.length) ? args[i + 1] : null;
  }

  final version = flag('--version');
  if (version == null || version.trim().isEmpty) {
    stderr.writeln('缺少 --version x.y.z');
    exit(1);
  }
  final v = version.trim();
  final tag = flag('--tag') ?? 'v$v';
  final outPath = flag('--out') ?? 'build/update.json';
  final notes = flag('--notes') ?? 'eatgemini $v';
  final base =
      'https://github.com/$_owner/$_repo/releases/download/$tag';

  final installerName = 'eatgemini-setup-v$v.exe';
  final portableName = 'eatgemini-v$v.exe';
  final installerFile = File('build/$installerName');
  final manifest = <String, Object?>{
    'version': v,
    'publishedAt': DateTime.now().toUtc().toIso8601String(),
    'notes': notes,
    'releaseUrl': 'https://github.com/$_owner/$_repo/releases/tag/$tag',
    'installerUrl': '$base/$installerName',
    'portableUrl': '$base/$portableName',
    'installerSize':
        installerFile.existsSync() ? installerFile.lengthSync() : 0,
  };

  final out = File(outPath);
  if (!out.parent.existsSync()) out.parent.createSync(recursive: true);
  out.writeAsStringSync(
    '${const JsonEncoder.withIndent('  ').convert(manifest)}\n',
    flush: true,
  );
  stdout.writeln('已生成 ${out.path}（版本 $v）');
}
