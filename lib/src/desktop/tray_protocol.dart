/// 托盘 isolate 协议与文案（桌面文档 §14、功能体验优化 F12）。
///
/// 主 isolate → 托盘：`{'cmd': 'state'|'balloon'|'quit', ...}`
/// 托盘 → 主 isolate：`{'action': 'open'|'copy'|'exit'}`
///
/// 本文件不含 win32，两侧与测试共用。
library;

import 'tray_glyph.dart' show trayIconKeyForState;

const String trayCmdState = 'state';
const String trayCmdBalloon = 'balloon';
const String trayCmdQuit = 'quit';

const String trayActionOpen = 'open';
const String trayActionCopy = 'copy';
const String trayActionExit = 'exit';

/// 状态推送。
Map<String, Object?> trayStateMessage({
  required String state,
  required int todayRequests,
  String gatewayUrl = '',
}) =>
    {
      'cmd': trayCmdState,
      'icon': trayIconKeyForState(state),
      'tooltip': buildTrayTooltip(state: state, todayRequests: todayRequests),
      'gateway': gatewayUrl,
    };

/// 气泡通知。level：info / warn / error。
Map<String, Object?> trayBalloonMessage({
  required String level,
  required String title,
  required String text,
}) =>
    {
      'cmd': trayCmdBalloon,
      'level': level,
      'title': title,
      'text': text,
    };

/// 悬停提示：`eatgemini · 运行中 · 今日 42 次`（≤127 字符，§14）。
String buildTrayTooltip({required String state, required int todayRequests}) {
  var text = 'eatgemini · ${trayStateLabel(state)} · 今日 $todayRequests 次';
  if (text.length > 127) text = text.substring(0, 127);
  return text;
}

/// 状态 → 中文标签（托盘菜单“状态：…”行同款）。
String trayStateLabel(String state) => switch (state) {
      'ready' => '运行中',
      'needs_key' => '待配置 Key',
      'degraded' => '已降级',
      'config_error' => '配置错误',
      'port_conflict' => '端口冲突',
      'persist_error' => '持久化错误',
      'stopping' => '退出中',
      _ => '运行中',
    };

/// 托盘菜单文案（§14）。
const List<String> trayMenuLines = [
  '打开监控窗口',
  '复制网关地址',
  '──────────',
  '状态：{state}（只读）',
  '──────────',
  '退出 eatgemini',
];

/// 首次关窗气泡（§4.4 / F12：一次性提示，之后不再弹）。
const String trayCloseHintTitle = 'eatgemini 仍在运行';
const String trayCloseHintText =
    '窗口已收纳到任务栏托盘（右下角 ^ 折叠图标里），网关继续在后台工作。'
    '单击托盘图标可重新打开窗口，右键可退出。';
