/// 控制台服务：只监听回环，提供监控页面与管理 API。
///
/// 规则来源：桌面文档 §9。
/// 与会话相关的硬性要求：一次性票据、HttpOnly Cookie、Host 校验、
/// 非 GET 的 Origin + CSRF 校验、严格 CSP。
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import '../core/config.dart';
import 'assets.dart';
import 'assets.g.dart';

abstract interface class ConsoleHost {
  String get version;
  String get gatewayBaseUrl;
  bool get isLanMode;
  List<String> get lanAddresses;

  Map<String, Object?> snapshot();
  Stream<(String, Map<String, Object?>)> events();
  Future<void> openWindow();

  Map<String, Object?> modelsState();
  Map<String, Object?> requests({
    String? client,
    String? outcome,
    String? model,
    int limit,
    int? beforeMs,
  });
  Map<String, Object?>? requestById(String requestId);

  Map<String, Object?> connectInfo();
  String revealToken(String clientId);
  Future<Map<String, Object?>> rotateToken(String clientId);
  String pockettavernConnectCode();

  Map<String, Object?> secretsInfo();
  Future<Map<String, Object?>> verifyUpstreamKey(String key);
  Future<Map<String, Object?>> saveUpstreamKey(
    String key, {
    required bool sameProject,
    String? projectRef,
  });
  Future<void> deleteUpstreamKey();

  Map<String, Object?> readConfig();
  Future<Map<String, Object?>> writeConfig(
      int revision, Map<String, Object?> config);
  Future<Map<String, Object?>> reloadConfig();
  Future<void> resetConfig();
  Future<Map<String, Object?>> checkUpstream();
  Future<Map<String, Object?>> refreshModels();
  bool clearLocalEstimate(String bucketId);
  Future<void> setModelEnabled(String modelId, bool enabled);

  Map<String, Object?> diagnostics();
  Future<String> exportDiagnostics();

  Future<void> openDataDir();
  Future<Map<String, Object?>> setListen({String? mode, int? port});
  Future<void> requestExit();
}

class ConsoleServer {
  ConsoleServer({
    required this.host,
    required this.backendLimitList,
    Random? random,
    this.appVersion = '1.0.0',
  }) : _random = random ?? Random.secure();

  final ConsoleHost host;
  final List<BackendCounter> backendLimitList;
  final Random _random;
  final String appVersion;

  HttpServer? _server;
  String? _ticket;
  DateTime? _ticketExpires;
  final Map<String, String> _sessions = {}; // session -> csrf
  int _sseCount = 0;

  int get port => _server?.port ?? 0;

  /// 当前控制台 SSE 连接数（0 = 监控窗口已关闭，供托盘关窗检测 §4.4）。
  int get sseConnections => _sseCount;

