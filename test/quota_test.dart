import 'package:eatgemini/src/core/classify.dart';
import 'package:eatgemini/src/core/config.dart';
import 'package:eatgemini/src/core/pacific_clock.dart';
import 'package:eatgemini/src/quota/quota.dart';
import 'package:test/test.dart';

void main() {
  late RouterConfig config;
  late QuotaManager quota;

  setUp(() {
    config = defaultConfig();
    quota = QuotaManager(
      config: () => config,
      store: MemoryStateStore(),
      clock: const PacificClock(),
    );
  });

  final noonPst = DateTime.utc(2026, 11, 6, 20); // 12:00 PT

  test('RPM 到达上限后跳过，窗口滑过后恢复', () {
    const model = 'gemini-3.8-flash';
    var t = noonPst;
    for (var i = 0; i < 5; i++) {
      final r = quota.reserve(model, 10, t);
      expect(r, isNotNull, reason: '第 ${i + 1} 次应可预留');
      t = t.add(const Duration(seconds: 1));
    }
    expect(quota.reserve(model, 10, t), isNull);
    final skip = quota.check(model, 10, t);
    expect(skip!.reason, 'rpm_limited');

    // 61 秒后窗口滑过
    final later = t.add(const Duration(seconds: 61));
    expect(quota.reserve(model, 10, later), isNotNull);
  });

  test('RPD 到达上限记为疑似耗尽，可低频探测', () {
    const model = 'gemini-2.5-flash-lite';
    var t = noonPst;
    // lite25 的 rpd 是 20，但 rpm 是 10：跨分钟铺开。
    for (var i = 0; i < 20; i++) {
      final r = quota.reserve(model, 10, t);
      expect(r, isNotNull, reason: '第 ${i + 1} 次');
      t = t.add(const Duration(seconds: 7));
    }
    final skip = quota.check(model, 10, t);
    expect(skip!.reason, 'daily_suspected');
    // 普通调用不允许探测；显式 allowProbe 且过了探测间隔才允许。
    expect(quota.reserve(model, 10, t), isNull);
    expect(
      quota.reserve(model, 10, t.add(const Duration(minutes: 6)),
          allowProbe: true),
      isNotNull,
    );
  });

  test('日耗尽封锁到太平洋午夜，跨日重置', () {
    const model = 'gemini-3.8-flash';
    final r = quota.reserve(model, 100, noonPst)!;
    quota.applyFailure(
      model,
      const UpstreamFailureForTest.daily(),
      noonPst,
      reservation: r,
    );
    final skip = quota.check(model, 100, noonPst);
    expect(skip!.reason, 'confirmed_blocked');
    // 次日 00:01 PT 之后恢复
    final nextDay = DateTime.utc(2026, 11, 7, 8, 1);
    expect(quota.check(model, 100, nextDay), isNull);
  });

  test('未知 429 只做短冷却', () {
    const model = 'gemini-3.8-flash';
    final r = quota.reserve(model, 100, noonPst)!;
    quota.applyFailure(
      model,
      const UpstreamFailureForTest.unknown429(),
      noonPst,
      reservation: r,
    );
    expect(quota.check(model, 100, noonPst)!.reason, 'model_blocked');
    expect(
      quota.check(model, 100, noonPst.add(const Duration(seconds: 61))),
      isNull,
    );
  });

  test('清除本地估算不能清掉上游确认的封锁', () {
    const model = 'gemini-3.8-flash';
    final r = quota.reserve(model, 100, noonPst)!;
    quota.applyFailure(
      model,
      const UpstreamFailureForTest.daily(),
      noonPst,
      reservation: r,
    );
    expect(quota.clearLocalEstimate('flash38:rpd'), isFalse);
  });

  test('跨日只重置日桶，分钟窗口保留', () {
    const model = 'gemini-3.8-flash';
    quota.reserve(model, 100, noonPst);
    final snapshot = quota.snapshot(noonPst);
    final buckets = (snapshot['buckets'] as Map).cast<String, Object?>();
    expect((buckets['flash38:rpd'] as Map)['localAttempts'], 1);
    expect((buckets['flash38:rpm'] as Map)['minuteUsed'], 1);

    final nextDay = DateTime.utc(2026, 11, 7, 9);
    final after = quota.snapshot(nextDay);
    final afterBuckets = (after['buckets'] as Map).cast<String, Object?>();
    expect((afterBuckets['flash38:rpd'] as Map)['localAttempts'], 0);
  });
}

/// 测试用失败对象（避免依赖 classify 的构造细节）。
class UpstreamFailureForTest extends UpstreamFailure {
  const UpstreamFailureForTest.daily()
      : super(
          kind: FailureKind.dailyExhausted,
          status: 429,
          message: 'quota per day',
          dimension: QuotaDimension.rpd,
        );

  const UpstreamFailureForTest.unknown429()
      : super(
          kind: FailureKind.unknown429,
          status: 429,
          message: 'quota',
        );
}
