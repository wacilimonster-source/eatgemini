/// 托盘图标光栅化与 ICO 打包（纯 Dart，无 win32，供托盘 isolate 运行时生成）。
///
/// 视觉与界面品牌一致（设计规范 §08.1 / §04）：圆角方块 + 135° 渐变 + 白色
/// 宝石（i-gem 的 24 网格几何）。状态色映射 F12：绿=ready、
/// 黄=needs_key/degraded、红=config_error/port_conflict/persist_error、灰=其他。
/// 小尺寸（16-24px）下宝石占比加大、圆角收紧（见 _renderFrame 注释），
/// 否则任务栏/托盘上图形会被平色芯片淹没、观感发糊。
library;

import 'dart:math' as math;
import 'dart:typed_data';

/// 托盘包含的图标档位（ICO 内的帧尺寸）。
///
/// 24 一档对应 150% DPI 的 SM_CXSMICON（125%=20），否则该档位下托盘只能取
/// 20/32 最近帧，图标发虚。
const List<int> kTrayFrameSizes = [16, 20, 24, 32, 48];

/// favicon（任务栏/标签页图标）帧尺寸。
///
/// 实测（提取 Edge 窗口 HICON 逐帧比对）：Edge 生成窗口图标时固定拿 ICO 里
/// **最小的那一帧**放大到 SM_CXICON/SM_CXSMICON 的物理尺寸（125% DPI →
/// 40/20px），16px 帧被放大 2.5 倍是任务栏图标发糊的根源。因此这里只放
/// ≥40 的大帧：40 精确命中 125% 的 ICON_BIG（零重采样），48/64 供更大
/// 尺寸场景按需缩小；小尺寸表面一律由大帧缩小（缩小比放大清晰）。
/// 托盘图标不受影响（tray_isolate 用 kTrayFrameSizes 的专用帧）。
const List<int> kFaviconFrameSizes = [40, 48, 64];

/// 应用状态 → 图标档位（F12）。
String trayIconKeyForState(String state) => switch (state) {
      'ready' => 'ready',
      'needs_key' || 'degraded' => 'warn',
      'config_error' || 'port_conflict' || 'persist_error' => 'error',
      _ => 'idle',
    };

/// 图标档位 → 135° 渐变两端色（ARGB）。与界面 --ok/--warn/--err 同族。
const Map<String, List<int>> trayPalette = {
  'ready': [0xFF4FD79B, 0xFF1FA97A], // 绿：就绪
  'warn': [0xFFF6C35C, 0xFFE09A2E], // 黄：待配置 / 降级
  'error': [0xFFF27674, 0xFFD84542], // 红：错误
  'idle': [0xFF9DAAC0, 0xFF7D8EA9], // 灰：启动 / 退出中
};

/// i-gem 的 24 网格几何（与 assets/ui/app.js 的 sprite 一致）。
const List<List<double>> _gemOutline = [
  [7.3, 3.5],
  [16.7, 3.5],
  [21.0, 9.2],
  [12.0, 20.5],
  [3.0, 9.2],
];

const List<List<double>> _gemGirdle = [
  [3.0, 9.2],
  [21.0, 9.2],
];

/// 棱面线只保留冠部一段（桌面到底尖的 V 线会在小尺寸汇成一团）。
const List<List<double>> _gemVeeLeft = [
  [7.3, 3.5],
  [9.6, 9.2],
];

const List<List<double>> _gemVeeRight = [
  [16.7, 3.5],
  [14.4, 9.2],
];

/// 生成某个档位的完整 ICO 字节（16/20/24/32/48 五帧，32bpp BGRA + AND 掩码）。
Uint8List buildTrayIco(String key) {
  final frames = <Uint8List>[];
  for (final size in kTrayFrameSizes) {
    frames.add(_renderFrame(key, size));
  }
  return _packIco(kTrayFrameSizes, frames);
}

/// 生成 favicon.ico（ready 绿档，任务栏图标与托盘视觉一致）。
///
/// Edge/Chrome 的 `--app` 窗口把页面 favicon 用作窗口/任务栏图标；同一套
/// 光栅化器出像素，保证托盘（运行时）与任务栏（页面 favicon）看起来是
/// 同一颗宝石，且各档位整数像素、无缩放模糊。
Uint8List buildFaviconIco() {
  final frames = <Uint8List>[];
  for (final size in kFaviconFrameSizes) {
    frames.add(_renderFrame('ready', size));
  }
  return _packIco(kFaviconFrameSizes, frames);
}

