/// UI 手工/浏览器测试挂载点：起一个带假上游和已存 Key 的实例，
/// 把控制台启动地址打印到 stdout 第一行，供浏览器自动化使用。
///
/// 用法：`dart run tool/ui_harness.dart`，结束后杀进程即可。
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:eatgemini/src/app/app_controller.dart';
import 'package:eatgemini/src/core/config.dart';

import '../test/support/fake_upstream.dart';

Future<void> main() async {
  final fake = await FakeUpstream.start();
  final dataDir = await Directory.systemTemp.createTemp('eatgemini-ui');
  final cfgJson = jsonDecode(defaultConfig().encode()) as Map<String, Object?>;
  cfgJson['upstream'] = {'baseUrl': fake.baseUrl};
  cfgJson['listen'] = const ListenConfig(port: 0).toJson();
  File('${dataDir.path}/config.json')
      .writeAsStringSync(jsonEncode(cfgJson), flush: true);

  final app = AppController(version: 'ui-test');
  unawaited(app.start(AppOptions(
    dataDirOverride: dataDir.path,
    openWindow: false,
    console: true,
  )));

  final deadline = DateTime.now().add(const Duration(seconds: 15));
  var ready = false;
  while (!ready && DateTime.now().isBefore(deadline)) {
    await Future<void>.delayed(const Duration(milliseconds: 100));
    try {
      ready = app.console.port > 0;
    } catch (_) {}
  }
  await app.saveUpstreamKey('UITEST-FAKE-KEY-0000000000000000000000000000',
      sameProject: true);

  stdout.writeln('LAUNCH_URL=${app.console.launchUri()}');
  stdout.writeln('GATEWAY=${app.gatewayBaseUrl}');
  stdout.writeln('DATA_DIR=${dataDir.path}');
  await stdout.flush();

  // 票据是一次性的：周期性发新票，方便多次浏览器接入（测试便利）。
  Timer.periodic(const Duration(seconds: 30), (_) {
    stdout.writeln('NEW_TICKET=${app.console.launchUri()}');
    stdout.flush();
  });

  // 挂住进程，等 SIGINT/kill。
  await Completer<void>().future;
}
