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
/// 后台进程直接调用 SetForegroundWindow 会被 Windows 前台锁定静默拒绝，
/// 窗口其实没被提到前面。所以先用 HWND_TOPMOST → HWND_NOTOPMOST 把窗口
/// 真正带到可见最前（不需要前台权限），再用 AttachThreadInput 临时共享
/// 前台线程输入队列来提高抢前台的成功率。
/// 循环有硬性上限并按 hwnd 去重，绝不会卡死调用线程。
bool activateMonitorWindow({String title = kMonitorWindowTitle}) {
  if (!Platform.isWindows) return false;
  final nativeTitle = title.toNativeUtf16();
  try {
    const int maxWindows = 32;
    const int flags = SWP_NOMOVE | SWP_NOSIZE | SWP_SHOWWINDOW;
    final seen = <int>{};
    var hwnd = 0;
    var activated = false;
    for (var i = 0; i < maxWindows; i++) {
      hwnd = FindWindowEx(0, hwnd, nullptr, nativeTitle);
      if (hwnd == 0 || !seen.add(hwnd)) break;
      if (IsWindowVisible(hwnd) == 0) continue;

      ShowWindow(hwnd, SW_RESTORE);
      SetWindowPos(hwnd, HWND_TOPMOST, 0, 0, 0, 0, flags);
      SetWindowPos(hwnd, HWND_NOTOPMOST, 0, 0, 0, 0, flags);
      BringWindowToTop(hwnd);

      final foreground = GetForegroundWindow();
      final fgThread = GetWindowThreadProcessId(foreground, nullptr);
      final myThread = GetCurrentThreadId();
      var attached = false;
      if (fgThread != 0 && fgThread != myThread) {
        attached = AttachThreadInput(myThread, fgThread, TRUE) != 0;
      }
      SetForegroundWindow(hwnd);
      if (attached) AttachThreadInput(myThread, fgThread, FALSE);
      // 只有真正抢到前台才算快速路径成功；否则 openWindow() 会回退启动
      // 浏览器，保证托盘点击一定有反馈，绝不会出现「点了没反应」。
      if (GetForegroundWindow() == hwnd) activated = true;
    }
    return activated;
  } finally {
    malloc.free(nativeTitle);
  }
}