  Future<void> start() async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    _server = server;
    server.autoCompress = true;
    unawaited(_loop());
  }

  Future<void> stop() async {
    await _server?.close(force: true);
    _server = null;
  }

  Future<void> _loop() async {
    final server = _server;
    if (server == null) return;
    await for (final req in server) {
      unawaited(_handle(req));
    }
  }

  /// 生成一次性启动票据（桌面文档 §9.1）。
  String createLaunchTicket() {
    _ticket = _randomString(32);
    _ticketExpires = DateTime.now().add(const Duration(seconds: 60));
    return _ticket!;
  }

  Uri launchUri() =>
      Uri.parse('http://127.0.0.1:$port/ui/launch?t=${createLaunchTicket()}');

  Future<void> _handle(HttpRequest req) async {
    try {
      _securityHeaders(req.response);
      final hostHeader = req.headers.value('host') ?? '';
      final expected = '127.0.0.1:$port';
      final expectedLocal = 'localhost:$port';
      if (hostHeader != expected && hostHeader != expectedLocal) {
        await _text(req, 421, 'Misdirected Request');
        return;
      }

      final path = req.uri.path;

      if (path == '/ipc/show' && req.method == 'POST') {
        await _handleIpc(req);
        return;
      }

      if (path == '/ui/launch' && req.method == 'GET') {
        await _handleLaunch(req);
        return;
      }

      // ---- 会话校验 ----
      final session = _sessionFromCookie(req);
      if (session == null) {
        await _json(req, 401, {
          'error': {'code': 'no_session', 'message': '会话已失效，请重新打开监控窗口'}
        });
        return;
      }

      if (req.method != 'GET' && req.method != 'HEAD') {
        final origin = req.headers.value('origin');
        final allowed = ['http://127.0.0.1:$port', 'http://localhost:$port'];
        if (origin != null && !allowed.contains(origin)) {
          await _json(req, 403, {
            'error': {'code': 'bad_origin', 'message': 'Origin 不被允许'}
          });
          return;
        }
        final csrf = req.headers.value('x-egc-csrf');
        if (csrf == null || csrf != _sessions[session]) {
          await _json(req, 403, {
            'error': {'code': 'bad_csrf', 'message': 'CSRF 校验失败'}
          });
          return;
        }
      }

      if (path == '/api/events') {
        await _handleEvents(req);
        return;
      }
      if (path == '/api/snapshot') {
        await _json(req, 200, {
          ...host.snapshot(),
          'csrf': _sessions[session],
        });
        return;
      }
      if (path.startsWith('/ui/')) {
        await _serveAsset(req, path);
        return;
      }
      if (path.startsWith('/api/')) {
        await _handleApi(req, path);
        return;
      }
      await _text(req, 404, 'Not Found');
    } catch (e) {
      try {
        await _json(req, 500, {
          'error': {'code': 'internal', 'message': '$e'}
        });
      } catch (_) {}
    }
  }

  void _securityHeaders(HttpResponse res) {
    res.headers.set('content-security-policy',
        "default-src 'self'; script-src 'self'; style-src 'self'; "
        "img-src 'self' data:; connect-src 'self'; frame-ancestors 'none'; "
        "base-uri 'none'; form-action 'self'");
    res.headers.set('x-content-type-options', 'nosniff');
    res.headers.set('referrer-policy', 'no-referrer');
    res.headers.set('cache-control', 'no-store');
  }

  String? _sessionFromCookie(HttpRequest req) {
    for (final cookie in req.cookies) {
      if (cookie.name == 'egc_session' && _sessions.containsKey(cookie.value)) {
        return cookie.value;
      }
    }
    return null;
  }

  Future<void> _handleIpc(HttpRequest req) async {
    final nonce = req.headers.value('x-eatgemini-ipc');
    if (nonce == null || nonce != _ipcNonce) {
      await _text(req, 403, 'Forbidden');
      return;
    }
    await host.openWindow();
    await _text(req, 204, '');
  }

  String? _ipcNonce;

  /// 由应用层在启动时注入，写入 instance.json。
  set ipcNonce(String value) => _ipcNonce = value;

  Future<void> _handleLaunch(HttpRequest req) async {
    final t = req.uri.queryParameters['t'];
    final expires = _ticketExpires;
    if (t == null ||
        _ticket == null ||
        t != _ticket ||
        expires == null ||
        DateTime.now().isAfter(expires)) {
      await _text(req, 403,
          '<!doctype html><meta charset="utf-8"><p>启动票据无效或已过期。'
          '请从托盘图标或重新双击 eatgemini.exe 打开监控窗口。</p>');
      return;
    }
    _ticket = null;
    _ticketExpires = null;
    final session = _randomString(32);
    final csrf = _randomString(24);
    _sessions[session] = csrf;
    final cookie = Cookie('egc_session', session)
      ..httpOnly = true
      ..sameSite = SameSite.strict
      ..path = '/';
    req.response.cookies.add(cookie);
    req.response.statusCode = 302;
    req.response.headers.set('location', '/ui/');
    await req.response.close();
  }

  /// SSE 实时事件流（监控页 `EventSource('/api/events')`）。
  ///
  /// Windows 上有个关键坑：客户端断开后，HttpResponse 的写入会静默成功、
  /// `res.done` 永不完成（实测裸 HttpClient/EventSource 消失后 ping 十几分钟
  /// 仍无错误），SSE 计数永远不回落 → 托盘的关窗检测（§4.4）彻底失效。
  /// 因此这里先发头帧后 `detachSocket`，改在原生 socket 上写流：
  /// `onDone`/`onError` 可靠感知断连（FIN 与 RST 均触发，已实测）。
  ///
  /// detach 前必须关掉分块编码（无 Content-Length 的 HTTP/1.1 默认 chunked），
  /// 否则客户端会按 chunked 解析 detach 后的裸字节。改用 close-delimited：
  /// 连接只在服务端退出时关闭，EventSource 断线自动重连的行为不变。
  Future<void> _handleEvents(HttpRequest req) async {
    final res = req.response;
    res.statusCode = 200;
    res.headers.set('content-type', 'text/event-stream; charset=utf-8');
    res.headers.set('cache-control', 'no-cache, no-transform');
    res.headers.set('x-accel-buffering', 'no');
    res.headers.set('connection', 'close');
    res.persistentConnection = false;
    res.headers.chunkedTransferEncoding = false;
    res.bufferOutput = false;
    await res.flush();

    final socket = await res.detachSocket();
    _sseCount++;

    StreamSubscription<(String, Map<String, Object?>)>? sub;
    Timer? heartbeat;
    var closed = false;
    void cleanup() {
      if (closed) return;
      closed = true;
      _sseCount--;
      heartbeat?.cancel();
      unawaited(sub?.cancel());
      try {
        socket.destroy();
      } catch (_) {}
    }

    void send(String frame) {
      if (closed) return;
      try {
        // 只 write 不 flush：detach 后的 IOSink 在内部 addStream 未完成时调
        // flush 会抛 "StreamSink is bound to a stream"（竞态），而原生 socket
        // 的写队列本就会在事件循环里自动排空，无需显式 flush。
        socket.write(frame);
      } catch (_) {
        cleanup();
      }
    }

    // 首帧：会话可用标志。
    send('event: hello\ndata: {"api":$kApiVersion}\n\n');

    sub = host.events().listen((event) {
      send('event: ${event.$1}\ndata: ${jsonEncode(event.$2)}\n\n');
    });
    heartbeat = Timer.periodic(const Duration(seconds: 15), (_) {
      send(': ping\n\n');
    });
    socket.listen(
      (_) {},
      onDone: cleanup,
      onError: (Object _) => cleanup,
      cancelOnError: true,
    );
  }

  Future<void> _handleApi(HttpRequest req, String path) async {
    final segments = path.split('/').where((s) => s.isNotEmpty).toList();

    if (path == '/api/models' && req.method == 'GET') {
      await _json(req, 200, host.modelsState());
      return;
    }
    if (segments.length == 4 &&
        segments[1] == 'models' &&
        segments[3] == 'enabled' &&
        req.method == 'POST') {
      final body = await _readJson(req);
      final enabled = body['enabled'] == true;
      await host.setModelEnabled(segments[2], enabled);
      await _json(req, 200, {'ok': true});
      return;
    }
    if (segments.length == 4 &&
        segments[1] == 'buckets' &&
        segments[3] == 'clear-local-estimate' &&
        req.method == 'POST') {
      final ok = host.clearLocalEstimate(Uri.decodeComponent(segments[2]));
      await _json(req, ok ? 200 : 409, {
        'ok': ok,
        if (!ok) 'message': '该桶有上游确认的封锁，不能在本机清除',
      });
      return;
    }
    if (path == '/api/router/refresh' && req.method == 'POST') {
      await _json(req, 200, await host.refreshModels());
      return;
    }
    if (path == '/api/requests' && req.method == 'GET') {
      final q = req.uri.queryParameters;
      await _json(req, 200, host.requests(
        client: q['client'],
        outcome: q['outcome'],
        model: q['model'],
        limit: int.tryParse(q['limit'] ?? '') ?? 100,
        beforeMs: int.tryParse(q['before'] ?? ''),
      ));
      return;
    }
    if (segments.length == 3 &&
        segments[1] == 'requests' &&
        req.method == 'GET') {
      final detail = host.requestById(segments[2]);
      if (detail == null) {
        await _json(req, 404, {
          'error': {'code': 'not_found', 'message': '没有这条请求记录'}
        });
        return;
      }
      await _json(req, 200, detail);
      return;
    }
    if (path == '/api/connect' && req.method == 'GET') {
      await _json(req, 200, host.connectInfo());
      return;
    }
    if (segments.length == 4 &&
        segments[1] == 'connect' &&
        segments[3] == 'reveal' &&
        req.method == 'POST') {
      await _json(req, 200, {'token': host.revealToken(segments[2])});
      return;
    }
    if (segments.length == 4 &&
        segments[1] == 'connect' &&
        segments[3] == 'rotate' &&
        req.method == 'POST') {
      await _json(req, 200, await host.rotateToken(segments[2]));
      return;
    }
    if (path == '/api/connect/pockettavern/code' && req.method == 'POST') {
      await _json(req, 200, {'code': host.pockettavernConnectCode()});
      return;
    }
    if (path == '/api/secrets/upstream' && req.method == 'GET') {
      await _json(req, 200, host.secretsInfo());
      return;
    }
    if (path == '/api/secrets/upstream/verify' && req.method == 'POST') {
      final body = await _readJson(req);
      await _json(req, 200, await host.verifyUpstreamKey('${body['apiKey'] ?? ''}'));
      return;
    }
    if (path == '/api/secrets/upstream' && req.method == 'PUT') {
      final body = await _readJson(req);
      await _json(
        req,
        200,
        await host.saveUpstreamKey(
          '${body['apiKey'] ?? ''}',
          sameProject: body['sameProject'] != false,
          projectRef: body['projectRef']?.toString(),
        ),
      );
      return;
    }
    if (path == '/api/secrets/upstream' && req.method == 'DELETE') {
      await host.deleteUpstreamKey();
      await _json(req, 200, {'ok': true});
      return;
    }
    if (path == '/api/config' && req.method == 'GET') {
      await _json(req, 200, host.readConfig());
      return;
    }
    if (path == '/api/config' && req.method == 'PUT') {
      final body = await _readJson(req);
      final revision = (body['revision'] as num?)?.toInt() ?? 0;
      final config = body['config'];
      if (config is! Map) {
        await _json(req, 400, {
          'error': {'code': 'invalid_request', 'message': 'config 必须是对象'}
        });
        return;
      }
      await _json(
          req, 200, await host.writeConfig(revision, config.cast<String, Object?>()));
      return;
    }
    if (path == '/api/config/reload' && req.method == 'POST') {
      await _json(req, 200, await host.reloadConfig());
      return;
    }
    if (path == '/api/config/reset' && req.method == 'POST') {
      await host.resetConfig();
      await _json(req, 200, host.readConfig());
      return;
    }
    if (path == '/api/upstream/check' && req.method == 'POST') {
      await _json(req, 200, await host.checkUpstream());
      return;
    }
    if (path == '/api/diagnostics' && req.method == 'GET') {
      await _json(req, 200, host.diagnostics());
      return;
    }
    if (path == '/api/diagnostics/export' && req.method == 'POST') {
      final file = await host.exportDiagnostics();
      await _json(req, 200, {'path': file, 'ok': true});
      return;
    }
    if (path == '/api/app/listen' && req.method == 'POST') {
      final body = await _readJson(req);
      final mode = body['mode']?.toString();
      final port = (body['port'] as num?)?.toInt();
      await _json(req, 200, await host.setListen(mode: mode, port: port));
      return;
    }
    if (path == '/api/app/open-data-dir' && req.method == 'POST') {
      await host.openDataDir();
      await _json(req, 200, {'ok': true});
      return;
    }
    if (path == '/api/app/open-window' && req.method == 'POST') {
      await host.openWindow();
      await _json(req, 200, {'ok': true});
      return;
    }
    if (path == '/api/app/exit' && req.method == 'POST') {
      await _json(req, 200, {'ok': true});
      unawaited(host.requestExit());
      return;
    }

    await _json(req, 404, {
      'error': {'code': 'not_found', 'message': '未知接口 $path'}
    });
  }

  Future<void> _serveAsset(HttpRequest req, String path) async {
    final key = path == '/ui/' ? '/ui/index.html' : path;
    final asset = kUiAssets[key] ?? _diskAsset(key);
    if (asset == null) {
      await _text(req, 404, 'Not Found');
      return;
    }
    final etag = asset.etag;
    if (req.headers.value('if-none-match') == etag) {
      req.response.statusCode = 304;
      await req.response.close();
      return;
    }
    req.response.statusCode = 200;
    req.response.headers.set('content-type', asset.mime);
    req.response.headers.set('etag', etag);
    req.response.add(asset.bytes);
    await req.response.close();
  }

  EmbeddedAsset? _diskAsset(String key) {
    try {
      final rel = key.replaceFirst('/ui/', '');
      // 先按 URI 规则归一化 ..，再确认仍位于 assets/ui 内；同时拒绝
      // Windows 反斜杠/盘符，避免 `/ui/..\..\pubspec.yaml` 逃逸（G8）。
      final normalized = Uri(path: '/ui/$rel').normalizePath().path;
      if (!normalized.startsWith('/ui/')) return null;
      final safeRel = normalized.substring('/ui/'.length);
      if (safeRel.isEmpty ||
          safeRel.contains('\\') ||
          safeRel.contains(':') ||
          safeRel.contains('\u0000')) {
        return null;
      }
      final file = File('assets/ui/$safeRel');
      if (!file.existsSync()) return null;
      final bytes = file.readAsBytesSync();
      return EmbeddedAsset(
        mime: _mimeOf(safeRel),
        bytes: bytes,
        etag: 'w${bytes.length}',
      );
    } catch (_) {
      return null;
    }
  }

  static String _mimeOf(String name) {
    if (name.endsWith('.html')) return 'text/html; charset=utf-8';
    if (name.endsWith('.css')) return 'text/css; charset=utf-8';
    if (name.endsWith('.js')) return 'text/javascript; charset=utf-8';
    if (name.endsWith('.svg')) return 'image/svg+xml';
    if (name.endsWith('.ico')) return 'image/x-icon';
    if (name.endsWith('.json')) return 'application/json; charset=utf-8';
    return 'application/octet-stream';
  }

  Future<Map<String, Object?>> _readJson(HttpRequest req) async {
    final raw = await utf8.decoder.bind(req).join();
    if (raw.trim().isEmpty) return {};
    try {
      final decoded = jsonDecode(raw);
      return decoded is Map ? decoded.cast<String, Object?>() : {};
    } catch (_) {
      return {};
    }
  }

  Future<void> _json(HttpRequest req, int status, Map<String, Object?> body) async {
    req.response.statusCode = status;
    req.response.headers.contentType =
        ContentType('application', 'json', charset: 'utf-8');
    req.response.write(jsonEncode(body));
    await req.response.close();
  }

  Future<void> _text(HttpRequest req, int status, String body) async {
    req.response.statusCode = status;
    final isHtml = body.startsWith('<!doctype') || body.startsWith('<');
    req.response.headers.contentType =
        ContentType.parse(isHtml ? 'text/html; charset=utf-8' : 'text/plain; charset=utf-8');
    req.response.write(body);
    await req.response.close();
  }

  String _randomString(int length) {
    const chars = 'abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789';
    return List.generate(length, (_) => chars[_random.nextInt(chars.length)])
        .join();
  }
}

/// 兜底计数器类型（保持接口稳定，当前未使用）。
class BackendCounter {
  int value = 0;
}
