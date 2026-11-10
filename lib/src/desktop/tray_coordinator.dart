/// 主 isolate 侧的托盘协调器：spawn、状态推送、命令回传、关窗检测。
///
/// 关窗检测（§4.4 / F12）：控制台 SSE 连接全部断开超过 5 秒视为窗口已关闭，
/// 首次发生时托盘弹一次性气泡（`desktop.closeHintShown` 持久化由回调完成）。
/// 非 Windows 平台为空操作，测试可注入假的 isolate 启动器。
library;

import 'dart:async';
import 'dart:io' show Platform;
import 'dart:isolate';

import 'tray_isolate.dart' as impl;
import 'tray_protocol.dart';

/// 关窗检测状态机（§4.4 / F12）：SSE 全部断开超过 [gracePeriod] 且窗口
/// 曾打开过 → 首次提示后不再提示。纯逻辑，便于单测。
class WindowCloseWatch {
  WindowCloseWatch({this.gracePeriod = const Duration(seconds: 5)});

  final Duration gracePeriod;
  bool hinted = false;

  DateTime? _goneSince;
  bool _seenConnection = false;

  /// 返回 true 表示此刻应弹“仍在后台运行”气泡（只返回一次）。
  bool shouldHint({required DateTime now, required int sseConnections}) {
    if (sseConnections > 0) {
      _seenConnection = true;
      _goneSince = null;
      return false;
    }
    if (!_seenConnection || hinted) return false;
    _goneSince ??= now;
    if (now.difference(_goneSince!) >= gracePeriod) {
      hinted = true;
      return true;
    }
    return false;
  }
}

class TrayCoordinator {
  TrayCoordinator({
    required this.onOpenWindow,
    required this.onExit,
    this.onFirstCloseHint,
    this.onCheckUpdate,
    this.onToggleAutostart,
    this.log,
  });

  /// 托盘“打开监控窗口”。
  final void Function() onOpenWindow;

  /// 托盘“退出 eatgemini”。
  final Future<void> Function() onExit;

  /// 首次关窗气泡弹过后回调（持久化 closeHintShown）。
  final void Function()? onFirstCloseHint;

  /// 托盘“检查更新”。
  final void Function()? onCheckUpdate;

  /// 托盘“开机自启”开关。
  final void Function()? onToggleAutostart;

  final void Function(String line)? log;

  Isolate? _isolate;
  SendPort? _toTray;
  int _hwnd = 0;
  ReceivePort? _fromTray;
  Completer<void>? _bye;

  /// 已有窗口的网关地址（复制菜单用），随状态推送更新。
  bool get running => _toTray != null;

  /// 启动托盘。Windows 失败时记日志并静默降级（网关照常可用）。
  Future<void> start() async {
    if (!Platform.isWindows || _toTray != null) return;
    final ready = Completer<void>();
    // 必须先挂好 completer 再 spawn：isolate 可能抢在 spawn 返回前
    // 发出 ready 消息，晚赋值会把 complete() 丢掉（M1）。
    _readyCompleter = ready;
    _fromTray = ReceivePort()
      ..listen(_handleTrayMessage);
    try {
      _isolate = await Isolate.spawn(
        impl.trayIsolateMain,
        {'reply': _fromTray!.sendPort},
        debugName: 'tray',
      );
    } catch (e) {
      log?.call('托盘启动失败：$e');
      _readyCompleter = null;
      _fromTray?.close();
      _fromTray = null;
      return;
    }
    // 握手超时不影响主流程。
    await ready.future.timeout(const Duration(seconds: 3), onTimeout: () {
      log?.call('托盘握手超时（图标可能未显示）');
    });
  }

  Completer<void>? _readyCompleter;

  final TrayStateCache _stateCache = TrayStateCache();

  /// 推送状态与悬停提示（§14：主 → 托盘 {state, tooltip}）。
  /// 状态没变就跳过，避免每 2 秒一次无意义的托盘 IPC 与图标重绘。
  void update({
    required String state,
    required int todayRequests,
    required String gatewayUrl,
  }) {
    if (!running) return;
    if (!_stateCache.shouldSend(
      state: state,
      todayRequests: todayRequests,
      gatewayUrl: gatewayUrl,
    )) {
      return;
    }
    _send(trayStateMessage(
      state: state,
      todayRequests: todayRequests,
      gatewayUrl: gatewayUrl,
    ));
  }

