import 'dart:io';

import 'package:eatgemini/src/desktop/autostart.dart';
import 'package:eatgemini/src/desktop/install_layout.dart';
import 'package:eatgemini/src/desktop/win_registry.dart';
import 'package:test/test.dart';

void main() {
  test('自启命令带引号（含空格路径）且可反解', () {
    const path = r'C:\Users\me\Local Settings\eatgemini.exe';
    final command = buildAutostartCommand(path);
    expect(command, '"$path" --minimized');
    expect(exePathFromCommand(command), path);
    expect(exePathFromCommand('eatgemini.exe --minimized'), isNull);
  });

  test('内存注册表读写删与幂等删除', () {
    final registry = InMemoryRegistry();
    expect(registry.readString('Software\\X', 'v'), isNull);
    expect(registry.writeString('Software\\X', 'v', 'data'), isTrue);
    expect(registry.readString('software\\x', 'v'), 'data');
    expect(registry.deleteValue('Software\\X', 'v'), isTrue);
    expect(registry.readString('Software\\X', 'v'), isNull);
    expect(registry.deleteValue('Software\\Never', 'v'), isTrue);
    expect(registry.writeString('Software\\Y', 'v', 'data'), isTrue);
    expect(registry.deleteKey('Software\\Y'), isTrue);
    expect(registry.readString('Software\\Y', 'v'), isNull);
  });

  test('AutostartManager：开关、状态与路径自愈', () {
    final registry = InMemoryRegistry();
    final exe = r'C:\Apps\eatgemini\eatgemini.exe';
    final manager =
        AutostartManager(registry: registry, executablePath: exe);

    expect(manager.describe().enabled, isFalse);
    expect(manager.setEnabled(true), isTrue);
    final state = manager.describe();
    expect(state.enabled, isTrue);
    expect(state.targetsCurrentExe, isTrue);
    expect(state.command, buildAutostartCommand(exe));

    // 模拟 exe 被移动：注册表里仍是旧路径 → 自愈重写。
    registry.writeString(kRunKeyPath, kRunValueName,
        buildAutostartCommand(r'C:\Old\eatgemini.exe'));
    expect(manager.describe().targetsCurrentExe, isFalse);
    expect(manager.repairIfStale(), isTrue);
    expect(manager.describe().targetsCurrentExe, isTrue);
    expect(manager.repairIfStale(), isFalse); // 已是当前路径，不再写

    expect(manager.clear(), isTrue);
    expect(manager.describe().enabled, isFalse);
  });

  test('非 Windows 平台优雅降级', () {
    final manager = AutostartManager(
      registry: InMemoryRegistry(supported: false),
      executablePath: '/opt/eatgemini/eatgemini',
    );
    expect(manager.supported, isFalse);
    expect(manager.setEnabled(true), isFalse);
    expect(manager.describe().enabled, isFalse);
    expect(manager.describe().supported, isFalse);
  });

  test('卸载项与安装形态判断', () {
    final registry = InMemoryRegistry();
    final dir =
        '${Directory.systemTemp.path}${Platform.pathSeparator}eg-installed';
    writeUninstallEntry(
        registry: registry, installDir: dir, version: '0.2.4');
    expect(registry.readString(kUninstallKeyPath, 'DisplayVersion'),
        '0.2.4');
    expect(registry.readString(kUninstallKeyPath, 'InstallLocation'), dir);
    expect(registry.readString(kUninstallKeyPath, 'UninstallString'),
        '"${uninstallerPath(dir)}"');

    final exe = '$dir${Platform.pathSeparator}eatgemini.exe';
    final installed = readInstallation(registry: registry,
        executablePath: exe);
    expect(installed.mode, 'installed');
    expect(installed.isInstalled, isTrue);
    expect(installed.installDir, dir);
    expect(installed.toJson()['displayVersion'], '0.2.4');

    final portable = readInstallation(
        registry: registry,
        executablePath: '${Directory.systemTemp.path}'
            '${Platform.pathSeparator}eatgemini.exe');
    expect(portable.mode, 'portable');

    removeUninstallEntry(registry: registry);
    expect(registry.readString(kUninstallKeyPath, 'DisplayVersion'), isNull);
  });

  test('pathsEqual 忽略大小写、斜杠方向与尾部斜杠', () {
    expect(pathsEqual(r'C:\Apps\eatgemini\\', 'c:/apps/EATgemini'), isTrue);
    expect(pathsEqual(r'C:\Apps\eatgemini', r'C:\Apps\other'), isFalse);
  });
}
