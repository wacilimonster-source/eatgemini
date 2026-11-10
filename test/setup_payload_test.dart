import 'dart:io';
import 'dart:typed_data';

import 'package:eatgemini/src/desktop/setup_payload.dart';
import 'package:test/test.dart';

void main() {
  test('trailer 编解码与损坏数据', () {
    final trailer = buildSetupTrailer(1234567);
    expect(trailer.length, kSetupTrailerSize);
    expect(parseSetupTrailer(trailer), 1234567);
    expect(parseSetupTrailer(Uint8List(10)), isNull);
    final broken = Uint8List.fromList(trailer)..[0] = 0x58; // 破坏 magic
    expect(parseSetupTrailer(broken), isNull);
  });

  test('安装包读出本体与内嵌程序', () {
    final temp = Directory.systemTemp.createTempSync('eg-payload-');
    addTearDown(() {
      if (temp.existsSync()) temp.deleteSync(recursive: true);
    });
    final base = Uint8List.fromList([
      0x4D, 0x5A, ...List<int>.filled(126, 0x41),
    ]);
    final payload = Uint8List.fromList([
      0x4D, 0x5A, ...List<int>.filled(200, 0x42),
    ]);
    final file = File('${temp.path}${Platform.pathSeparator}setup.exe');
    file.writeAsBytesSync([
      ...base,
      ...payload,
      ...buildSetupTrailer(payload.length),
    ], flush: true);

    final bundle = readSetupBundle(file.path);
    expect(bundle, isNotNull);
    expect(bundle!.baseExe.length, base.length);
    expect(bundle.baseExe[0], 0x4D);
    expect(bundle.payload.length, payload.length);
    expect(bundle.payload[1], 0x5A);
  });

  test('无 trailer 或不是 PE 的文件不是安装包', () {
    final temp = Directory.systemTemp.createTempSync('eg-payload-bad-');
    addTearDown(() {
      if (temp.existsSync()) temp.deleteSync(recursive: true);
    });
    final plain = File('${temp.path}${Platform.pathSeparator}plain.exe');
    plain.writeAsBytesSync(List<int>.filled(200, 0x33), flush: true);
    expect(readSetupBundle(plain.path), isNull);

    final short = File('${temp.path}${Platform.pathSeparator}short.exe');
    short.writeAsBytesSync([
      0x4D,
      0x5A,
      ...buildSetupTrailer(100),
    ], flush: true);
    expect(readSetupBundle(short.path), isNull);
    expect(readSetupBundle('${temp.path}${Platform.pathSeparator}missing.exe'),
        isNull);
  });
}
