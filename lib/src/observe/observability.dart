/// 日志、脱敏与请求记录。
///
/// 硬约束（桌面文档 §7）：prompt、回复正文、Authorization、Key 一律不落盘。
/// 所有文本在写入前经过 [Redactor]。
library;

import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:io';

import '../core/telemetry.dart';

class Redactor {
  Redactor();

  final List<(String, String)> _secrets = [];

  static final _googleKey = RegExp(r'AIza[0-9A-Za-z_\-]{30,}');
  static final _clientToken = RegExp(r'egw_(?:st|pt)_[0-9A-Za-z_\-]{20,}');
  static final _bearer = RegExp(r'Bearer\s+\S+', caseSensitive: false);
  static final _proxyAuth = RegExp(r'//[^/@\s:]+:[^/@\s]*@');

  void register(String value, String label) {
    if (value.isEmpty) return;
    _secrets.add((value, '[$label]'));
    // 长值优先替换，避免短值先命中。
    _secrets.sort((a, b) => b.$1.length.compareTo(a.$1.length));
  }

  void clear() => _secrets.clear();

  String redact(String input) {
    var out = input;
    for (final s in _secrets) {
      out = out.replaceAll(s.$1, s.$2);
    }
    out = out.replaceAll(_googleKey, '[REDACTED:google_key]');
    out = out.replaceAll(_clientToken, '[REDACTED:client_token]');
    out = out.replaceAll(_bearer, 'Bearer [REDACTED]');
    out = out.replaceAll(_proxyAuth, '//[REDACTED]@');
    if (out.length > 2000) out = '${out.substring(0, 2000)}…';
    return out;
  }
}

enum LogLevel { debug, info, warn, error }

extension LogLevelX on LogLevel {
  String get label => switch (this) {
        LogLevel.debug => 'DEBUG',
        LogLevel.info => 'INFO ',
        LogLevel.warn => 'WARN ',
        LogLevel.error => 'ERROR',
      };
}

class Logger {
  Logger({
    required this.directory,
    required this.redactor,
    this.maxFileBytes = 10485760,
    this.retentionDays = 7,
    this.debugEnabled = false,
    this.onLog,
  });

  final Directory directory;
  final Redactor redactor;
  final int maxFileBytes;
  final int retentionDays;
  final bool debugEnabled;
  final void Function(LogLevel level, String line)? onLog;

  final Queue<String> recent = Queue<String>();
  File? _file;
  String? _dayKey;
  bool _disabled = false;
  final List<String> _pending = [];

  Future<void> init() async {
    try {
      if (!directory.existsSync()) directory.createSync(recursive: true);
      _rotateIfNeeded();
      _cleanupOld();
    } catch (_) {
      _disabled = true;
    }
  }

  void _rotateIfNeeded() {
    final now = DateTime.now();
    final key =
        '${now.year}${now.month.toString().padLeft(2, '0')}${now.day.toString().padLeft(2, '0')}';
    if (_dayKey == key && _file != null) {
      if (_file!.existsSync() && _file!.lengthSync() < maxFileBytes) return;
      if (_file!.existsSync()) {
        final rotated =
            '${_file!.path}.${DateTime.now().millisecondsSinceEpoch}';
        try {
          _file!.renameSync(rotated);
        } catch (_) {}
      }
    }
    _dayKey = key;
    _file = File('${directory.path}${Platform.pathSeparator}eatgemini-$key.log');
  }

  void _cleanupOld() {
    final cutoff = DateTime.now().subtract(Duration(days: retentionDays));
    for (final f in directory.listSync()) {
      if (f is! File) continue;
      final name = f.uri.pathSegments.last;
      if (!name.startsWith('eatgemini-')) continue;
      try {
        if (f.lastModifiedSync().isBefore(cutoff)) f.deleteSync();
      } catch (_) {}
    }
  }

  void log(LogLevel level, String message, {String? tag}) {
    if (level == LogLevel.debug && !debugEnabled) return;
    final line =
        '${DateTime.now().toUtc().toIso8601String()} ${level.label} '
        '${tag == null ? '' : '[$tag] '}${redactor.redact(message)}';
    recent.addLast(line);
    while (recent.length > 500) {
      recent.removeFirst();
    }
    onLog?.call(level, line);
    if (_disabled) return;
    _pending.add(line);
    if (_pending.length == 1) {
      // 合并写入，避免每条日志都打开文件。
      Timer(Duration.zero, _flush);
    }
  }