  /// 气泡通知。level：info / warn / error。
  void showBalloon({
    required String level,
    required String title,
    required String text,
  }) {
    if (!running) return;
    _send(trayBalloonMessage(level: level, title: title, text: text));
  }

  /// 请求托盘退出并等待图标移除（超时兜底）。
  Future<void> stop() async {
    if (!running) return;
    _bye ??= Completer<void>();
    _send({'cmd': trayCmdQuit});
    await _bye!.future.timeout(const Duration(seconds: 2), onTimeout: () {
      log?.call('托盘退出超时，强制结束 isolate');
    });
    _isolate?.kill(priority: Isolate.beforeNextEvent);
    _isolate = null;
    _toTray = null;
    _fromTray?.close();
    _fromTray = null;
    _hwnd = 0;
    _stateCache.reset(); // 重新 start 后必须重发首帧状态
  }

  // ---- 关窗检测 ----

  final WindowCloseWatch _closeWatch = WindowCloseWatch();

  /// 由宿主周期调用（~2s 一次）。[sseConnections] 为控制台当前 SSE 连接数。
  void tick({required DateTime now, required int sseConnections}) {
    if (!_closeWatch.shouldHint(now: now, sseConnections: sseConnections)) {
      return;
    }
    if (!running) return;
    showBalloon(
      level: 'info',
      title: trayCloseHintTitle,
      text: trayCloseHintText,
    );
    onFirstCloseHint?.call();
  }

  // ---- 菜单状态 ----

  bool? _lastAutostart;
  bool? _lastUpdateAvailable;

  /// 推送开机自启勾选与更新提示；值没变就不打扰托盘消息循环。
  void setMenuState({
    required bool autostartEnabled,
    required bool updateAvailable,
  }) {
    if (_lastAutostart == autostartEnabled &&
        _lastUpdateAvailable == updateAvailable) {
      return;
    }
    _lastAutostart = autostartEnabled;
    _lastUpdateAvailable = updateAvailable;
    _send(trayMenuMessage(
      autostartEnabled: autostartEnabled,
      updateAvailable: updateAvailable,
    ));
  }

  /// 轻量心跳：只唤醒托盘的 GetMessage 循环，让 SendPort 命令有机会投递，
  /// 不触发状态推送/图标重绘。状态推送去重后必须保留这个心跳，否则托盘
  /// isolate 会长期停在阻塞的 GetMessage 上，菜单状态/气泡/退出命令延迟。
  void pulse() {
    if (_hwnd != 0) impl.postTrayWake(_hwnd);
  }

  // ---- 内部 ----

  void _send(Map<String, Object?> msg) {
    final port = _toTray;
    if (port == null) return;
    port.send(msg);
    if (_hwnd != 0) impl.postTrayWake(_hwnd); // 唤醒 GetMessage 循环
  }

  void _handleTrayMessage(Object? raw) {
    if (raw is! Map) return;
    final port = raw['port'];
    if (port is SendPort) {
      _toTray = port;
      final hwnd = raw['hwnd'];
      if (hwnd is int) _hwnd = hwnd;
      _readyCompleter?.complete();
      return;
    }
    if (raw.containsKey('error')) {
      log?.call('托盘启动失败：${raw['error']}');
      _toTray = null;
      _readyCompleter?.complete();
      return;
    }
    switch (raw['action']) {
      case trayActionOpen:
        log?.call('托盘请求打开监控窗口');
        onOpenWindow();
      case trayActionExit:
        log?.call('托盘请求退出');
        unawaited(onExit());
      case trayActionCheckUpdate:
        log?.call('托盘请求检查更新');
        onCheckUpdate?.call();
      case trayActionToggleAutostart:
        log?.call('托盘切换开机自启');
        onToggleAutostart?.call();
      case 'bye':
        _bye?.complete();
    }
  }
}
