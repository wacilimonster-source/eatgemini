/// 开始菜单快捷方式（IShellLinkW + IPersistFile，纯 FFI，无 PowerShell 闪窗）。
library;

import 'dart:ffi';
import 'dart:io' show File, Platform;

import 'package:ffi/ffi.dart';
import 'package:win32/win32.dart';

/// 创建 .lnk。父目录需已存在；失败返回 false（安装器会降级为不建快捷方式）。
bool createShortcut({
  required String linkPath,
  required String targetPath,
  String arguments = '',
  String workingDirectory = '',
  String description = '',
  String iconPath = '',
}) {
  if (!Platform.isWindows) return false;
  final hr = CoInitializeEx(nullptr, COINIT_APARTMENTTHREADED);
  if (hr < 0) return false; // RPC_E_CHANGED_MODE 等，交由调用方降级
  return using((Arena arena) {
    try {
      final link = ShellLink.createInstance();
      try {
        final target = targetPath.toNativeUtf16(allocator: arena);
        final args = arguments.toNativeUtf16(allocator: arena);
        final work = workingDirectory.toNativeUtf16(allocator: arena);
        final desc = description.toNativeUtf16(allocator: arena);
        final icon = (iconPath.isEmpty ? targetPath : iconPath)
            .toNativeUtf16(allocator: arena);
        link.setPath(target);
        if (arguments.isNotEmpty) link.setArguments(args);
        if (workingDirectory.isNotEmpty) link.setWorkingDirectory(work);
        if (description.isNotEmpty) link.setDescription(desc);
        link.setIconLocation(icon, 0);
        link.setShowCmd(SW_SHOWNORMAL);

        final persist = IPersistFile.from(link);
        try {
          final lnk = linkPath.toNativeUtf16(allocator: arena);
          final saved = persist.save(lnk, TRUE);
          return saved == 0 && File(linkPath).existsSync();
        } finally {
          persist.release();
        }
      } finally {
        link.release();
      }
    } catch (_) {
      return false;
    } finally {
      CoUninitialize();
    }
  });
}

bool deleteShortcut(String linkPath) {
  try {
    final file = File(linkPath);
    if (file.existsSync()) file.deleteSync();
    return true;
  } catch (_) {
    return false;
  }
}
