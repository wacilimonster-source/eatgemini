import 'package:eatgemini/src/http/admission.dart';
import 'package:test/test.dart';

void main() {
  Future<bool> acquire(
    Admission a, {
    required String client,
    int maxGlobal = 2,
    int maxPerClient = 1,
    int maxQueue = 8,
    int maxQueuePerClient = 4,
    int maxWaitMs = 1000,
  }) =>
      a.acquire(
        clientId: client,
        maxGlobal: maxGlobal,
        maxPerClient: maxPerClient,
        maxQueue: maxQueue,
        maxQueuePerClient: maxQueuePerClient,
        maxWaitMs: maxWaitMs,
      );

  test('释放方不能把名额记到别的客户端头上', () async {
    final a = Admission();
    expect(await acquire(a, client: 'A'), isTrue);
    expect(await acquire(a, client: 'B'), isTrue);
    expect(a.inFlight, 2);

    // 全局已满：A 再请求进入等待。
    final pendingA = acquire(a, client: 'A');
    expect(a.queued, 1);

    // B 释放后全局空出一个名额，但 A 已达单客户端上限（1），不能把
    // 这个名额判给 A——否则 A 会突破 maxInFlightPerClient。
    a.release('B');
    expect(a.inFlight, 1);
    expect(await acquire(a, client: 'B'), isTrue);
    expect(a.inFlight, 2);
    expect(a.queued, 1, reason: 'A 仍在排队，等待自己的在途请求结束');

    // A 的在途请求结束后，等待者才被唤醒并计入 A。
    a.release('A');
    expect(await pendingA, isTrue);
    expect(a.inFlight, 2);
    expect(a.queued, 0);
  });

  test('maxQueueLengthPerClient 生效：同客户端排队过多直接拒绝', () async {
    final a = Admission();
    expect(await acquire(a, client: 'A'), isTrue); // 占满全局
    final queued = acquire(a, client: 'A', maxQueuePerClient: 1);
    expect(a.queued, 1);
    expect(
      await acquire(a, client: 'A', maxQueuePerClient: 1),
      isFalse,
      reason: '第二个排队请求应被单客户端队列上限拒绝',
    );
    a.release('A');
    expect(await queued, isTrue);
  });

  test('排队超时返回 false 并从队列移除', () async {
    final a = Admission();
    expect(await acquire(a, client: 'A'), isTrue);
    final start = DateTime.now();
    expect(
      await acquire(a, client: 'A', maxWaitMs: 50),
      isFalse,
    );
    expect(DateTime.now().difference(start).inMilliseconds, greaterThanOrEqualTo(40));
    expect(a.queued, 0);
  });

  test('全局队列满时拒绝新请求', () async {
    final a = Admission();
    expect(await acquire(a, client: 'A', maxGlobal: 1), isTrue);
    final w1 = acquire(a, client: 'A', maxGlobal: 1, maxQueue: 1);
    expect(a.queued, 1);
    expect(
      await acquire(a, client: 'B', maxGlobal: 1, maxQueue: 1),
      isFalse,
    );
    a.release('A');
    expect(await w1, isTrue);
  });
}
