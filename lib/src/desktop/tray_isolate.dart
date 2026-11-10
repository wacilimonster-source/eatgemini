/// 托盘 isolate（桌面文档 §14）：隐藏顶层工具窗口 + Shell_NotifyIconW。
///
/// 消息循环阻塞在本 isolate 线程上；主 isolate 的命令经 SendPort 到达事件
/// 循环，由循环每轮的 await 空隙处理——因此主 isolate 每次发命令后都要
/// PostMessage(_wakeMsg) 唤醒 GetMessage。WndProc 是静态回调不能捕获上下文，
/// 但可以调用同 isolate 的顶层函数：点击类动作（弹菜单、转发 open）在
/// WndProc 里**同步**完成——经事件循环中转实测会被鼠标消息洪峰拖慢
/// 140~1300ms（SillyTavernDesktop/GrandetToken 的托盘都是同步处理点击）；
/// 菜单命令、重加图标等仍由 Dart 侧循环统一执行。
///
/// NOTIFYICON_VERSION_4：v0/v3 的鼠标 UP 会被 Shell 扣住
/// GetDoubleClickTime（本机实测 500ms）做双击判定，右键菜单/双击因此
/// 「不跟手」；v4 的 WM_CONTEXTMENU / 鼠标消息立即投递（v4 下 lParam 为
/// MAKELONG(事件, 图标ID)，v0/v3 的 lParam 就是原始鼠标消息，两种编码都
/// 兼容，SETVERSION 万一失败时仍按 v0 行为工作）。v4 会抑制标准 tooltip，
/// 所以 NIF_TIP 必须搭配 NIF_SHOWTIP。
///
/// 协议见 tray_protocol.dart。托盘 isolate 不接收任何密钥（§7.3）。
library;

import 'dart:async';
import 'dart:ffi';
import 'dart:isolate';

import 'package:ffi/ffi.dart';
import 'package:win32/win32.dart';

import 'tray_glyph.dart';
import 'tray_protocol.dart';

const int _callbackMsg = WM_APP + 1; // NOTIFYICONDATA.uCallbackMessage
const int _wakeMsg = WM_APP + 2; // 主 isolate 的唤醒消息

const int _menuOpen = 1;
const int _menuCopy = 2;
const int _menuStatus = 3; // 只读行，禁用
const int _menuExit = 4;
const int _menuCheckUpdate = 5;
const int _menuAutostart = 6;

const int _trayIconId = 1;

// ---- WndProc 共享状态（单线程串行访问，见文件头） ----
int _hwnd = 0;
int _taskbarCreatedMsg = 0;
bool _added = false;
bool _menuTracking = false; // TrackPopupMenu 正在模态跟踪
int _menuClosedTick = 0; // 菜单关闭时刻：吞掉「关闭菜单的那次点击」的回放
bool _reAddRequested = false;
DateTime? _lastOpenForward;
int _menuCommand = 0;

// ---- Dart 侧状态 ----
final Map<String, int> _icons = {};
Pointer<NOTIFYICONDATA>? _nid;
SendPort? _actions;
String _iconKey = 'idle';
String _tooltip = 'eatgemini · 启动中';
String _gatewayUrl = '';
bool _autostartEnabled = false;
bool _updateAvailable = false;
bool _quitRequested = false;
int _bigWindowIcon = 0;
int _smallWindowIcon = 0;

const String _monitorWindowTitle = 'eatgemini 监控';

