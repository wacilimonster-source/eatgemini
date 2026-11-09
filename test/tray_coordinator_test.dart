import 'package:eatgemini/src/desktop/tray_coordinator.dart';
import 'package:test/test.dart';

DateTime _at(int seconds) => DateTime(2026, 1, 1, 12, 0, seconds);

void main() {
  group('WindowCloseWatch（关窗检测 §4.4）', () {
    test('窗口从未打开过不提示', () {
      final w = WindowCloseWatch();
      expect(w.shouldHint(now: _at(100), sseConnections: 0), isFalse);
      expect(w.shouldHint(now: _at(200), sseConnections: 0), isFalse);
    });

    test('断开超过 5 秒提示一次，之后不再提示', () {
      final w = WindowCloseWatch();
      expect(w.shouldHint(now: _at(10), sseConnections: 1), isFalse);
      // 断开瞬间到 5 秒内：静默。
      expect(w.shouldHint(now: _at(11), sseConnections: 0), isFalse);
      expect(w.shouldHint(now: _at(15), sseConnections: 0), isFalse);
      // 第 16 秒：满 5 秒 → 提示一次。
      expect(w.shouldHint(now: _at(16), sseConnections: 0), isTrue);
      expect(w.hinted, isTrue);
      expect(w.shouldHint(now: _at(60), sseConnections: 0), isFalse);
    });

    test('重连后计时清零，再断开重新计 5 秒', () {
      final w = WindowCloseWatch();
      expect(w.shouldHint(now: _at(10), sseConnections: 1), isFalse);
      expect(w.shouldHint(now: _at(12), sseConnections: 0), isFalse);
      expect(w.shouldHint(now: _at(13), sseConnections: 1), isFalse); // 回连
      expect(w.shouldHint(now: _at(14), sseConnections: 0), isFalse);
      expect(w.shouldHint(now: _at(18), sseConnections: 0), isFalse); // 仅 4s
      expect(w.shouldHint(now: _at(19), sseConnections: 0), isTrue); // 5s 满
    });
  });
}
