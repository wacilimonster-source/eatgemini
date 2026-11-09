/// 数据目录、配置存储与单实例。
///
/// 规则来源：桌面文档 §5、§8、§4.2。
library;

import 'dart:convert';
import 'dart:io';

import '../core/config.dart';

class DataDir {
  DataDir(this.root);

  final Directory root;

  Directory get state => Directory('${root.path}${Platform.pathSeparator}state');
  Directory get logs => Directory('${root.path}${Platform.pathSeparator}logs');
  Directory get exports =>
      Directory('${root.path}${Platform.pathSeparator}exports');
  Directory get webview =>
      Directory('${root.path}${Platform.pathSeparator}webview');

  File get configFile =>
      File('${root.path}${Platform.pathSeparator}config.json');
  File get configBackup =>
      File('${root.path}${Platform.pathSeparator}config.json.bak');
  File get instanceFile =>
      File('${root.path}${Platform.pathSeparator}instance.json');

  String get secretsPath =>
      '${root.path}${Platform.pathSeparator}secrets.dat';

  void ensure() {
    for (final dir in [root, state, logs, exports, webview]) {
      if (!dir.existsSync()) dir.createSync(recursive: true);
    }
  }

  /// 数据目录优先级：`--data-dir` > 便携标记 > `%LOCALAPPDATA%\eatgemini`。
  static DataDir resolve({String? override, String? executablePath}) {
    if (override != null && override.trim().isNotEmpty) {
      return DataDir(Directory(override));
    }
    final exeDir = executablePath == null
        ? null
        : File(executablePath).parent;
    if (exeDir != null &&
        File('${exeDir.path}${Platform.pathSeparator}eatgemini.portable')
            .existsSync()) {
      return DataDir(
        Directory('${exeDir.path}${Platform.pathSeparator}eatgemini-data'),
      );
    }
    final local = Platform.environment['LOCALAPPDATA'];
    if (local == null || local.isEmpty) {
      return DataDir(Directory('${Directory.current.path}/eatgemini-data'));
    }
    return DataDir(Directory('$local${Platform.pathSeparator}eatgemini'));
  }
}

class ConfigStore {
  ConfigStore(this.dataDir);

  final DataDir dataDir;
  int _revision = 1;

  int get revision => _revision;

  RouterConfig load({bool writeDefaultsIfMissing = true}) {
    if (!dataDir.configFile.existsSync()) {
      final defaults = defaultConfig();
      if (writeDefaultsIfMissing) {
        write(defaults);
      }
      return defaults;
    }
    final raw = dataDir.configFile.readAsStringSync();
    return parseConfig(raw);
  }

  /// 尝试从备份恢复；失败返回 null。
  RouterConfig? tryRecover() {
    if (!dataDir.configBackup.existsSync()) return null;
    try {
      return parseConfig(dataDir.configBackup.readAsStringSync());
    } catch (_) {
      return null;
    }
  }

  /// 恢复成功后把可用配置写回主文件，并把坏文件保留为 `.corrupt-*`。
  void replaceCorruptWith(RouterConfig config) {
    final stamp = DateTime.now().millisecondsSinceEpoch;
    if (dataDir.configFile.existsSync()) {
      try {
        dataDir.configFile.renameSync(
          '${dataDir.configFile.path}.corrupt-$stamp',
        );
      } catch (_) {
        try {
          dataDir.configFile.deleteSync();
        } catch (_) {}
      }
    }
    write(config);
  }

  void write(RouterConfig config) {
    // 写完即校验一次，防止把非法快照落盘。
    final encoded = config.encode();
    parseConfig(encoded);
    if (!dataDir.root.existsSync()) dataDir.root.createSync(recursive: true);
    if (dataDir.configFile.existsSync()) {
      dataDir.configFile.copySync(dataDir.configBackup.path);
    }
    final tmp = File('${dataDir.configFile.path}.tmp');
    tmp.writeAsStringSync('$encoded\n', flush: true);
    try {
      tmp.renameSync(dataDir.configFile.path);
    } catch (_) {
      if (dataDir.configFile.existsSync()) dataDir.configFile.deleteSync();
      tmp.renameSync(dataDir.configFile.path);
    }
    _revision++;
  }

