import 'dart:io';

import 'package:eatgemini/src/app/app_env.dart';
import 'package:eatgemini/src/core/config.dart';
import 'package:test/test.dart';

void main() {
  late Directory root;
  late DataDir dataDir;
  late ConfigStore store;

  setUp(() {
    root = Directory.systemTemp.createTempSync('eatgemini-env-');
    dataDir = DataDir(root);
    dataDir.ensure();
    store = ConfigStore(dataDir);
  });

  tearDown(() {
    try {
      root.deleteSync(recursive: true);
    } catch (_) {}
  });

  test('从备份恢复后写回主文件，坏文件保留为 .corrupt-*', () {
    // 第一次写创建主文件；第二次写把合法主文件备份为 .bak。
    store.write(defaultConfig());
    store.write(defaultConfig());
    dataDir.configFile.writeAsStringSync('{ broken');
    final recovered = store.tryRecover();
    expect(recovered, isNotNull);

    store.replaceCorruptWith(recovered!);

    // 主文件已恢复为合法配置，可以正常加载。
    expect(() => store.load(), returnsNormally);
    // 坏文件保留下来便于排查。
    final corrupt = root
        .listSync()
        .whereType<File>()
        .where((f) => f.path.contains('.corrupt-'))
        .toList();
    expect(corrupt, hasLength(1));
    expect(corrupt.single.readAsStringSync(), contains('broken'));
  });
}
