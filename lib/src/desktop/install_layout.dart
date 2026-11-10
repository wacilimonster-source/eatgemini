/// 安装版布局：安装目录、开始菜单、卸载注册表项、Run 项。
///
/// 应用与安装器共用同一套路径约定（都是当前用户级，不需要管理员）。
library;

import 'dart:io' show Directory, File, Platform;

import 'win_registry.dart';

const String kRunKeyPath = r'Software\Microsoft\Windows\CurrentVersion\Run';
const String kRunValueName = 'eatgemini';
const String kUninstallKeyPath =
    r'Software\Microsoft\Windows\CurrentVersion\Uninstall\eatgemini';
const String kDisplayName = 'eatgemini';
const String kPublisher = 'eatgemini';

String get _sep => Platform.pathSeparator;

String _localAppData() {
  final local = Platform.environment['LOCALAPPDATA'];
  return (local == null || local.isEmpty) ? Directory.current.path : local;
}

/// 安装目录：%LOCALAPPDATA%\Programs\eatgemini。
String defaultInstallDir() =>
    '${_localAppData()}${_sep}Programs${_sep}eatgemini';

/// 数据目录：与便携版共用 %LOCALAPPDATA%\eatgemini。
String defaultDataDir() => '${_localAppData()}${_sep}eatgemini';

String defaultUpdatesDir() => '${defaultDataDir()}${_sep}updates';

/// 开始菜单程序组目录；没有 APPDATA 时返回空串（跳过快捷方式）。
String startMenuAppDir() {
  final roaming = Platform.environment['APPDATA'];
  if (roaming == null || roaming.isEmpty) return '';
  return '$roaming${_sep}Microsoft${_sep}Windows${_sep}Start Menu'
      '${_sep}Programs${_sep}eatgemini';
}

String installedExePath([String? installDir]) =>
    '${installDir ?? defaultInstallDir()}${_sep}eatgemini.exe';

String uninstallerPath([String? installDir]) =>
    '${installDir ?? defaultInstallDir()}${_sep}uninstall.exe';

String appShortcutPath() {
  final dir = startMenuAppDir();
  return dir.isEmpty ? '' : '$dir${_sep}eatgemini.lnk';
}

String uninstallShortcutPath() {
  final dir = startMenuAppDir();
  return dir.isEmpty ? '' : '$dir${_sep}卸载 eatgemini.lnk';
}

bool pathsEqual(String a, String b) {
  String norm(String s) => s
      .trim()
      .replaceAll('/', '\\')
      .replaceAll(RegExp(r'\\+$'), '')
      .toLowerCase();
  return norm(a) == norm(b);
}

/// 「应用和功能」卸载项（HKCU）。
void writeUninstallEntry({
  required RegistryStore registry,
  required String installDir,
  required String version,
}) {
  registry.writeString(kUninstallKeyPath, 'DisplayName', kDisplayName);
  registry.writeString(kUninstallKeyPath, 'DisplayVersion', version);
  registry.writeString(kUninstallKeyPath, 'Publisher', kPublisher);
  registry.writeString(kUninstallKeyPath, 'InstallLocation', installDir);
  registry.writeString(kUninstallKeyPath, 'DisplayIcon',
      installedExePath(installDir));
  registry.writeString(
      kUninstallKeyPath, 'UninstallString', '"${uninstallerPath(installDir)}"');
}

void removeUninstallEntry({required RegistryStore registry}) {
  registry.deleteKey(kUninstallKeyPath);
}

class InstallationInfo {
  const InstallationInfo({
    required this.mode,
    this.installDir,
    this.displayVersion,
    this.uninstaller,
  });

  /// installed（由安装版安装） / portable（便携版直接运行）。
  final String mode;
  final String? installDir;
  final String? displayVersion;
  final String? uninstaller;

  bool get isInstalled => mode == 'installed';

  Map<String, Object?> toJson() => {
        'mode': mode,
        'isInstalled': isInstalled,
        if (installDir != null) 'installDir': installDir,
        if (displayVersion != null) 'displayVersion': displayVersion,
        if (uninstaller != null) 'uninstaller': uninstaller,
      };
}

/// 判断当前进程是安装版还是便携版：卸载项里的安装目录与 exe 所在目录一致。
InstallationInfo readInstallation({
  RegistryStore? registry,
  String? executablePath,
}) {
  final store = registry ?? const WindowsRegistry();
  final location = store.readString(kUninstallKeyPath, 'InstallLocation');
  final exe = executablePath ?? Platform.resolvedExecutable;
  final exeDir = File(exe).parent.path;
  final installed = location != null && pathsEqual(location, exeDir);
  return InstallationInfo(
    mode: installed ? 'installed' : 'portable',
    installDir: installed ? location : null,
    displayVersion: store.readString(kUninstallKeyPath, 'DisplayVersion'),
    uninstaller: store.readString(kUninstallKeyPath, 'UninstallString'),
  );
}