/// 找到所有监控窗口（按标题匹配 Edge 应用模式窗口）并覆盖其大/小图标。
/// HICON 由本 isolate 持有，窗口存活期间必须保持有效，故不 DestroyIcon。
///
/// 性能关键（托盘点击卡顿修复）：
/// - 用 `FindWindowEx` 按标题精确查找：窗口管理器在内核侧比较窗口名，
///   不像 `EnumWindows + GetWindowText` 那样向其他进程发**同步** WM_GETTEXT；
/// - 用 `PostMessage` 异步下发 WM_SETICON，不再 `SendMessage` 等待 Edge
///   窗口响应。任一窗口繁忙时都不会阻塞本 isolate 的 GetMessage 循环，
///   托盘点击才能被立即处理。
void _applyWindowIcons() {
  if (_bigWindowIcon == 0 || _smallWindowIcon == 0) return;
  final title = _monitorWindowTitle.toNativeUtf16();
  try {
    // 硬性上限 + 句柄去重：窗口 Z 序在 PostMessage 后可能变化，
    // 绝不能让这个每 2 秒的任务有机会卡住托盘的 GetMessage 循环。
    final seen = <int>{};
    var hwnd = 0;
    for (var i = 0; i < 32; i++) {
      hwnd = FindWindowEx(0, hwnd, nullptr, title);
      if (hwnd == 0 || !seen.add(hwnd)) break;
      if (IsWindowVisible(hwnd) == 0) continue;
      PostMessage(hwnd, WM_SETICON, ICON_BIG, _bigWindowIcon);
      PostMessage(hwnd, WM_SETICON, ICON_SMALL, _smallWindowIcon);
    }
  } finally {
    malloc.free(title);
  }
}

/// isolate 入口：`Isolate.spawn(trayIsolateMain, {'reply': SendPort})`。
Future<void> trayIsolateMain(Object raw) async {
  final params = raw as Map<dynamic, dynamic>;
  final reply = params['reply'] as SendPort;

  final arena = Arena();
  try {
    final hInstance = GetModuleHandle(nullptr);
    final className = 'eatgemini-tray'.toNativeUtf16(allocator: arena);

    final wc = arena<WNDCLASS>();
    final wcr = wc.ref;
    wcr.style = 0;
    wcr.lpfnWndProc = Pointer.fromFunction<WNDPROC>(_trayWndProc, 0);
    wcr.hInstance = hInstance;
    wcr.lpszClassName = className;
    if (RegisterClass(wc) == 0) {
      reply.send({'error': 'RegisterClassW 失败'});
      return;
    }

    // 必须是顶层窗口而不是 message-only（HWND_MESSAGE）：
    // 1) KB135788 要求菜单弹出前 SetForegroundWindow 成功，而 message-only
    //    窗口不在 Z 序里、永远不能成为前台，每次调用都静默失败——菜单焦点
    //    不正常：点外面不消失、悬停/首次点击被当成「激活第一次点击」吞掉，
    //    右键菜单表现为「不跟手、卡顿」。
    // 2) TaskbarCreated 这类 HWND_BROADCAST 广播只投递给顶层窗口，
    //    message-only 窗口永远收不到，Explorer 重启后的重加图标是死代码。
    // WS_EX_TOOLWINDOW + 从不 ShowWindow：不进任务栏与 Alt-Tab，不可见。
    _hwnd = CreateWindowEx(
      WS_EX_TOOLWINDOW, className, className, WS_POPUP, 0, 0, 0, 0,
      NULL, NULL, hInstance, nullptr,
    );
    if (_hwnd == 0) {
      reply.send({'error': 'CreateWindowExW 失败'});
      return;
    }

    _taskbarCreatedMsg =
        RegisterWindowMessage('TaskbarCreated'.toNativeUtf16(allocator: arena));

    for (final key in trayPalette.keys) {
      final h = _loadIcon(key);
      if (h != 0) _icons[key] = h;
    }
    if (!_icons.containsKey(_iconKey)) {
      reply.send({'error': '托盘图标生成失败'});
      return;
    }

    _nid = arena<NOTIFYICONDATA>();
    if (!_addIcon()) {
      reply.send({'error': 'Shell_NotifyIcon(NIM_ADD) 失败'});
      return;
    }

    final commands = ReceivePort();
    _actions = reply;
    commands.listen(_handleCommand);
    reply.send({'port': commands.sendPort, 'hwnd': _hwnd});

    // 监控窗口图标：Edge 应用模式窗口的图标来自页面 favicon 的 16/32px 缓存
    // 位图（Chromium 把 favicon 强制缩到 16/32 存储），任务栏上放大绘制必然
    // 发糊。这里周期性用我们的精确位图 WM_SETICON 覆盖（Edge 在导航/主题
    // 变化时会重设，所以要反复钉住）。菜单与气泡不受影响。
    _bigWindowIcon = _iconFromFrame('ready', 48);
    _smallWindowIcon = _iconFromFrame('ready', 24);
    if (_bigWindowIcon != 0 && _smallWindowIcon != 0) {
      _applyWindowIcons();
      Timer.periodic(const Duration(seconds: 2), (_) {
        if (!_quitRequested) _applyWindowIcons();
      });
    }

    final msg = arena<MSG>();
    while (!_quitRequested) {
      final r = GetMessage(msg, NULL, 0, 0);
      if (r <= 0) break; // WM_QUIT 或错误
      TranslateMessage(msg);
      DispatchMessage(msg);
      _runPendingActions();
      // 让事件循环投递 SendPort 命令（配合主 isolate 的 _wakeMsg 唤醒）。
      await Future<void>.delayed(Duration.zero);
    }

    for (final h in _icons.values) {
      DestroyIcon(h);
    }
    if (_bigWindowIcon != 0) DestroyIcon(_bigWindowIcon);
    if (_smallWindowIcon != 0) DestroyIcon(_smallWindowIcon);
    _icons.clear();
    _nid = null;
    commands.close();
    _actions?.send({'action': 'bye'}); // 主 isolate 等这行才算退出完成
  } finally {
    arena.releaseAll();
  }
}

