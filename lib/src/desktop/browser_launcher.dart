/// 打开监控窗口：优先 Edge/Chrome 的应用模式，失败退回默认浏览器。
///
/// 规则来源：桌面文档 §4.4。
library;

import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';
import 'package:win32/win32.dart';

class LaunchResult {
  const LaunchResult(this.mode, {this.message});

  /// edge / chrome / default / failed
  final String mode;
  final String? message;
}

class BrowserLauncher {
  BrowserLauncher({required this.userDataDir, this.preferred = 'auto'});

  final Directory userDataDir;
  final String preferred;

  /// 用 ShellExecute 由系统 shell 打开 URL。
  ///
  /// Edge 应用模式（--app=）在专用 profile 已有驻留进程时会把请求转交给它，
  /// 却不再创建/显示窗口，托盘点击表现为「没反应」。ShellExecute 由 explorer
  /// 处理，浏览器窗口一定会被创建并带到前台，且不会闪控制台窗口。
  Future<LaunchResult> openVisible(Uri url) async {
    if (!Platform.isWindows) {
      return const LaunchResult('failed', message: '仅支持 Windows');
    }
    final verb = 'open'.toNativeUtf16();
    final target = url.toString().toNativeUtf16();
    try {
      const int swShowNormal = 1;
      final code =
          ShellExecute(0, verb, target, nullptr, nullptr, swShowNormal);
      if (code > 32) return const LaunchResult('default');
      return LaunchResult('failed', message: 'ShellExecute 失败（$code）');
    } finally {
      malloc.free(verb);
      malloc.free(target);
    }
  }

  Future<LaunchResult> open(Uri url) async {
    final browser = preferred == 'default' ? null : _findBrowser(preferred);
    if (browser != null) {
      try {
        if (!userDataDir.existsSync()) userDataDir.createSync(recursive: true);
        await Process.start(
          browser,
          [
            '--app=$url',
            '--user-data-dir=${userDataDir.path}',
            '--no-first-run',
            '--no-default-browser-check',
            '--disable-sync',
            '--window-size=1180,800',
          ],
          mode: ProcessStartMode.detached,
        );
        return LaunchResult(browser.toLowerCase().contains('edge') ? 'edge' : 'chrome');
      } catch (_) {
        // 落到默认浏览器
      }
    }
    try {
      final opened = await Process.run(
        'rundll32',
        ['url.dll,FileProtocolHandler', url.toString()],
        runInShell: false,
      );
      if (opened.exitCode == 0) {
        return const LaunchResult('default',
            message: '未找到 Edge，已用默认浏览器打开');
      }
    } catch (_) {}

    try {
      await Process.start(
        'cmd',
        ['/c', 'start', '', url.toString()],
        mode: ProcessStartMode.detached,
        runInShell: true,
      );
      return const LaunchResult('default', message: '已用默认浏览器打开');
    } catch (e) {
      return LaunchResult('failed', message: '无法打开浏览器：$e');
    }
  }

  String? _findBrowser(String preferred) {
    for (final candidate in _candidates(preferred)) {
      if (File(candidate).existsSync()) return candidate;
    }
    return null;
  }

  /// 按 `desktop.browser` 选择优先顺序；找不到时回退到另一个浏览器。
  List<String> _candidates(String preferred) {
    final programFiles = Platform.environment['ProgramFiles'] ?? r'C:\Program Files';
    final programFilesX86 =
        Platform.environment['ProgramFiles(x86)'] ?? r'C:\Program Files (x86)';
    final localAppData = Platform.environment['LOCALAPPDATA'] ?? '';
    final edge = [
      '$programFilesX86\\Microsoft\\Edge\\Application\\msedge.exe',
      '$programFiles\\Microsoft\\Edge\\Application\\msedge.exe',
      if (localAppData.isNotEmpty)
        '$localAppData\\Microsoft\\Edge\\Application\\msedge.exe',
    ];
    final chrome = [
      '$programFiles\\Google\\Chrome\\Application\\chrome.exe',
      '$programFilesX86\\Google\\Chrome\\Application\\chrome.exe',
      if (localAppData.isNotEmpty)
        '$localAppData\\Google\\Chrome\\Application\\chrome.exe',
    ];
    return switch (preferred) {
      'edge' => [...edge, ...chrome],
      'chrome' => [...chrome, ...edge],
      _ => [...edge, ...chrome],
    };
  }
}
