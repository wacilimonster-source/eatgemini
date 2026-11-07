/// eatgemini 入口。
///
/// 发布版 exe 的子系统会被改成 GUI（tool/set_subsystem.dart），因此这里
/// 不能依赖 stdout：所有输出走日志文件，`--console` 才回显。
library;

import 'dart:async';
import 'dart:io';

import 'package:eatgemini/src/app/app_controller.dart';

const String _version =
    String.fromEnvironment('APP_VERSION', defaultValue: '1.0.0');
const String _commit = String.fromEnvironment('GIT_COMMIT', defaultValue: 'dev');

/// print 重定向目标（Logger 就绪后由 AppController 设置）。
void Function(String line)? _printSink;

Future<void> main(List<String> args) async {
  final options = _parseArgs(args);

  if (options.versionOnly) {
    final text = 'eatgemini $_version ($_commit)';
    final out = options.versionOut;
    if (out != null) {
      try {
        File(out).writeAsStringSync(text, flush: true);
      } catch (_) {
        exitCode = 1;
        return;
      }
    } else if (options.console) {
      stdout.writeln(text);
    }
    return;
  }

  await runZonedGuarded(
    () async {
      final app = AppController(version: _version, buildCommit: _commit);
      _wireSignals(app);
      final code = await app.start(options);
      exit(code);
    },
    (error, stack) {
      _printSink?.call('未捕获异常：$error\n$stack');
      try {
        final dir = options.dataDirOverride ?? _defaultLogDir();
        if (dir != null) {
          final file = File('$dir${Platform.pathSeparator}eatgemini-crash.log');
          file.writeAsStringSync(
            '${DateTime.now().toUtc().toIso8601String()} $error\n$stack\n',
            mode: FileMode.append,
            flush: true,
          );
        }
      } catch (_) {}
      if (options.console) {
        stderr.writeln('未捕获异常：$error');
      }
      exit(1);
    },
    zoneSpecification: ZoneSpecification(
      print: (self, parent, zone, line) {
        _printSink?.call(line);
        if (options.console) parent.print(zone, line);
      },
    ),
  );
}

void _wireSignals(AppController app) {
  // Windows 不支持 SIGTERM；watch() 的错误是异步抛出的，必须挂在 onError 上。
  final signals = <ProcessSignal>[
    ProcessSignal.sigint,
    if (!Platform.isWindows) ProcessSignal.sigterm,
  ];
  for (final signal in signals) {
    try {
      signal.watch().listen(
            (_) => app.shutdown(),
            onError: (_) {},
          );
    } catch (_) {}
  }
}

String? _defaultLogDir() {
  final local = Platform.environment['LOCALAPPDATA'];
  if (local == null) return null;
  final dir = Directory('$local${Platform.pathSeparator}eatgemini'
      '${Platform.pathSeparator}logs');
  try {
    if (!dir.existsSync()) dir.createSync(recursive: true);
    return dir.path;
  } catch (_) {
    return null;
  }
}

AppOptions _parseArgs(List<String> args) {
  var minimized = false;
  var console = false;
  var versionOnly = false;
  var openWindow = true;
  String? dataDir;
  String? versionOut;

  for (var i = 0; i < args.length; i++) {
    final arg = args[i];
    switch (arg) {
      case '--minimized':
        minimized = true;
        openWindow = false;
      case '--console':
        console = true;
      case '--version':
        versionOnly = true;
      case '--no-window':
        openWindow = false;
      case '--data-dir':
        if (i + 1 < args.length) dataDir = args[++i];
      case '--version-out':
        if (i + 1 < args.length) versionOut = args[++i];
      case '--help':
      case '-h':
        if (console) {
          stdout.writeln('用法：eatgemini [--minimized] [--console] '
              '[--data-dir <path>] [--version [--version-out <file>]]');
        }
      default:
        break;
    }
  }

  return AppOptions(
    minimized: minimized,
    console: console,
    dataDirOverride: dataDir,
    versionOut: versionOut,
    versionOnly: versionOnly,
    openWindow: openWindow,
  );
}