int _trayWndProc(int hwnd, int msg, int wParam, int lParam) {
  if (msg == _callbackMsg) {
    // v4：lParam 的 LOWORD 是通知事件（WM_CONTEXTMENU / 鼠标消息…），
    // HIWORD 是图标 ID；v0/v3：lParam 就是原始鼠标消息。用 LOWORD 比较
    // 两种编码都覆盖（SETVERSION 万一失败退回 v0 行为时仍能工作）。
    final lo = lParam & 0xFFFF;
    // 右键 → 菜单必须在消息处理的**当场**同步弹出（SillyTavernDesktop 的
    // WinForms NotifyIcon、GrandetToken 的 Tauri 托盘都是这么做的，所以
    // 跟手）。此前经 _runPendingActions 延迟到 Dart 事件循环，实测鼠标
    // 滚动消息洪峰期间 WM_CONTEXTMENU → 菜单出现被拖到 140~1300ms。
    //
    // 防重开双保险：
    // 1. _menuTracking 挡掉模态循环期间派发的消息；
    // 2. 菜单被右键点外面关闭时，那次点击的 UP/CONTEXTMENU 会在
    //    TrackPopupMenu 返回后回放给本窗口，不吞掉的话菜单一关立刻又
    //    重开——关闭后 400ms 内的菜单请求一律视为回放。
    if (lo == WM_CONTEXTMENU || lParam == WM_RBUTTONUP) {
      if (!_menuTracking && GetTickCount() - _menuClosedTick > 400) {
        _showMenu();
      }
    }
    // 双击才打开监控窗口。v4 下双击序列是
    // (DOWN,UP,SELECT)(DOWN,UP,SELECT)(DBLCLK,UP,SELECT)，
    // 只认 DBLCLK，单击的 NIN_SELECT/UP 一律忽略。
    if (lo == WM_LBUTTONDBLCLK) {
      if (!_menuTracking) _forwardOpen();
    }
    return 0;
  }
  if (_taskbarCreatedMsg != 0 && msg == _taskbarCreatedMsg && _added) {
    // Explorer 重启后图标丢失，重新添加（§14）。
    _reAddRequested = true;
    return 0;
  }
  if (msg == WM_COMMAND) {
    _menuCommand = wParam & 0xFFFF;
    return 0;
  }
  if (msg == WM_DESTROY) {
    _removeIcon();
    PostQuitMessage(0);
    return 0;
  }
  return DefWindowProc(hwnd, msg, wParam, lParam);
}

/// 双击 → 打开监控窗口。防抖：800ms 窗口内的连发合并成一次。
/// 在 WndProc 里同步调用，不经过事件循环。
void _forwardOpen() {
  final now = DateTime.now();
  if (_lastOpenForward == null ||
      now.difference(_lastOpenForward!) > const Duration(milliseconds: 800)) {
    _lastOpenForward = now;
    _actions?.send({'action': trayActionOpen});
  }
}

