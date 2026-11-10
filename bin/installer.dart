/// eatgemini 安装版（自解压安装器）。
///
/// 构建时把便携版 eatgemini.exe 追加到本 exe 尾部（见 tool/attach_payload.dart）。
/// 安装到 %LOCALAPPDATA%\Programs\eatgemini（当前用户，不需要管理员），
/// 创建开始菜单快捷方式、写 HKCU 卸载项；卸载时清理并保留用户数据目录。
///
/// 编译产物是 GUI 子系统，所有交互走 MessageBox，日志写数据目录。
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:eatgemini/src/desktop/autostart.dart';
import 'package:eatgemini/src/desktop/install_layout.dart';
import 'package:eatgemini/src/desktop/setup_payload.dart';
import 'package:eatgemini/src/desktop/shortcuts.dart';
import 'package:eatgemini/src/desktop/win_registry.dart';
import 'package:ffi/ffi.dart';
import 'package:win32/win32.dart';

const String _setupVersion =
    String.fromEnvironment('SETUP_VERSION', defaultValue: 'dev');

const int _mbOk = 0x00000000;
const int _mbOkCancel = 0x00000001;
const int _mbYesNo = 0x00000004;
const int _mbIconInfo = 0x00000040;
const int _mbIconError = 0x00000010;
const int _mbIconQuestion = 0x00000020;
const int _idOk = 1;
const int _idYes = 6;

class _Options {
  bool silent = false;
  bool uninstall = false;
  bool noLaunch = false;
  bool autostart = false;
  bool fromUpdate = false;
  bool fromCopy = false;
  bool versionOnly = false;
  bool help = false;
  String? installDir;
  String? dataDir;
  String? versionOut;
}

Future<void> main(List<String> args) async {
  final options = _parseArgs(args);
  if (options.versionOnly) {
    final text = 'eatgemini-setup $_setupVersion';
    final out = options.versionOut;
    if (out != null) {
      try {
        File(out).writeAsStringSync(text, flush: true);
      } catch (_) {
        exit(1);
      }
    }
    return;
  }
  if (options.help) {
    _message(
      '用法：eatgemini-setup [--silent] [--uninstall] '
      '[--install-dir <路径>] [--no-launch] [--autostart]\n\n'
      '不带参数：显示安装向导。--silent 用于自动化升级。',
      'eatgemini 安装程序',
      _mbOk | _mbIconInfo,
    );
    return;
  }
  try {
    final code = options.uninstall
        ? await _uninstall(options)
        : await _install(options);
    exit(code);
  } catch (e, stack) {
    _log('安装器异常：$e\n$stack');
    if (!options.silent) {
      _message('操作失败：$e\n\n详细见数据目录 logs/installer.log',
          'eatgemini 安装程序', _mbOk | _mbIconError);
    }
    exit(1);
  }
}

_Options _parseArgs(List<String> args) {
  final options = _Options();
  for (var i = 0; i < args.length; i++) {
    switch (args[i]) {
      case '--silent':
        options.silent = true;
      case '--uninstall':
        options.uninstall = true;
      case '--no-launch':
        options.noLaunch = true;
      case '--autostart':
        options.autostart = true;
      case '--from-update':
        options.fromUpdate = true;
      case '--from-copy':
        options.fromCopy = true;
      case '--version':
        options.versionOnly = true;
      case '--help':
      case '-h':
        options.help = true;
      case '--install-dir':
        if (i + 1 < args.length) options.installDir = args[++i];
      case '--data-dir':
        if (i + 1 < args.length) options.dataDir = args[++i];
      case '--version-out':
        if (i + 1 < args.length) options.versionOut = args[++i];
    }
  }
  return options;
}

// ---------------------------------------------------------------- 安装

