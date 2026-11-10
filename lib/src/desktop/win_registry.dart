/// Windows 注册表 HKCU 读写（开机自启、卸载信息）。
///
/// 只用当前用户配置单元，不需要管理员权限；win32 5.15 没有高层封装，
/// 这里直接调 advapi32 的 W 版本 API。非 Windows / 测试注入 [InMemoryRegistry]。
library;

import 'dart:ffi';
import 'dart:io' show Platform;

import 'package:ffi/ffi.dart';
import 'package:win32/win32.dart';

const int _errorSuccess = 0;
const int _errorFileNotFound = 2;

/// 注册表访问抽象：键路径相对 HKCU，值一律 REG_SZ。
abstract interface class RegistryStore {
  bool get supported;

  String? readString(String keyPath, String valueName);

  bool writeString(String keyPath, String valueName, String data);

  bool deleteValue(String keyPath, String valueName);

  bool deleteKey(String keyPath);
}

class WindowsRegistry implements RegistryStore {
  const WindowsRegistry();

  @override
  bool get supported => Platform.isWindows;

  @override
  String? readString(String keyPath, String valueName) {
    if (!supported) return null;
    return using((Arena arena) {
      final subKey = keyPath.toNativeUtf16(allocator: arena);
      final phk = arena<IntPtr>()..value = 0;
      if (RegOpenKeyEx(
              HKEY_CURRENT_USER, subKey, 0, KEY_QUERY_VALUE, phk) !=
          _errorSuccess) {
        return null;
      }
      final hKey = phk.value;
      try {
        final name = valueName.toNativeUtf16(allocator: arena);
        final type = arena<Uint32>();
        final size = arena<Uint32>()..value = 0;
        // 先取长度；lpData 传 nullptr 是 RegQueryValueExW 的标准用法。
        if (RegQueryValueEx(
                hKey, name, nullptr, type, nullptr, size) !=
            _errorSuccess) {
          return null;
        }
        if (type.value != REG_SZ || size.value == 0 || size.value > 1 << 20) {
          return null;
        }
        final buffer = arena<Uint8>(size.value + 2);
        final actual = arena<Uint32>()..value = size.value;
        if (RegQueryValueEx(
                hKey, name, nullptr, type, buffer, actual) !=
            _errorSuccess) {
          return null;
        }
        final count = actual.value ~/ 2;
        if (count <= 0) return null;
        final units = buffer.cast<Uint16>().asTypedList(count);
        var end = units.length;
        while (end > 0 && units[end - 1] == 0) {
          end--;
        }
        return String.fromCharCodes(units.sublist(0, end));
      } finally {
        RegCloseKey(hKey);
      }
    });
  }

  @override
  bool writeString(String keyPath, String valueName, String data) {
    if (!supported) return false;
    return using((Arena arena) {
      final subKey = keyPath.toNativeUtf16(allocator: arena);
      final phk = arena<IntPtr>()..value = 0;
      final disposition = arena<Uint32>()..value = 0;
      final created = RegCreateKeyEx(
        HKEY_CURRENT_USER,
        subKey,
        0,
        nullptr,
        0,
        KEY_SET_VALUE | KEY_QUERY_VALUE,
        nullptr,
        phk,
        disposition,
      );
      if (created != _errorSuccess) return false;
      final hKey = phk.value;
      try {
        final name = valueName.toNativeUtf16(allocator: arena);
        final value = data.toNativeUtf16(allocator: arena);
        return RegSetValueEx(
              hKey,
              name,
              0,
              REG_SZ,
              value.cast<Uint8>(),
              (data.length + 1) * 2,
            ) ==
            _errorSuccess;
      } finally {
        RegCloseKey(hKey);
      }
    });
  }

  @override
  bool deleteValue(String keyPath, String valueName) {
    if (!supported) return false;
    return using((Arena arena) {
      final subKey = keyPath.toNativeUtf16(allocator: arena);
      final phk = arena<IntPtr>()..value = 0;
      if (RegOpenKeyEx(
              HKEY_CURRENT_USER, subKey, 0, KEY_SET_VALUE, phk) !=
          _errorSuccess) {
        // 键不存在时删除本身就是幂等成功。
        return true;
      }
      final hKey = phk.value;
      try {
        final name = valueName.toNativeUtf16(allocator: arena);
        final status = RegDeleteValue(hKey, name);
        return status == _errorSuccess || status == _errorFileNotFound;
      } finally {
        RegCloseKey(hKey);
      }
    });
  }

  @override
  bool deleteKey(String keyPath) {
    if (!supported) return false;
    return using((Arena arena) {
      final subKey = keyPath.toNativeUtf16(allocator: arena);
      final status = RegDeleteKey(HKEY_CURRENT_USER, subKey);
      return status == _errorSuccess || status == _errorFileNotFound;
    });
  }
}

/// 测试 / 非 Windows 环境用的内存实现。
class InMemoryRegistry implements RegistryStore {
  InMemoryRegistry({bool supported = true}) : _supported = supported;

  final bool _supported;
  final Map<String, Map<String, String>> _keys = {};

  @override
  bool get supported => _supported;

  @override
  String? readString(String keyPath, String valueName) =>
      _keys[_normalize(keyPath)]?[valueName];

  @override
  bool writeString(String keyPath, String valueName, String data) {
    if (!_supported) return false;
    _keys.putIfAbsent(_normalize(keyPath), () => <String, String>{})[valueName] =
        data;
    return true;
  }

  @override
  bool deleteValue(String keyPath, String valueName) {
    final key = _normalize(keyPath);
    final values = _keys[key];
    if (values == null) return true;
    values.remove(valueName);
    if (values.isEmpty) _keys.remove(key);
    return true;
  }

  @override
  bool deleteKey(String keyPath) {
    _keys.remove(_normalize(keyPath));
    return true;
  }

  String _normalize(String path) => path.toLowerCase();
}