void _runPendingActions() {
  if (_menuCommand != 0) {
    final cmd = _menuCommand;
    _menuCommand = 0;
    switch (cmd) {
      case _menuOpen:
        _actions?.send({'action': trayActionOpen});
      case _menuCopy:
        if (_gatewayUrl.isNotEmpty) _copyToClipboard(_gatewayUrl);
      case _menuExit:
        _actions?.send({'action': trayActionExit});
      case _menuCheckUpdate:
        _actions?.send({'action': trayActionCheckUpdate});
      case _menuAutostart:
        _actions?.send({'action': trayActionToggleAutostart});
    }
  }
  if (_reAddRequested) {
    _reAddRequested = false;
    if (_addIcon()) _modifyIcon();
  }
}

void _handleCommand(Object? raw) {
  if (raw is! Map) return;
  switch (raw['cmd']) {
    case trayCmdState:
      final icon = raw['icon'];
      if (icon is String && _icons.containsKey(icon)) _iconKey = icon;
      final tooltip = raw['tooltip'];
      if (tooltip is String && tooltip.isNotEmpty) _tooltip = tooltip;
      final gateway = raw['gateway'];
      if (gateway is String && gateway.isNotEmpty) _gatewayUrl = gateway;
      if (_added) _modifyIcon();
    case trayCmdBalloon:
      if (_added) _showBalloon(raw);
    case trayCmdMenu:
      _autostartEnabled = raw['autostart'] == true;
      _updateAvailable = raw['update'] == true;
    case trayCmdQuit:
      _quitRequested = true;
      DestroyWindow(_hwnd); // WM_DESTROY → 移除图标 + PostQuitMessage
  }
}

// ---------------------------------------------------------------- 图标

bool _addIcon() {
  final nid = _nid!;
  final r = nid.ref
    ..cbSize = sizeOf<NOTIFYICONDATA>()
    ..hWnd = _hwnd
    ..uID = _trayIconId
    ..uFlags = NIF_MESSAGE | NIF_ICON | NIF_TIP | NIF_SHOWTIP
    ..uCallbackMessage = _callbackMsg
    ..hIcon = _icons[_iconKey]!
    ..szTip = _tooltip;
  final ok = Shell_NotifyIcon(NIM_ADD, nid) != 0;
  if (!ok) return false;
  r.Anonymous.uVersion = NOTIFYICON_VERSION_4;
  Shell_NotifyIcon(NIM_SETVERSION, nid);
  _added = true;
  return true;
}

void _modifyIcon() {
  final nid = _nid!;
  nid.ref
    ..uFlags = NIF_ICON | NIF_TIP | NIF_SHOWTIP
    ..hIcon = _icons[_iconKey] ?? _icons.values.first
    ..szTip = _tooltip;
  Shell_NotifyIcon(NIM_MODIFY, nid);
}

void _removeIcon() {
  if (!_added) return;
  final nid = _nid!;
  nid.ref.uFlags = 0;
  Shell_NotifyIcon(NIM_DELETE, nid);
  _added = false;
}

int _loadIcon(String key) {
  // 按系统小图标尺寸（托盘实际显示尺寸）选最近的帧，避免缩放发糊。
  final target = GetSystemMetrics(SM_CXSMICON);
  var best = kTrayFrameSizes.first;
  for (final s in kTrayFrameSizes) {
    if ((s - target).abs() < (best - target).abs()) best = s;
  }
  return _iconFromFrame(key, best);
}

/// 由指定尺寸的帧创建 HICON（CreateIconFromResourceEx 只认单张图像）。
int _iconFromFrame(String key, int size) {
  final dib = buildTrayFrameDib(key, size);
  final p = malloc<Uint8>(dib.length);
  try {
    p.asTypedList(dib.length).setAll(0, dib);
    return CreateIconFromResourceEx(
        p, dib.length, 1, 0x00030000, 0, 0, LR_DEFAULTCOLOR);
  } finally {
    malloc.free(p);
  }
}

