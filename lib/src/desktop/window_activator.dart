/// 已有监控窗口的快速激活（避免托盘点击时冷启动 Edge）。
///
/// 用 FindWindowEx 按标题精确查找：窗口管理器在内核侧比较窗口名，
/// 不会像 EnumWindows + GetWindowText 那样向其他进程发同步 WM_GETTEXT，
/// 因此遇到无响应窗口也不会卡住调用线程。
library;

import 'dart:ffi';
import 'dart:io' show Platform;

import 'package:ffi/ffi.dart';
import 'package:win32/win32.dart';

const String kMonitorWindowTitle = 'eatgemini 监控';

/// 找到所有可见的监控窗口并前置；返回是否至少激活了一个。
///
/// 非 Windows 或没有窗口时返回 false，调用方照常走浏览器启动路径。
bool activateMonitorWindow({String title = kMonitorWindowTitle}) {
  if (!Platform.isWindows) return false;
  final nativeTitle = title.toNativeUtf16();
  try {
    var hwnd = 0;
    var found = false;
    while (true) {
      hwnd = FindWindowEx(0, hwnd, nullptr, nativeTitle);
      if (hwnd == 0) break;
      if (IsWindowVisible(hwnd) == 0) continue;
      // 最小化 → 还原；随后提到顶层并请求前台（前台锁定失败也无妨，
      // ShowWindow 已让窗口可见，不阻塞等待任何跨进程响应）。
      ShowWindow(hwnd, SW_RESTORE);
      BringWindowToTop(hwnd);
      SetForegroundWindow(hwnd);
      found = true;
    }
    return found;
  } finally {
    malloc.free(nativeTitle);
  }
}
