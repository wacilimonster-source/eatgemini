/// 托盘 isolate（桌面文档 §14）：message-only 窗口 + Shell_NotifyIconW。
///
/// 消息循环阻塞在本 isolate 线程上；主 isolate 的命令经 SendPort 到达事件
/// 循环，由循环每轮的 await 空隙处理——因此主 isolate 每次发命令后都要
/// PostMessage(_wakeMsg) 唤醒 GetMessage。WndProc 是静态回调不能捕获上下文，
/// 它只记录事件标志，动作统一由 Dart 侧循环执行。
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
bool _menuRequested = false;
bool _openRequested = false;
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
void _applyWindowIcons() {
  if (_bigWindowIcon == 0 || _smallWindowIcon == 0) return;
  _matchedWindows.clear();
  EnumWindows(Pointer.fromFunction<WNDENUMPROC>(_monitorWindowEnumProc, 0), 0);
  for (final hwnd in _matchedWindows) {
    SendMessage(hwnd, WM_SETICON, ICON_BIG, _bigWindowIcon);
    SendMessage(hwnd, WM_SETICON, ICON_SMALL, _smallWindowIcon);
  }
}

final List<int> _matchedWindows = [];

/// EnumWindows 回调：标题精确等于监控窗口标题的可见顶层窗口。
int _monitorWindowEnumProc(int hwnd, int lParam) {
  if (IsWindowVisible(hwnd) == 0) return 1;
  final len = GetWindowTextLength(hwnd);
  if (len != _monitorWindowTitle.length) return 1;
  final buf = calloc<Uint16>(len + 1);
  try {
    GetWindowText(hwnd, buf.cast<Utf16>(), len + 1);
    final title = buf.cast<Utf16>().toDartString();
    if (title == _monitorWindowTitle) _matchedWindows.add(hwnd);
  } finally {
    calloc.free(buf);
  }
  return 1;
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

    _hwnd = CreateWindowEx(
      0, className, className, 0, 0, 0, 0, 0,
      HWND_MESSAGE, NULL, hInstance, nullptr,
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
    if (lParam == WM_RBUTTONUP) _menuRequested = true;
    // 左键单击即打开（气泡文案承诺“单击托盘图标重新打开”）；双击时系统会
    // 先补发一次 UP 再发 DBLCLK，由 _runPendingActions 的防抖合并成一次。
    if (lParam == WM_LBUTTONUP || lParam == WM_LBUTTONDBLCLK) {
      _openRequested = true;
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

void _runPendingActions() {
  if (_openRequested) {
    _openRequested = false;
    // 防抖：单击+双击的连发合并成一次打开（800ms 窗口内的重复请求丢弃）。
    final now = DateTime.now();
    if (_lastOpenForward == null ||
        now.difference(_lastOpenForward!) >
            const Duration(milliseconds: 800)) {
      _lastOpenForward = now;
      _actions?.send({'action': trayActionOpen});
    }
  }
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
  if (_menuRequested) {
    _menuRequested = false;
    _showMenu();
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
    ..uFlags = NIF_MESSAGE | NIF_ICON | NIF_TIP
    ..uCallbackMessage = _callbackMsg
    ..hIcon = _icons[_iconKey]!
    ..szTip = _tooltip;
  final ok = Shell_NotifyIcon(NIM_ADD, nid) != 0;
  if (!ok) return false;
  r.Anonymous.uVersion = NOTIFYICON_VERSION;
  Shell_NotifyIcon(NIM_SETVERSION, nid);
  _added = true;
  return true;
}

void _modifyIcon() {
  final nid = _nid!;
  nid.ref
    ..uFlags = NIF_ICON | NIF_TIP
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
  try {
    final pt = arena<POINT>();
    GetCursorPos(pt);
    // KB135788：菜单消失前需要前台窗口；关闭后再发 WM_NULL 修复焦点。
    SetForegroundWindow(_hwnd);
    TrackPopupMenu(menu, TPM_RIGHTBUTTON | TPM_BOTTOMALIGN, pt.ref.x, pt.ref.y,
        0, _hwnd, nullptr);
    PostMessage(_hwnd, WM_NULL, 0, 0);
  } finally {
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
