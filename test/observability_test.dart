import 'dart:convert';
import 'dart:io';

import 'package:eatgemini/src/core/telemetry.dart';
import 'package:eatgemini/src/http/gateway_server.dart';
import 'package:eatgemini/src/observe/observability.dart';
import 'package:test/test.dart';

RequestSummary summary(String id) => RequestSummary(
      requestId: id,
      clientId: 'c',
      requestedModel: 'm',
      stream: false,
      startedAt: DateTime.now(),
      outcome: 'succeeded',
      httpStatus: 200,
      upstreamAttempts: 1,
      fellBack: false,
      cancelled: false,
      totalMs: 1,
    );

void main() {
  group('RequestLog', () {
    late Directory dir;
    late Redactor redactor;

    setUp(() {
      dir = Directory.systemTemp.createTempSync('eatgemini-obs-');
      redactor = Redactor();
    });

    tearDown(() {
      try {
        dir.deleteSync(recursive: true);
      } catch (_) {}
    });

    test('进程启动后的第一条请求也能记录尝试明细', () {
      final log = RequestLog(
        directory: dir,
        capacity: 5,
        redactor: redactor,
        retentionDays: 7,
      );
      // 尝试事件先于 summary 到达。
      log.noteAttempt('req1', {'phase': 'sending'});
      log.add(summary('req1'));
      final detail = log.byId('req1')!;
      expect(detail['attemptsDetail'], hasLength(1));
    });

    test('条目淘汰时同步清理尝试明细', () {
      final log = RequestLog(
        directory: dir,
        capacity: 2,
        redactor: redactor,
        retentionDays: 7,
      );
      for (final id in ['a', 'b', 'c']) {
        log.noteAttempt(id, {'phase': 'sending'});
        log.add(summary(id));
      }
      expect(log.byId('a'), isNull);
      expect(log.byId('b')!['attemptsDetail'], hasLength(1));
      expect(log.byId('c')!['attemptsDetail'], hasLength(1));
    });

    test('cleanupOld 按 retentionDays 删除过期请求日志', () {
      final old = File('${dir.path}${Platform.pathSeparator}requests-20200101.jsonl')
        ..writeAsStringSync('{}\n');
      old.setLastModifiedSync(DateTime.now().subtract(const Duration(days: 30)));
      final fresh =
          File('${dir.path}${Platform.pathSeparator}requests-29990101.jsonl')
            ..writeAsStringSync('{}\n');

      final log = RequestLog(
        directory: dir,
        capacity: 5,
        redactor: redactor,
        retentionDays: 7,
      );
      log.cleanupOld();

      expect(old.existsSync(), isFalse);
      expect(fresh.existsSync(), isTrue);
    });
  });

  group('StreamSniffer', () {
    test('SSE 帧被任意切块时仍能识别 usage 与错误码', () {
      final sniffer = StreamSniffer();
      final payload = 'data: ${jsonEncode({
            'choices': const <Object?>[],
            'usage': {'total_tokens': 19},
          })}\n\n'
          'data: ${jsonEncode({
            'error': {'code': 'upstream_stream_error'},
          })}\n\n';
      // 逐字节喂入，模拟最坏的 TCP 切块。
      for (final byte in utf8.encode(payload)) {
        sniffer.feed([byte]);
      }
      sniffer.flush();
      expect(sniffer.usage?['total_tokens'], 19);
      expect(sniffer.errorCode, 'upstream_stream_error');
    });
  });

  group('StaticTokenDirectory', () {
    test('多令牌时任一命中即可通过', () {
      final dir = StaticTokenDirectory(const {
        'sillytavern': 'tok_st',
        'pockettavern': 'tok_pt',
      });
      expect(dir.clientIdForToken('tok_st'), 'sillytavern');
      expect(dir.clientIdForToken('tok_pt'), 'pockettavern');
      expect(dir.clientIdForToken('tok_wrong'), isNull);
      expect(dir.clientIdForToken(''), isNull);
    });
  });
}
