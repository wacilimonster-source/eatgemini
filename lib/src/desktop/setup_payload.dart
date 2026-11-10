/// 安装器自解压 payload 的尾部格式（构建工具与安装器共用）。
///
/// 安装器 exe 尾部追加 `[便携版 exe 字节][24 字节 trailer]`，PE 加载器
/// 忽略节表之外的附加数据，实测 Dart AOT exe 追加后仍可正常运行。
/// trailer = 16 字节 ASCII magic + 8 字节 payload 长度（小端 uint64）。
library;

import 'dart:io' show File;
import 'dart:typed_data';

const String kSetupMagic = 'EATGEMINISETUP1!';
const int kSetupTrailerSize = 24;
const int _magicSize = 16;

Uint8List buildSetupTrailer(int payloadLength) {
  final out = Uint8List(kSetupTrailerSize);
  final magic = kSetupMagic.codeUnits;
  if (magic.length != _magicSize) {
    throw StateError('magic 必须是 $_magicSize 字节');
  }
  out.setRange(0, _magicSize, magic);
  ByteData.sublistView(out).setUint64(_magicSize, payloadLength, Endian.little);
  return out;
}

/// 解析尾部，返回 payload 长度；magic 不符或长度非法返回 null。
int? parseSetupTrailer(Uint8List tail) {
  if (tail.length < kSetupTrailerSize) return null;
  final end = tail.sublist(tail.length - kSetupTrailerSize);
  if (String.fromCharCodes(end.sublist(0, _magicSize)) != kSetupMagic) {
    return null;
  }
  final length = ByteData.sublistView(end)
      .getUint64(_magicSize, Endian.little);
  if (length <= 0 || length > 1 << 31) return null;
  return length;
}

class SetupBundle {
  const SetupBundle({required this.baseExe, required this.payload});

  /// 去掉 payload 与 trailer 的安装器本体（用于写 uninstall.exe）。
  final Uint8List baseExe;

  /// 内嵌的便携版 eatgemini.exe 字节。
  final Uint8List payload;
}

/// 从安装器 exe 中读出本体与 payload；不是有效安装包返回 null。
SetupBundle? readSetupBundle(String path) {
  final file = File(path);
  if (!file.existsSync()) return null;
  final bytes = file.readAsBytesSync();
  if (bytes.length < kSetupTrailerSize) return null;
  final payloadLength = parseSetupTrailer(bytes);
  if (payloadLength == null) return null;
  final payloadEnd = bytes.length - kSetupTrailerSize;
  final payloadStart = payloadEnd - payloadLength;
  if (payloadStart < 0) return null;
  // PE 头校验，避免把随便一个带尾部标记的文件当成安装包。
  if (payloadStart < 0x40 ||
      String.fromCharCodes(bytes.sublist(0, 2)) != 'MZ') {
    return null;
  }
  return SetupBundle(
    baseExe: Uint8List.sublistView(bytes, 0, payloadStart),
    payload: Uint8List.sublistView(bytes, payloadStart, payloadEnd),
  );
}
