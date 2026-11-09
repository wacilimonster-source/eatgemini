import 'dart:typed_data';

import 'package:eatgemini/src/desktop/tray_glyph.dart';
import 'package:eatgemini/src/desktop/tray_protocol.dart';
import 'package:test/test.dart';

/// 解出某一帧的像素（top-down 坐标，返回 [r, g, b, a]）。
List<int> Function(int x, int y) framePixels(Uint8List ico, int size) {
  // 找到对应目录项。
  final count = ico[4] | (ico[5] << 8);
  var offset = 0;
  for (var i = 0; i < count; i++) {
    final e = 6 + i * 16;
    if (ico[e] == size) {
      offset = _u32(ico, e + 12);
    }
  }
  expect(offset, isNot(0), reason: 'ICO 里找不到 $size 帧图像');
  // BITMAPINFOHEADER 校验。
  final bd = ByteData.sublistView(ico);
  expect(bd.getUint32(offset, Endian.little), 40);
  expect(bd.getInt32(offset + 8, Endian.little), size * 2); // XOR+AND
  expect(bd.getUint16(offset + 14, Endian.little), 32); // 32bpp

  final rowBytes = size * 4;
  final xor = offset + 40;
  return (x, y) {
    final p = xor + (size - 1 - y) * rowBytes + x * 4; // bottom-up
    return [
      ico[p + 2],
      ico[p + 1],
      ico[p],
      ico[p + 3],
    ];
  };
}

int _u32(List<int> b, int i) =>
    b[i] | (b[i + 1] << 8) | (b[i + 2] << 16) | (b[i + 3] << 24);

void main() {
  group('buildTrayIco', () {
    test('结构：ICONDIR + 帧目录项，各帧 32bpp', () {
      final ico = buildTrayIco('ready');
      expect(ico[0] | (ico[1] << 8), 0); // reserved
      expect(ico[2] | (ico[3] << 8), 1); // type = icon
      final count = ico[4] | (ico[5] << 8);
      expect(count, kTrayFrameSizes.length);

      var cursor = 6 + count * 16;
      for (var i = 0; i < count; i++) {
        final e = 6 + i * 16;
        expect(ico[e], kTrayFrameSizes[i]);
        expect(ico[e + 1], kTrayFrameSizes[i]);
        expect(ico[e + 6] | (ico[e + 7] << 8), 32); // bitCount
        expect(_u32(ico, e + 12), cursor); // offset 连续
        cursor += _u32(ico, e + 8);
      }
      expect(cursor, ico.length);
    });

    test('像素：圆角外透明，宝石白色，芯片渐变随状态变色', () {
      final ready = framePixels(buildTrayIco('ready'), 32);
      final error = framePixels(buildTrayIco('error'), 32);

      // 四角外透明（圆角 9.8px，(1,1) 在圆角外）。
      for (final (x, y) in [(1, 1), (30, 1), (1, 30), (30, 30)]) {
        expect(ready(x, y)[3], lessThan(60), reason: '($x,$y) 应在圆角外');
      }

      // 宝石亭部（girdle 以下）实心白。
      for (final (x, y) in [(16, 16), (14, 17), (18, 17), (16, 19)]) {
        final gem = ready(x, y);
        expect(gem[3], greaterThan(240), reason: '($x,$y) 应不透明');
        expect(gem[0], greaterThan(230), reason: '($x,$y) 应为白色');
        expect(gem[1], greaterThan(230));
        expect(gem[2], greaterThan(230));
      }

      // 棱面线（girdle y≈13.3，宝石加大后 32 帧腰带线约在 y=13）切穿露出
      // 芯片色：绿色系而非白色。
      final facet = ready(10, 13);
      expect(facet[3], greaterThan(200));
      expect(facet[1], greaterThan(facet[0]), reason: '绿色芯片 g>r');

      // 芯片区随状态变色：绿 vs 红。
      final readyChip = ready(5, 5);
      final errorChip = error(5, 5);
      expect(readyChip[1], greaterThan(readyChip[0]));
      expect(errorChip[0], greaterThan(errorChip[1]));
    });

    test('档位互不串色：idle 是灰（r≈g≈b）', () {
      final idle = framePixels(buildTrayIco('idle'), 32);
      final chip = idle(5, 5);
      expect(chip[3], greaterThan(200));
      expect((chip[0] - chip[1]).abs(), lessThan(40));
      expect((chip[1] - chip[2]).abs(), lessThan(40));
    });
  });

  group('buildFaviconIco', () {
    test('结构与像素和托盘 ready 档一致（任务栏=托盘视觉）', () {
      final fav = buildFaviconIco();
      final count = fav[4] | (fav[5] << 8);
      expect(count, kFaviconFrameSizes.length);
      for (var i = 0; i < count; i++) {
        expect(fav[6 + i * 16], kFaviconFrameSizes[i]);
      }
      // 与托盘同一光栅化器：48 帧的像素应逐点一致（favicon 最小帧 40，
      // 见 tray_glyph.dart 的注释——Edge 窗口图标固定拿最小帧放大）。
      final trayReady = framePixels(buildTrayIco('ready'), 48);
      final favicon = framePixels(fav, 48);
      for (final (x, y) in [(6, 6), (20, 16), (24, 24), (24, 30), (1, 1)]) {
        expect(favicon(x, y), trayReady(x, y), reason: '($x,$y) 应与托盘一致');
      }
    });
  });

  group('状态映射与文案（F12）', () {
    test('托盘图标档位', () {
      expect(trayIconKeyForState('ready'), 'ready');
      expect(trayIconKeyForState('needs_key'), 'warn');
      expect(trayIconKeyForState('degraded'), 'warn');
      expect(trayIconKeyForState('config_error'), 'error');
      expect(trayIconKeyForState('port_conflict'), 'error');
      expect(trayIconKeyForState('persist_error'), 'error');
      expect(trayIconKeyForState('stopping'), 'idle');
    });

    test('悬停提示 ≤127 字符且带今日请求数', () {
      final tip = buildTrayTooltip(state: 'ready', todayRequests: 42);
      expect(tip, 'eatgemini · 运行中 · 今日 42 次');
      expect(buildTrayTooltip(state: 'ready', todayRequests: 1 << 60).length,
          lessThanOrEqualTo(127));
    });
  });
}
