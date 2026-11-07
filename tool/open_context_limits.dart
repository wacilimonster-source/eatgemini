/// 将现有数据目录切换到不额外限制上下文的配置，保留密钥、额度和模型启用状态。
library;

import 'dart:io';

import 'package:eatgemini/src/app/app_env.dart';
import 'package:eatgemini/src/core/config.dart';

void main(List<String> args) {
  final dataDir = DataDir.resolve(override: args.isEmpty ? null : args.single);
  final store = ConfigStore(dataDir);
  final json = store.load().toJson();
  final policy = json['policy'] as Map;
  for (final field in [
    'maxRequestBytes',
    'maxBufferedResponseBytes',
    'requestDeadlineMs',
  ]) {
    policy[field] = 0;
  }
  for (final profile in (json['compatibility'] as Map).values) {
    (profile as Map)['defaultMaxOutputTokens'] = 0;
  }
  final upstream = json['upstream'] as Map;
  upstream['firstEventTimeoutMs'] = 600000;
  upstream['streamIdleTimeoutMs'] = 300000;
  final defaults = defaultConfig();
  for (final entry in (json['models'] as Map).entries) {
    final spec = defaults.models[entry.key];
    if (spec == null) continue;
    final model = entry.value as Map;
    model['inputTokenLimit'] ??= spec.inputTokenLimit;
    model['outputTokenLimit'] ??= spec.outputTokenLimit;
  }
  final next = decodeConfig(json);
  if (dataDir.configFile.existsSync()) {
    dataDir.configFile.copySync(
        '${dataDir.configFile.path}.before-context-${DateTime.now().millisecondsSinceEpoch}');
  }
  store.write(next);
  stdout.writeln('已保存：${dataDir.configFile.path}');
  stdout.writeln('默认输出=模型最大额度；请求/响应大小与总生成时长=不限');
  stdout.writeln('首事件等待=10分钟；流空闲等待=5分钟');
}
