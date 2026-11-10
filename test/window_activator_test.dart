import 'package:eatgemini/src/desktop/window_activator.dart';
import 'package:test/test.dart';

void main() {
  test('监控窗口标题与托盘 isolate 保持一致', () {
    expect(kMonitorWindowTitle, 'eatgemini 监控');
  });

  test('没有匹配窗口时返回 false（非 Windows 也直接降级）', () {
    // 不打开任何窗口、不产生副作用；只是确认 FFI 调用路径安全返回。
    expect(
      activateMonitorWindow(title: 'eatgemini-perf-test-no-such-window'),
      isFalse,
    );
  });
}