Future<int> _install(_Options options) async {
  if (!Platform.isWindows) {
    _error(options, '安装版目前只支持 Windows 10/11');
    return 1;
  }
  final registry = const WindowsRegistry();
  final bundle = readSetupBundle(Platform.resolvedExecutable);
  if (bundle == null) {
    _error(options, '安装包不完整（找不到内嵌的程序）。请重新下载安装版。');
    return 1;
  }
  if (!_isPe(bundle.payload)) {
    _error(options, '内嵌程序校验失败，安装包可能已损坏。');
    return 1;
  }

  final previous = registry.readString(kUninstallKeyPath, 'InstallLocation');
  final dir = options.installDir ??
      (previous != null && previous.isNotEmpty
          ? previous
          : defaultInstallDir());
  final exePath = installedExePath(dir);
  final upgrade = File(exePath).existsSync();
  final dataDir = options.dataDir ?? defaultDataDir();

  if (!options.silent) {
    final answer = _message(
      '${upgrade ? '升级' : '安装'} eatgemini v$_setupVersion\n\n'
      '位置：$dir\n\n'
      '将创建开始菜单快捷方式与「应用和功能」卸载项。\n'
      'API Key、配置与用量数据保存在 $dataDir，卸载不会删除。\n\n'
      '继续${upgrade ? '升级' : '安装'}？',
      'eatgemini ${upgrade ? '升级' : '安装'}',
      _mbOkCancel | _mbIconInfo,
    );
    if (answer != _idOk) {
      _log('用户取消安装');
      return 0;
    }
  }

  final targetDir = Directory(dir);
  if (!targetDir.existsSync()) targetDir.createSync(recursive: true);

  // 先写新文件为 .new；替换失败（旧进程占用）时请求旧实例退出再重试。
  final exeNew = File('$exePath.new');
  exeNew.writeAsBytesSync(bundle.payload, flush: true);
  var replaced = _replaceFile(exeNew, exePath);
  if (!replaced) {
    _log('exe 被占用，请求运行中的 eatgemini 退出');
    await _requestAppQuit(dataDir);
    for (var attempt = 0; attempt < 4 && !replaced; attempt++) {
      await Future<void>.delayed(const Duration(milliseconds: 900));
      replaced = _replaceFile(exeNew, exePath);
    }
  }
  if (!replaced) {
    _error(options,
        '无法覆盖 $exePath。请先从托盘「退出 eatgemini」后重新运行安装程序。');
    return 1;
  }

  // 卸载程序 = 安装器本体（剥离 payload），不带内嵌程序，体积更小。
  final uninstallNew = File('${uninstallerPath(dir)}.new');
  uninstallNew.writeAsBytesSync(bundle.baseExe, flush: true);
  if (!_replaceFile(uninstallNew, uninstallerPath(dir))) {
    _log('警告：uninstall.exe 写入失败（可能正在运行旧卸载程序）');
  }

  // 开始菜单快捷方式（失败不阻断安装）。
  final menuDir = startMenuAppDir();
  if (menuDir.isNotEmpty) {
    try {
      final folder = Directory(menuDir);
      if (!folder.existsSync()) folder.createSync(recursive: true);
      final appLnk = createShortcut(
        linkPath: appShortcutPath(),
        targetPath: exePath,
        description: 'eatgemini · Gemini 额度路由网关',
        iconPath: exePath,
      );
      final uninstallLnk = createShortcut(
        linkPath: uninstallShortcutPath(),
        targetPath: uninstallerPath(dir),
        arguments: '--uninstall',
        description: '卸载 eatgemini',
        iconPath: uninstallerPath(dir),
      );
      _log('快捷方式：app=$appLnk uninstall=$uninstallLnk');
    } catch (e) {
      _log('快捷方式创建失败：$e');
    }
  }

  writeUninstallEntry(
      registry: registry, installDir: dir, version: _setupVersion);

  // 升级后 Run 值可能仍指向旧路径：仅在已启用时修正，不改变开关状态。
  final runValue = registry.readString(kRunKeyPath, kRunValueName);
  if (runValue != null) {
    registry.writeString(
        kRunKeyPath, kRunValueName, buildAutostartCommand(exePath));
  } else if (options.autostart) {
    registry.writeString(
        kRunKeyPath, kRunValueName, buildAutostartCommand(exePath));
  }

  _log('${upgrade ? '升级' : '安装'}完成：v$_setupVersion → $exePath');
  if (!options.silent) {
    _message(
      '${upgrade ? '已升级' : '已安装'} eatgemini v$_setupVersion。\n\n'
      '开始菜单可找到 eatgemini；卸载请用「卸载 eatgemini」或系统'
      '「应用和功能」。\n数据目录：$dataDir',
      'eatgemini 安装完成',
      _mbOk | _mbIconInfo,
    );
  }

  var launch = options.fromUpdate && !options.noLaunch;
  if (!options.silent && !options.noLaunch && !launch) {
    launch = _message('现在启动 eatgemini 吗？', 'eatgemini',
            _mbYesNo | _mbIconQuestion) ==
        _idYes;
  }
  if (launch) {
    try {
      await Process.start(exePath, const [], mode: ProcessStartMode.detached);
      _log('已启动 eatgemini');
    } catch (e) {
      _log('启动失败：$e');
    }
  }
  return 0;
}

