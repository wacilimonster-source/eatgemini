/// Windows DPAPI（CryptProtectData）封装。
///
/// 只在当前 Windows 用户下可解密：换用户、换电脑、重装系统都解不开（设计如此）。
/// 非 Windows 或测试环境使用 [FakeDpapi]。
library;

import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';
import 'package:win32/win32.dart';

class DpapiException implements Exception {
  DpapiException(this.message);

  final String message;

  @override
  String toString() => message;
}

abstract interface class Dpapi {
  Uint8List protect(Uint8List plain, Uint8List entropy);

  Uint8List unprotect(Uint8List blob, Uint8List entropy);
}

class WindowsDpapi implements Dpapi {
  const WindowsDpapi();

  static const int _uiForbidden = 0x1;

  @override
  Uint8List protect(Uint8List plain, Uint8List entropy) {
    return using((Arena arena) {
      final inBlob = arena<CRYPT_INTEGER_BLOB>();
      final inData = arena<Uint8>(plain.isEmpty ? 1 : plain.length);
      if (plain.isNotEmpty) {
        inData.asTypedList(plain.length).setAll(0, plain);
      }
      inBlob.ref
        ..cbData = plain.length
        ..pbData = inData;

      final entropyBlob = arena<CRYPT_INTEGER_BLOB>();
      final entropyData = arena<Uint8>(entropy.isEmpty ? 1 : entropy.length);
      if (entropy.isNotEmpty) {
        entropyData.asTypedList(entropy.length).setAll(0, entropy);
      }
      entropyBlob.ref
        ..cbData = entropy.length
        ..pbData = entropyData;

      final outBlob = arena<CRYPT_INTEGER_BLOB>();
      final ok = CryptProtectData(
        inBlob,
        nullptr,
        entropyBlob,
        nullptr,
        nullptr,
        _uiForbidden,
        outBlob,
      );
      if (ok == 0) {
        throw DpapiException('加密失败（错误码 ${GetLastError()}）');
      }
      try {
        return _copyOut(outBlob);
      } finally {
        LocalFree(outBlob.ref.pbData.cast());
      }
    });
  }

  @override
  Uint8List unprotect(Uint8List blob, Uint8List entropy) {
    return using((Arena arena) {
      final inBlob = arena<CRYPT_INTEGER_BLOB>();
      final inData = arena<Uint8>(blob.isEmpty ? 1 : blob.length);
      if (blob.isNotEmpty) {
        inData.asTypedList(blob.length).setAll(0, blob);
      }
      inBlob.ref
        ..cbData = blob.length
        ..pbData = inData;

      final entropyBlob = arena<CRYPT_INTEGER_BLOB>();
      final entropyData = arena<Uint8>(entropy.isEmpty ? 1 : entropy.length);
      if (entropy.isNotEmpty) {
        entropyData.asTypedList(entropy.length).setAll(0, entropy);
      }
      entropyBlob.ref
        ..cbData = entropy.length
        ..pbData = entropyData;

      final outBlob = arena<CRYPT_INTEGER_BLOB>();
      final ok = CryptUnprotectData(
        inBlob,
        nullptr,
        entropyBlob,
        nullptr,
        nullptr,
        _uiForbidden,
        outBlob,
      );
      if (ok == 0) {
        throw DpapiException('解密失败（错误码 ${GetLastError()}）');
      }
      try {
        return _copyOut(outBlob);
      } finally {
        LocalFree(outBlob.ref.pbData.cast());
      }
    });
  }

  Uint8List _copyOut(Pointer<CRYPT_INTEGER_BLOB> outBlob) {
    final length = outBlob.ref.cbData;
    final result = Uint8List(length);
    if (length > 0) {
      result.setAll(0, outBlob.ref.pbData.asTypedList(length));
    }
    return result;
  }
}

/// 测试用"假加密"：可逆编码，**不提供任何机密性**。
class FakeDpapi implements Dpapi {
  FakeDpapi({this.failOnUnprotect = false});

  final bool failOnUnprotect;

  @override
  Uint8List protect(Uint8List plain, Uint8List entropy) {
    final out = Uint8List(plain.length + 4);
    out[0] = 0xFA;
    out[1] = 0xCE;
    out[2] = entropy.isEmpty ? 0 : entropy[0];
    out[3] = 0;
    for (var i = 0; i < plain.length; i++) {
      out[i + 4] = plain[i] ^ (entropy.isEmpty ? 0x5A : entropy[i % entropy.length]);
    }
    return out;
  }

  @override
  Uint8List unprotect(Uint8List blob, Uint8List entropy) {
    if (failOnUnprotect) throw DpapiException('解密失败（模拟）');
    if (blob.length < 4 || blob[0] != 0xFA || blob[1] != 0xCE) {
      throw DpapiException('数据格式不正确');
    }
    final out = Uint8List(blob.length - 4);
    for (var i = 0; i < out.length; i++) {
      out[i] =
          blob[i + 4] ^ (entropy.isEmpty ? 0x5A : entropy[i % entropy.length]);
    }
    return out;
  }
}

Dpapi defaultDpapi() => Platform.isWindows ? const WindowsDpapi() : FakeDpapi();