  void writeRaw(Map<String, Object?> json) {
    write(decodeConfig(json));
  }

  void restoreDefaults() {
    if (dataDir.configFile.existsSync()) {
      final stamp = DateTime.now().millisecondsSinceEpoch;
      dataDir.configFile.copySync(
        '${dataDir.configFile.path}.replaced-$stamp',
      );
    }
    write(defaultConfig());
  }
}

class InstanceInfo {
  const InstanceInfo({
    required this.pid,
    required this.consolePort,
    required this.ipcNonce,
    required this.startedAt,
  });

  final int pid;
  final int consolePort;
  final String ipcNonce;
  final String startedAt;

  Map<String, Object?> toJson() => {
        'pid': pid,
        'consolePort': consolePort,
        'ipcNonce': ipcNonce,
        'startedAt': startedAt,
      };

  static InstanceInfo? tryParse(String raw) {
    try {
      final m = jsonDecode(raw) as Map<String, Object?>;
      return InstanceInfo(
        pid: (m['pid'] as num?)?.toInt() ?? 0,
        consolePort: (m['consolePort'] as num?)?.toInt() ?? 0,
        ipcNonce: (m['ipcNonce'] ?? '').toString(),
        startedAt: (m['startedAt'] ?? '').toString(),
      );
    } catch (_) {
      return null;
    }
  }
}

/// 单实例：数据目录中的独占文件锁。
///
/// 早期版本同时用命名互斥体，但 win32 5.x 没有导出 CreateMutex，手工 FFI
/// 在 x64 上拿不到有效句柄（CreateMutexW 返回 0）。文件锁在 Windows 上是
/// 跨进程强制的，单实例语义已足够，也不再依赖额外绑定。
class SingleInstance {
  SingleInstance._(this._lockFile);

  final RandomAccessFile _lockFile;

  bool _disposed = false;

  /// 返回 null 表示已有实例在运行。
  static SingleInstance? acquire(DataDir dataDir, {String? mutexSuffix}) {
    dataDir.ensure();
    final lockFile = File(
      '${dataDir.state.path}${Platform.pathSeparator}.lock',
    );
    if (!lockFile.existsSync()) lockFile.createSync(recursive: true);
    final raf = lockFile.openSync(mode: FileMode.append);
    try {
      raf.lockSync(FileLock.exclusive);
    } on FileSystemException {
      raf.closeSync();
      return null;
    }
    return SingleInstance._(raf);
  }

  void dispose() {
    if (_disposed) return;
    _disposed = true;
    try {
      _lockFile.unlockSync();
    } catch (_) {}
    try {
      _lockFile.closeSync();
    } catch (_) {}
  }

  /// 通知已有实例打开窗口。返回是否成功。
  static Future<bool> notifyExisting(DataDir dataDir) async {
    final info = readInstance(dataDir);
    if (info == null || info.consolePort == 0) return false;
    final client = HttpClient()
      ..connectionTimeout = const Duration(seconds: 2);
    try {
      final req = await client.postUrl(
        Uri.parse('http://127.0.0.1:${info.consolePort}/ipc/show'),
      );
      req.headers.set('x-eatgemini-ipc', info.ipcNonce);
      final resp = await req.close().timeout(const Duration(seconds: 2));
      await resp.drain<void>();
      return resp.statusCode == 204;
    } catch (_) {
      return false;
    } finally {
      client.close(force: true);
    }
  }

  static InstanceInfo? readInstance(DataDir dataDir) {
    if (!dataDir.instanceFile.existsSync()) return null;
    try {
      return InstanceInfo.tryParse(dataDir.instanceFile.readAsStringSync());
    } catch (_) {
      return null;
    }
  }

  static void writeInstance(DataDir dataDir, InstanceInfo info) {
    dataDir.instanceFile
        .writeAsStringSync(jsonEncode(info.toJson()), flush: true);
  }

  static void clearInstance(DataDir dataDir) {
    try {
      if (dataDir.instanceFile.existsSync()) dataDir.instanceFile.deleteSync();
    } catch (_) {}
  }
}
