/// 并发准入：全局上限、按客户端上限与排队。
///
/// 规则来源：内核文档 §10、桌面文档 §8。计数必须按“请求实际占用的
/// 客户端”记账：等待队列里记录发起者 clientId，释放时按该 ID 重新判定，
/// 不能把唤醒名额算到释放方头上。
library;

import 'dart:async';

class Admission {
  int _inFlight = 0;
  final Map<String, int> _perClient = {};
  final List<_Waiter> _waiters = [];
  int _maxGlobal = 1;
  int _maxPerClient = 1;

  /// 当前在途请求数（测试与诊断用）。
  int get inFlight => _inFlight;

  /// 当前排队请求数（测试与诊断用）。
  int get queued => _waiters.length;

  Future<bool> acquire({
    required String clientId,
    required int maxGlobal,
    required int maxPerClient,
    required int maxQueue,
    required int maxQueuePerClient,
    required int maxWaitMs,
  }) async {
    // 配置热加载可能改变上限；release/_dispatch 使用最近一次的上限。
    _maxGlobal = maxGlobal > 0 ? maxGlobal : 1;
    _maxPerClient = maxPerClient > 0 ? maxPerClient : 1;

    final perClient = _perClient[clientId] ?? 0;
    if (_inFlight < _maxGlobal && perClient < _maxPerClient) {
      _take(clientId);
      return true;
    }
    if (_waiters.length >= maxQueue) return false;
    final queuedForClient =
        _waiters.where((w) => w.clientId == clientId).length;
    if (queuedForClient >= maxQueuePerClient) return false;

    final waiter = _Waiter(clientId);
    _waiters.add(waiter);
    waiter.timer = Timer(Duration(milliseconds: maxWaitMs), () {
      if (waiter.completer.isCompleted) return;
      _waiters.remove(waiter);
      waiter.completer.complete(false);
    });
    return waiter.completer.future;
  }

  void release(String clientId) {
    if (_inFlight > 0) _inFlight--;
    final next = (_perClient[clientId] ?? 1) - 1;
    if (next <= 0) {
      _perClient.remove(clientId);
    } else {
      _perClient[clientId] = next;
    }
    _dispatch();
  }

  /// 按客户端重新判定等待者：容量不足的留在队里，避免把名额记错人。
  void _dispatch() {
    var i = 0;
    while (i < _waiters.length) {
      final waiter = _waiters[i];
      if (waiter.completer.isCompleted) {
        _waiters.removeAt(i);
        continue;
      }
      final perClient = _perClient[waiter.clientId] ?? 0;
      if (_inFlight < _maxGlobal && perClient < _maxPerClient) {
        _waiters.removeAt(i);
        waiter.timer?.cancel();
        _take(waiter.clientId);
        waiter.completer.complete(true);
        // 还有容量时继续唤醒后面的等待者。
        continue;
      }
      i++;
    }
  }

  void _take(String clientId) {
    _inFlight++;
    _perClient[clientId] = (_perClient[clientId] ?? 0) + 1;
  }
}

class _Waiter {
  _Waiter(this.clientId);

  final String clientId;
  final Completer<bool> completer = Completer<bool>();
  Timer? timer;
}
