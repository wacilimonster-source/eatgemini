/// 开机自启：HKCU\...\Run 下的 eatgemini 值。
///
/// 值形如 `"C:\...\eatgemini.exe" --minimized`：登录后静默启动，不弹监控窗口。
/// 只写当前用户配置单元，不需要管理员；卸载/移动 exe 后启动时会自愈修正路径。
library;

import 'install_layout.dart';
import 'win_registry.dart';

class AutostartState {
  const AutostartState({
    required this.supported,
    required this.enabled,
    required this.targetsCurrentExe,
    required this.executablePath,
    this.command,
  });

  final bool supported;
  final bool enabled;
  final bool targetsCurrentExe;
  final String executablePath;
  final String? command;

  Map<String, Object?> toJson() => {
        'supported': supported,
        'enabled': enabled,
        'targetsCurrentExe': targetsCurrentExe,
        'executablePath': executablePath,
        if (command != null) 'command': command,
      };
}

/// 开机自启命令。路径必须加引号（Program Files 等含空格路径）。
String buildAutostartCommand(String exePath) => '"$exePath" --minimized';

/// 从 Run 值里取出可执行文件路径；格式不符返回 null。
String? exePathFromCommand(String command) {
  final match = RegExp(r'^\s*"([^"]+)"').firstMatch(command);
  return match?.group(1);
}

class AutostartManager {
  AutostartManager({
    required this.registry,
    required this.executablePath,
  });

  final RegistryStore registry;
  final String executablePath;

  bool get supported => registry.supported;

  AutostartState describe() {
    final command = supported
        ? registry.readString(kRunKeyPath, kRunValueName)
        : null;
    final path = command == null ? null : exePathFromCommand(command);
    return AutostartState(
      supported: supported,
      enabled: command != null,
      targetsCurrentExe:
          path != null && pathsEqual(path, executablePath),
      executablePath: executablePath,
      command: command,
    );
  }

  bool setEnabled(bool enabled) {
    if (!supported) return false;
    if (!enabled) return registry.deleteValue(kRunKeyPath, kRunValueName);
    return registry.writeString(
      kRunKeyPath,
      kRunValueName,
      buildAutostartCommand(executablePath),
    );
  }

  /// exe 被移动或升级后，Run 里可能指向旧路径。仅在确实过期时重写。
  bool repairIfStale() {
    final state = describe();
    if (!state.enabled || state.targetsCurrentExe) return false;
    return setEnabled(true);
  }

  /// 卸载时清理（与配置无关，只删自己的值）。
  bool clear() => registry.deleteValue(kRunKeyPath, kRunValueName);
}