/// 原子替换：先把旧文件改名成 .old（Windows 允许重命名正在运行的 exe），
/// 再把新文件就位；任何一步失败都回滚，绝不留下「删了旧的、新的没写上」。
bool _replaceFile(File staged, String targetPath) {
  final target = File(targetPath);
  var backup = File('$targetPath.old');
  try {
    if (backup.existsSync()) {
      try {
        backup.deleteSync();
      } catch (_) {
        // 上一次替换留下的旧映像仍被占用：换唯一名，避免 rename 冲突。
        backup = File(
            '$targetPath.old-${DateTime.now().millisecondsSinceEpoch}');
      }
    }
    if (!target.existsSync()) {
      staged.renameSync(targetPath);
      return true;
    }
    target.renameSync(backup.path);
    try {
      staged.renameSync(targetPath);
    } catch (_) {
      try {
        backup.renameSync(targetPath);
      } catch (_) {}
      return false;
    }
    try {
      backup.deleteSync();
    } catch (_) {
      _log('旧文件 $targetPath.old 暂被占用，将在下次安装/重启后清理');
    }
    return true;
  } catch (_) {
    return false;
  }
}

bool _isPe(Uint8List bytes) =>
    bytes.length > 0x40 && bytes[0] == 0x4D && bytes[1] == 0x5A; // MZ

// ---------------------------------------------------------------- 卸载

Future<int> _uninstall(_Options options) async {
  if (!Platform.isWindows) {
    _error(options, '卸载只支持 Windows');
    return 1;
  }
  final registry = const WindowsRegistry();
  final saved = registry.readString(kUninstallKeyPath, 'InstallLocation');
  final dir = options.installDir ??
      (saved != null && saved.isNotEmpty ? saved : defaultInstallDir());
  final dataDir = options.dataDir ?? defaultDataDir();

  if (!options.fromCopy && !options.silent) {
    final answer = _message(
      '卸载 eatgemini？\n\n'
      '位置：$dir\n\n'
      '将移除程序、开始菜单快捷方式、卸载项与开机自启。\n'
      '你的 API Key、配置和日志保存在 $dataDir，不会被删除。',
      'eatgemini 卸载',
      _mbOkCancel | _mbIconQuestion,
    );
    if (answer != _idOk) return 0;
  }

  // 卸载程序自身也在安装目录里：复制到临时目录由副本完成删除，
  // 避免 Windows 锁定正在运行的 exe（HKLM 延迟删除需要管理员，不好用）。
  final self = Platform.resolvedExecutable;
  if (!options.fromCopy && pathsEqual(File(self).parent.path, dir)) {
    final copy = '${Directory.systemTemp.path}${Platform.pathSeparator}'
        'eg-uninstall-${pid}.exe';
    File(self).copySync(copy);
    final args = <String>[
      '--uninstall',
      '--from-copy',
      '--install-dir',
      dir,
      '--data-dir',
      dataDir,
      if (options.silent) '--silent',
    ];
    await Process.start(copy, args, mode: ProcessStartMode.detached);
    _log('已移交临时副本卸载：$copy');
    return 0;
  }

  // 副本等原进程退出、句柄释放后再删文件。
  if (options.fromCopy) {
    await Future<void>.delayed(const Duration(milliseconds: 800));
  }
  await _requestAppQuit(dataDir);
  await Future<void>.delayed(const Duration(milliseconds: 1200));

  var failed = false;
  for (final path in [
    installedExePath(dir),
    uninstallerPath(dir),
    '${installedExePath(dir)}.new',
    '${uninstallerPath(dir)}.new',
  ]) {
    try {
      final file = File(path);
      if (file.existsSync()) file.deleteSync();
    } catch (e) {
      _log('删除失败 $path：$e');
      failed = true;
    }
  }
  deleteShortcut(appShortcutPath());
  deleteShortcut(uninstallShortcutPath());
  final menuDir = startMenuAppDir();
  if (menuDir.isNotEmpty) {
    try {
      final folder = Directory(menuDir);
      if (folder.existsSync() && folder.listSync().isEmpty) {
        folder.deleteSync();
      }
    } catch (_) {}
  }
  removeUninstallEntry(registry: registry);
  registry.deleteValue(kRunKeyPath, kRunValueName);
  try {
    final folder = Directory(dir);
    if (folder.existsSync() && folder.listSync().isEmpty) {
      folder.deleteSync();
    }
  } catch (_) {}

  if (options.fromCopy) {
    _cleanupUninstallCopies();
  }
  _log('卸载完成：$dir（数据目录保留：$dataDir）');
  if (!options.silent) {
    _message(
      '已卸载 eatgemini。\n\n'
      '${failed ? '部分文件可能仍被占用，重启后会自动清理。\n\n' : ''}'
      '数据目录（Key、配置、日志）保留在：$dataDir\n'
      '如不再需要，可手动删除该目录。',
      'eatgemini 卸载完成',
      _mbOk | _mbIconInfo,
    );
  }
  return failed ? 2 : 0;
}

