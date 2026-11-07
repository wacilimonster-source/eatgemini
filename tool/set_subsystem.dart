/// 把 Dart `compile exe` 产物的 PE 子系统从控制台（3）改为 GUI（2）。
///
/// 只改 OptionalHeader.Subsystem 两个字节，不动文件长度与末尾的 AOT 快照。
/// 用法：`dart run tool/set_subsystem.dart build/eatgemini.exe --gui`
library;

import 'dart:io';
import 'dart:typed_data';

Future<void> main(List<String> args) async {
  if (args.isEmpty) {
    stderr.writeln('用法：dart run tool/set_subsystem.dart <exe> [--gui|--cui]');
    exit(1);
  }
  final path = args[0];
  final target = args.contains('--cui') ? 3 : 2;
  final file = File(path);
  if (!file.existsSync()) {
    stderr.writeln('文件不存在：$path');
    exit(1);
  }

  final random = file.openSync(mode: FileMode.append);
  try {
    final length = random.lengthSync();
    if (length < 0x100) {
      stderr.writeln('文件太小，不是 PE 文件');
      exit(1);
    }

    // DOS 头：e_lfanew 在 0x3C
    random.setPositionSync(0x3C);
    final dosTail = random.readSync(4);
    final peOffset = ByteData.sublistView(dosTail).getUint32(0, Endian.little);

    random.setPositionSync(peOffset);
    final peSig = random.readSync(4);
    if (peSig[0] != 0x50 || peSig[1] != 0x45 || peSig[2] != 0 || peSig[3] != 0) {
      stderr.writeln('PE 签名不匹配');
      exit(1);
    }

    // COFF 头 20 字节 + OptionalHeader 的 Subsystem 字段（偏移 68）
    final subsystemOffset = peOffset + 4 + 20 + 68;
    random.setPositionSync(subsystemOffset);
    final current = ByteData.sublistView(random.readSync(2))
        .getUint16(0, Endian.little);

    if (current == target) {
      stdout.writeln('子系统已经是 ${_name(current)}，无需修改');
      return;
    }
    if (current != 3) {
      stderr.writeln('当前子系统是 ${_name(current)}（预期 3/CUI），拒绝修改');
      exit(1);
    }

    final data = ByteData(2)..setUint16(0, target, Endian.little);
    random.setPositionSync(subsystemOffset);
    random.writeFromSync(data.buffer.asUint8List());
    await random.flush();
    stdout.writeln('子系统：CUI(3) → ${_name(target)}（offset 0x${subsystemOffset.toRadixString(16)}）');
  } finally {
    random.closeSync();
  }
}

String _name(int value) => switch (value) {
      2 => 'GUI(2)',
      3 => 'CUI(3)',
      _ => '$value',
    };