  void _flush() {
    final lines = _pending.join('\n');
    _pending.clear();
    try {
      _rotateIfNeeded();
      _file?.writeAsStringSync('$lines\n', mode: FileMode.append, flush: true);
    } catch (_) {
      _disabled = true;
    }
  }

  void debug(String m, {String? tag}) => log(LogLevel.debug, m, tag: tag);
  void info(String m, {String? tag}) => log(LogLevel.info, m, tag: tag);
  void warn(String m, {String? tag}) => log(LogLevel.warn, m, tag: tag);
  void error(String m, {String? tag}) => log(LogLevel.error, m, tag: tag);

  Future<void> close() async {
    _flush();
  }
}

/// 请求记录：内存环形 + 每日 jsonl。
class RequestLog {
  RequestLog({
    required this.directory,
    required this.capacity,
    required this.redactor,
    this.retentionDays = 7,
  });

  final Directory directory;
  final int capacity;
  final Redactor redactor;
  final int retentionDays;

  final List<Map<String, Object?>> _entries = [];
  final Map<String, Map<String, Object?>> _attempts = {};

  List<Map<String, Object?>> get entries =>
      List.unmodifiable(_entries.reversed.take(capacity));

  void add(RequestSummary summary) {
    final json = summary.toJson();
    _entries.add(json);
    while (_entries.length > capacity) {
      final evicted = _entries.removeAt(0);
      // 随条目淘汰同步清掉尝试明细，避免进程级内存单调增长（G5）。
      final evictedId = evicted['requestId']?.toString();
      if (evictedId != null) _attempts.remove(evictedId);
    }
    _append(json);
  }

  void noteAttempt(String requestId, Map<String, Object?> attempt) {
    // 尝试事件先于 summary 到达：不能因为“还没有任何记录”就丢弃，
    // 否则进程启动后的第一条请求永远没有尝试明细。
    _attempts.putIfAbsent(requestId, () => <String, Object?>{}).putIfAbsent(
          'attempts',
          () => <Object?>[],
        );
    final list = _attempts[requestId]!['attempts'];
    if (list is List) list.add(attempt);
    // 兜底上限：极少数请求可能永远不产生 summary（进程级异常）。
    while (_attempts.length > capacity) {
      _attempts.remove(_attempts.keys.first);
    }
  }

  Map<String, Object?>? byId(String requestId) {
    for (final e in _entries) {
      if (e['requestId'] == requestId) {
        final copy = Map<String, Object?>.from(e);
        final extra = _attempts[requestId];
        if (extra != null) copy['attemptsDetail'] = extra['attempts'];
        return copy;
      }
    }
    return null;
  }

  void _append(Map<String, Object?> json) {
    try {
      if (!directory.existsSync()) directory.createSync(recursive: true);
      final now = DateTime.now();
      final key =
          '${now.year}${now.month.toString().padLeft(2, '0')}${now.day.toString().padLeft(2, '0')}';
      final file = File(
          '${directory.path}${Platform.pathSeparator}requests-$key.jsonl');
      file.writeAsStringSync(
        '${redactor.redact(jsonEncode(json))}\n',
        mode: FileMode.append,
        flush: false,
      );
    } catch (_) {}
  }

  void cleanupOld() {
    final cutoff = DateTime.now().subtract(Duration(days: retentionDays));
    try {
      for (final f in directory.listSync()) {
        if (f is! File) continue;
        if (!f.uri.pathSegments.last.startsWith('requests-')) continue;
        if (f.lastModifiedSync().isBefore(cutoff)) f.deleteSync();
      }
    } catch (_) {}
  }
}

/// 控制台事件广播（SSE）。
class EventBus {
  final StreamController<(String, Map<String, Object?>)> _controller =
      StreamController.broadcast();

  Stream<(String, Map<String, Object?>)> get stream => _controller.stream;

  void emit(String event, Map<String, Object?> data) {
    if (_controller.isClosed) return;
    _controller.add((event, data));
  }

  Future<void> close() => _controller.close();
}