// ---------------------------------------------------------------- 辅助

/// 卸载副本完成后清理 temp 里的历史副本（自身仍被进程占用，留待下次清理）。
/// 避免多次升级/卸载在临时目录里累积几十 MB 的 exe。
void _cleanupUninstallCopies() {
  try {
    final self = Platform.resolvedExecutable.toLowerCase();
    for (final entity in Directory.systemTemp.listSync()) {
      if (entity is! File) continue;
      final name = entity.path.split(Platform.pathSeparator).last;
      if (!name.startsWith('eg-uninstall-') || !name.endsWith('.exe')) {
        continue;
      }
      if (entity.path.toLowerCase() == self) continue;
      try {
        entity.deleteSync();
      } catch (_) {}
    }
  } catch (_) {}
}

/// 通过数据目录里的 instance.json 请求运行中的实例优雅退出。
Future<void> _requestAppQuit(String dataDir) async {
  final file = File('$dataDir${Platform.pathSeparator}instance.json');
  if (!file.existsSync()) return;
  Map<String, Object?> info;
  try {
    final decoded = jsonDecode(file.readAsStringSync());
    if (decoded is! Map) return;
    info = decoded.cast<String, Object?>();
  } catch (_) {
    return;
  }
  final port = (info['consolePort'] as num?)?.toInt() ?? 0;
  final nonce = (info['ipcNonce'] ?? '').toString();
  if (port <= 0 || nonce.isEmpty) return;
  final client = HttpClient()
    ..connectionTimeout = const Duration(seconds: 2);
  try {
    final req = await client.postUrl(
      Uri.parse('http://127.0.0.1:$port/ipc/quit'),
    );
    req.headers.set('x-eatgemini-ipc', nonce);
    final resp = await req.close().timeout(const Duration(seconds: 2));
    await resp.drain<void>();
    _log('已请求旧实例退出（127.0.0.1:$port）');
  } catch (e) {
    _log('请求旧实例退出失败（可能并未运行）：$e');
  } finally {
    client.close(force: true);
  }
}

void _error(_Options options, String message) {
  _log('错误：$message');
  if (!options.silent) {
    _message(message, 'eatgemini 安装程序', _mbOk | _mbIconError);
  }
}

int _message(String text, String title, int flags) {
  if (!Platform.isWindows) return 0;
  final nativeTitle = title.toNativeUtf16();
  final nativeText = text.toNativeUtf16();
  try {
    return MessageBox(0, nativeText, nativeTitle, flags);
  } finally {
    malloc.free(nativeTitle);
    malloc.free(nativeText);
  }
}

void _log(String line) {
  try {
    final dir = Directory(
        '${defaultDataDir()}${Platform.pathSeparator}logs');
    if (!dir.existsSync()) dir.createSync(recursive: true);
    File('${dir.path}${Platform.pathSeparator}installer.log')
        .writeAsStringSync('${DateTime.now().toIso8601String()} $line\n',
            mode: FileMode.append, flush: true);
  } catch (_) {}
}
