/// 把便携版 exe 附加到安装器 exe 尾部，生成单文件安装包。
///
/// 用法：dart run tool/attach_payload.dart <installer-base.exe> <payload.exe> <out.exe>
/// PE 加载器忽略节表之外的附加数据（实测 Dart AOT exe 追加后仍可运行）。
library;

import 'dart:io';

import 'package:eatgemini/src/desktop/setup_payload.dart';

Future<void> main(List<String> args) async {
  if (args.length < 3) {
    stderr.writeln('用法：attach_payload.dart <installer-base.exe> '
        '<payload.exe> <out.exe>');
    exit(1);
  }
  final base = File(args[0]);
  final payload = File(args[1]);
  final out = File(args[2]);
  if (!base.existsSync() || !payload.existsSync()) {
    stderr.writeln('输入文件不存在：${base.path} / ${payload.path}');
    exit(1);
  }
  final payloadSize = await payload.length();
  if (payloadSize <= 0 || payloadSize > 1 << 31) {
    stderr.writeln('payload 大小非法：$payloadSize');
    exit(1);
  }
  if (out.existsSync()) await out.delete();

  final sink = out.openWrite();
  await sink.addStream(base.openRead());
  await sink.addStream(payload.openRead());
  sink.add(buildSetupTrailer(payloadSize));
  await sink.close();

  // 生成后立刻按安装器的读取路径回验一次。
  final bundle = readSetupBundle(out.path);
  if (bundle == null || bundle.payload.length != payloadSize) {
    stderr.writeln('回验失败：尾部 payload 不完整');
    if (out.existsSync()) await out.delete();
    exit(1);
  }
  stdout.writeln('已生成 ${out.path}'
      '（安装器 ${await base.length()} + payload $payloadSize 字节）');
}
