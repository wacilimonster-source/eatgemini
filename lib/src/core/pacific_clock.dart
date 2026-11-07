/// 太平洋时间重置时钟。
///
/// 官方 RPD 在太平洋时间午夜重置（内核文档 §9.3）。本项目不引入 IANA 时区
/// 数据库：只支持 America/Los_Angeles 一个时区，而它的规则由美国联邦法固定
/// （2007 年起：3 月第二个周日 02:00 开始夏令时，11 月第一个周日 02:00 结束）。
/// 手写规则可被单测穷举，也不会让单文件 exe 多带一份时区数据。
library;

class PacificClock {
  const PacificClock();

  static const Duration _standardOffset = Duration(hours: -8);
  static const Duration _daylightOffset = Duration(hours: -7);

  /// 给定 UTC 时刻是否处于 PDT（夏令时）。
  bool isDaylight(DateTime utc) {
    final u = utc.toUtc();
    final start = _dstStartUtc(u.year);
    final end = _dstEndUtc(u.year);
    return !u.isBefore(start) && u.isBefore(end);
  }

  /// UTC 时刻对应的太平洋墙上时间（返回的 DateTime 用 UTC 字段承载本地值，
  /// 只用于取年月日和展示，不要拿它和 UTC 比较）。
  DateTime wallClock(DateTime utc) {
    final u = utc.toUtc();
    return u.add(isDaylight(u) ? _daylightOffset : _standardOffset);
  }

  /// 配额日键，`YYYY-MM-DD`（太平洋日）。
  String dayKey(DateTime utc) {
    final w = wallClock(utc);
    return '${w.year.toString().padLeft(4, '0')}-'
        '${w.month.toString().padLeft(2, '0')}-'
        '${w.day.toString().padLeft(2, '0')}';
  }

  /// 下一个太平洋午夜的 UTC 时刻。
  DateTime nextMidnightUtc(DateTime utc) {
    final w = wallClock(utc);
    final midnight = DateTime.utc(w.year, w.month, w.day).add(const Duration(days: 1));
    // 午夜所在时刻的偏移由当时的夏令时状态决定；用不动点迭代避免边界误差。
    var candidate = midnight.add(const Duration(hours: 8));
    for (var i = 0; i < 3; i++) {
      final offset = isDaylight(candidate) ? const Duration(hours: 7) : const Duration(hours: 8);
      final next = midnight.add(offset);
      if (next == candidate) break;
      candidate = next;
    }
    return candidate;
  }

  /// 夏令时开始：3 月第二个周日 02:00 PST = 10:00 UTC。
  DateTime _dstStartUtc(int year) {
    final day = _nthWeekday(year, 3, DateTime.sunday, 2);
    return DateTime.utc(year, 3, day, 10);
  }

  /// 夏令时结束：11 月第一个周日 02:00 PDT = 09:00 UTC。
  DateTime _dstEndUtc(int year) {
    final day = _nthWeekday(year, 11, DateTime.sunday, 1);
    return DateTime.utc(year, 11, day, 9);
  }

  /// 某月第 n 个指定星期几（n=1 表示第一个）。
  static int _nthWeekday(int year, int month, int weekday, int n) {
    final firstWeekday = DateTime.utc(year, month, 1).weekday;
    var day = 1 + ((weekday - firstWeekday) % 7);
    if (day <= 0) day += 7;
    return day + (n - 1) * 7;
  }
}