/// 生成单帧 DIB（RT_ICON 资源格式：BITMAPINFOHEADER + BGRA + AND 掩码）。
///
/// `CreateIconFromResourceEx` 只认单张图像，不吃 ICO 容器——托盘加载走这里。
Uint8List buildTrayFrameDib(String key, int size) => _renderFrame(key, size);

/// 光栅化单帧：返回 bottom-up 的 BGRA DIB（BITMAPINFOHEADER + 像素 + 掩码）。
Uint8List _renderFrame(String key, int size) {
  final colors = trayPalette[key] ?? trayPalette['idle']!;
  // 小尺寸可读性优先：宝石 19/26（界面 logo 是 15/26，小图标下白宝石占比
  // 太小会被周围平色淹没、显得发糊），圆角 6.5/26 比界面芯片更方一点。
  final radius = size * 6.5 / 26;
  final glyph = size * 19 / 26;
  final scale = glyph / 24;
  final offset = (size - glyph) / 2;
  final facetStroke = math.max(0.9, size * 0.05);

  final ss = 4; // 超采样倍率：4x4 均值近似抗锯齿
  final n = size * ss;
  final inv = 1 / (ss * ss);
  final rgba = Float32List(size * size * 4);

  // 多边形/折线换算到超采样坐标。
  final outline = _mapPoly(_gemOutline, scale, offset, ss);
  final girdle = _mapPoly(_gemGirdle, scale, offset, ss);
  final veeLeft = _mapPoly(_gemVeeLeft, scale, offset, ss);
  final veeRight = _mapPoly(_gemVeeRight, scale, offset, ss);

  for (var y = 0; y < size; y++) {
    for (var x = 0; x < size; x++) {
      var r = 0.0, g = 0.0, b = 0.0, a = 0.0;
      for (var sy = 0; sy < ss; sy++) {
        for (var sx = 0; sx < ss; sx++) {
          final px = x * ss + sx + 0.5;
          final py = y * ss + sy + 0.5;
          // 芯片：圆角方块覆盖度。
          final cover = _roundedRectCoverage(px, py, n, radius * ss);
          if (cover <= 0) continue;
          // 135° 渐变（左上 → 右下）。
          final t = ((px + py) / (2 * n)).clamp(0.0, 1.0);
          var cr = _lerpCh(colors[0] >> 16 & 0xff, colors[1] >> 16 & 0xff, t);
          var cg = _lerpCh(colors[0] >> 8 & 0xff, colors[1] >> 8 & 0xff, t);
          var cb = _lerpCh(colors[0] & 0xff, colors[1] & 0xff, t);
          // 宝石：填充白色轮廓；棱面线"切穿"露出底色。
          if (_inPolygon(px, py, outline)) {
            final facet = _strokeHit(px, py, girdle, facetStroke * ss) ||
                _strokeHit(px, py, veeLeft, facetStroke * ss) ||
                _strokeHit(px, py, veeRight, facetStroke * ss);
            if (!facet) {
              cr = 255;
              cg = 255;
              cb = 255;
            }
          }
          r += cr;
          g += cg;
          b += cb;
          a += cover * 255;
        }
      }
      final i = (y * size + x) * 4;
      rgba[i] = r * inv;
      rgba[i + 1] = g * inv;
      rgba[i + 2] = b * inv;
      rgba[i + 3] = a * inv;
    }
  }

  // 打成 DIB：BITMAPINFOHEADER（biHeight=2×高，bottom-up）+ BGRA + AND 掩码。
  final rowBytes = size * 4;
  final maskRow = ((size + 31) ~/ 32) * 4;
  final out = ByteData(40 + rowBytes * size + maskRow * size);
  final bi = out;
  bi.setUint32(0, 40, Endian.little); // biSize
  bi.setInt32(4, size, Endian.little); // biWidth
  bi.setInt32(8, size * 2, Endian.little); // biHeight（XOR+AND）
  bi.setUint16(12, 1, Endian.little); // biPlanes
  bi.setUint16(14, 32, Endian.little); // biBitCount
  bi.setUint32(16, 0, Endian.little); // biCompression = BI_RGB
  bi.setUint32(20, rowBytes * size, Endian.little); // biSizeImage
  // 像素：bottom-up BGRA。
  for (var y = 0; y < size; y++) {
    final src = (size - 1 - y) * size * 4;
    var dst = 40 + y * rowBytes;
    for (var x = 0; x < size; x++) {
      final p = src + x * 4;
      out.setUint8(dst++, rgba[p + 2].round().clamp(0, 255));
      out.setUint8(dst++, rgba[p + 1].round().clamp(0, 255));
      out.setUint8(dst++, rgba[p].round().clamp(0, 255));
      out.setUint8(dst++, rgba[p + 3].round().clamp(0, 255));
    }
  }
  // AND 掩码：全 0（有 alpha 时按 alpha 混合）。
  return out.buffer.asUint8List();
}