// ---------------------------------------------------------------- 气泡

void _showBalloon(Map raw) {
  final level = (raw['level'] ?? 'info') as String;
  final nid = _nid!;
  nid.ref
    ..uFlags = NIF_INFO
    ..szInfoTitle = _clip((raw['title'] ?? '') as String, 63)
    ..szInfo = _clip((raw['text'] ?? '') as String, 255)
    ..dwInfoFlags = switch (level) {
      'warn' => NIIF_WARNING,
      'error' => NIIF_ERROR,
      _ => NIIF_INFO,
    };
  Shell_NotifyIcon(NIM_MODIFY, nid);
}

String _clip(String s, int max) => s.length <= max ? s : s.substring(0, max);

// ---------------------------------------------------------------- 菜单

void _showMenu() {
  final menu = CreatePopupMenu();
  if (menu == 0) return;
  _append(menu, _menuOpen, '打开监控窗口');
  _append(menu, _menuCopy, '复制网关地址');
  AppendMenu(menu, MF_SEPARATOR, 0, nullptr);
  _append(
      menu, _menuStatus, '状态：${_stateLabelOf(_tooltip)}（只读）',
      grayed: true);
  AppendMenu(menu, MF_SEPARATOR, 0, nullptr);
  _append(
    menu,
    _menuCheckUpdate,
    _updateAvailable ? '检查更新 · 有新版本' : '检查更新',
  );
  _append(menu, _menuAutostart, '开机自启', checked: _autostartEnabled);
  AppendMenu(menu, MF_SEPARATOR, 0, nullptr);
  _append(menu, _menuExit, '退出 eatgemini');

  final arena = Arena();
  _menuTracking = true;
  try {
    final pt = arena<POINT>();
    GetCursorPos(pt);
    // KB135788：菜单消失前需要前台窗口；关闭后再发 WM_NULL 修复焦点。
    // 现在持有的是真顶层窗口，这条才会真正生效。
    SetForegroundWindow(_hwnd);
    TrackPopupMenu(menu, TPM_RIGHTBUTTON | TPM_BOTTOMALIGN, pt.ref.x, pt.ref.y,
        0, _hwnd, nullptr);
    PostMessage(_hwnd, WM_NULL, 0, 0);
  } finally {
    _menuTracking = false;
    _menuClosedTick = GetTickCount();
    arena.releaseAll();
  }
  DestroyMenu(menu);
}

void _append(int menu, int id, String label,
    {bool grayed = false, bool checked = false}) {
  const int mfChecked = 0x00000008; // MF_CHECKED
  final text = label.toNativeUtf16();
  try {
    AppendMenu(
      menu,
      MF_STRING | (grayed ? MF_GRAYED : 0) | (checked ? mfChecked : 0),
      id,
      text,
    );
  } finally {
    malloc.free(text);
  }
}

/// 从 tooltip 反查状态标签（tooltip 形如 `eatgemini · 运行中 · 今日 1 次`）。
String _stateLabelOf(String tooltip) {
  final parts = tooltip.split(' · ');
  return parts.length >= 2 ? parts[1] : '运行中';
}

// ---------------------------------------------------------------- 剪贴板

bool _copyToClipboard(String text) {
  final h = GlobalAlloc(GMEM_MOVEABLE, (text.length + 1) * 2);
  if (h == nullptr) return false;
  final dst = GlobalLock(h);
  if (dst == nullptr) {
    GlobalFree(h);
    return false;
  }
  final units = dst.cast<Uint16>();
  for (var i = 0; i < text.length; i++) {
    units[i] = text.codeUnitAt(i);
  }
  units[text.length] = 0;
  GlobalUnlock(h);
  if (OpenClipboard(_hwnd) != 0) {
    EmptyClipboard();
    SetClipboardData(CF_UNICODETEXT, h.address); // 成功后 h 归系统所有
    CloseClipboard();
    return true;
  }
  GlobalFree(h);
  return false;
}

/// 主 isolate 侧调用：唤醒托盘的消息循环（有新命令到达）。
void postTrayWake(int hwnd) {
  PostMessage(hwnd, _wakeMsg, 0, 0);
}
