import 'package:eatgemini/src/core/pacific_clock.dart';
import 'package:test/test.dart';

void main() {
  const clock = PacificClock();

  group('太平洋日与重置', () {
    test('标准时间：太平洋午夜是 UTC 08:00', () {
      // 2026-11-06 00:00 PST = 2026-11-06T08:00Z
      expect(clock.dayKey(DateTime.utc(2026, 11, 6, 7, 59)), '2026-11-05');
      expect(clock.dayKey(DateTime.utc(2026, 11, 6, 8, 0)), '2026-11-06');
      expect(
        clock.nextMidnightUtc(DateTime.utc(2026, 11, 6, 9)),
        DateTime.utc(2026, 11, 7, 8),
      );
    });

    test('夏令时：太平洋午夜是 UTC 07:00', () {
      // 2026-06-15 00:00 PDT = 2026-06-15T07:00Z
      expect(clock.dayKey(DateTime.utc(2026, 6, 15, 6, 59)), '2026-06-14');
      expect(clock.dayKey(DateTime.utc(2026, 6, 15, 7, 0)), '2026-06-15');
      expect(
        clock.nextMidnightUtc(DateTime.utc(2026, 6, 15, 12)),
        DateTime.utc(2026, 6, 16, 7),
      );
    });

    test('夏令时开始：3 月第二个周日 10:00Z 切换', () {
      // 2026-03-08 是第二个周日
      expect(clock.isDaylight(DateTime.utc(2026, 3, 8, 9, 59)), isFalse);
      expect(clock.isDaylight(DateTime.utc(2026, 3, 8, 10, 0)), isTrue);
    });

    test('夏令时结束：11 月第一个周日 09:00Z 切换', () {
      expect(clock.isDaylight(DateTime.utc(2026, 11, 1, 8, 59)), isTrue);
      expect(clock.isDaylight(DateTime.utc(2026, 11, 1, 9, 0)), isFalse);
    });

    test('切换日的下一个午夜用正确偏移', () {
      // 11-01 是夏时制最后一天：00:00 当地仍是 PDT（UTC-7）
      expect(
        clock.nextMidnightUtc(DateTime.utc(2026, 10, 31, 20)),
        DateTime.utc(2026, 11, 1, 7),
      );
      // 11-01 之后的下一个午夜已是 PST（UTC-8）
      expect(
        clock.nextMidnightUtc(DateTime.utc(2026, 11, 1, 12)),
        DateTime.utc(2026, 11, 2, 8),
      );
    });
  });
}