List<List<double>> _mapPoly(
    List<List<double>> poly, double scale, double offset, int ss) {
  return [
    for (final p in poly)
      [(offset + p[0] * scale) * ss, (offset + p[1] * scale) * ss],
  ];
}

double _lerpCh(int a, int b, double t) => a + (b - a) * t;

/// 圆角方块覆盖度：在样本点处 1=内、0=外（圆角用 SDF 近似软边）。
double _roundedRectCoverage(double px, double py, int n, double r) {
  final half = n / 2;
  final dx = (px - half).abs() - (half - r);
  final dy = (py - half).abs() - (half - r);
  final outside = math.sqrt(math.max(dx, 0) * math.max(dx, 0) +
          math.max(dy, 0) * math.max(dy, 0)) -
      r;
  if (outside > 0.5) return 0;
  if (outside < -0.5) return 1;
  return 0.5 - outside; // 软边过渡 0..1
}

bool _inPolygon(double x, double y, List<List<double>> poly) {
  var inside = false;
  for (var i = 0, j = poly.length - 1; i < poly.length; j = i++) {
    final xi = poly[i][0], yi = poly[i][1];
    final xj = poly[j][0], yj = poly[j][1];
    if ((yi > y) != (yj > y) &&
        x < (xj - xi) * (y - yi) / (yj - yi) + xi) {
      inside = !inside;
    }
  }
  return inside;
}

bool _strokeHit(double px, double py, List<List<double>> poly, double width) {
  final half = width / 2;
  for (var i = 0; i < poly.length - 1; i++) {
    final d = _segDist(px, py, poly[i][0], poly[i][1], poly[i + 1][0],
        poly[i + 1][1]);
    if (d <= half) return true;
  }
  return false;
}

double _segDist(double px, double py, double ax, double ay, double bx, double by) {
  final abx = bx - ax, aby = by - ay;
  final apx = px - ax, apy = py - ay;
  final len2 = abx * abx + aby * aby;
  var t = len2 == 0 ? 0.0 : (apx * abx + apy * aby) / len2;
  t = t.clamp(0.0, 1.0);
  final dx = px - (ax + abx * t), dy = py - (ay + aby * t);
  return math.sqrt(dx * dx + dy * dy);
}

/// ICO 打包：ICONDIR + ICONDIRENTRY×n + 各帧 DIB。
Uint8List _packIco(List<int> sizes, List<Uint8List> frames) {
  final dirBytes = 6 + sizes.length * 16;
  var total = dirBytes;
  final offsets = <int>[];
  for (final f in frames) {
    offsets.add(total);
    total += f.length;
  }
  final out = ByteData(total);
  out.setUint16(0, 0, Endian.little); // reserved
  out.setUint16(2, 1, Endian.little); // type = icon
  out.setUint16(4, sizes.length, Endian.little);
  for (var i = 0; i < sizes.length; i++) {
    final e = 6 + i * 16;
    out.setUint8(e, sizes[i] >= 256 ? 0 : sizes[i]);
    out.setUint8(e + 1, sizes[i] >= 256 ? 0 : sizes[i]);
    out.setUint8(e + 2, 0); // 颜色数
    out.setUint8(e + 3, 0); // 保留
    out.setUint16(e + 4, 1, Endian.little); // planes
    out.setUint16(e + 6, 32, Endian.little); // bitCount
    out.setUint32(e + 8, frames[i].length, Endian.little);
    out.setUint32(e + 12, offsets[i], Endian.little);
  }
  for (var i = 0; i < frames.length; i++) {
    out.buffer.asUint8List().setRange(offsets[i], offsets[i] + frames[i].length, frames[i]);
  }
  return out.buffer.asUint8List();
}
