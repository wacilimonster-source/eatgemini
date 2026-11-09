/// 上游传输层。
///
/// 内核只依赖这里的抽象，测试替换成 fake；桌面版用 dart:io 实现，
/// 并在此统一注入代理与出站白名单（桌面文档 §7.2）。
library;

import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import '../core/config.dart';

/// 出站白名单拦截：必须在建立连接前抛出。
class EgressDenied implements Exception {
  EgressDenied(this.host);

  final String host;

  @override
  String toString() => '已阻止发往 $host 的连接（不在允许的上游/代理列表内）';
}

/// 出站策略。桌面版由上游地址与代理配置构造；测试默认放行。
abstract interface class EgressPolicy {
  void check(Uri target);
}

class AllowAllEgress implements EgressPolicy {
  const AllowAllEgress();

  @override
  void check(Uri target) {}
}

class UpstreamRequest {
  const UpstreamRequest({
    required this.uri,
    required this.headers,
    required this.body,
  });

  final Uri uri;
  final Map<String, String> headers;
  final Uint8List body;
}

/// 上游响应句柄：状态、头、字节流与取消能力。
class UpstreamResponse {
  UpstreamResponse({
    required this.statusCode,
    required this.headers,
    required this.body,
    required this.cancel,
    required this.headerLatencyMs,
  });

  final int statusCode;

  /// 键统一小写。
  final Map<String, String> headers;
  final Stream<List<int>> body;
  final Future<void> Function() cancel;
  final int headerLatencyMs;
}

abstract interface class Transport {
  Future<UpstreamResponse> send(
    UpstreamRequest request, {
    required Duration firstEventTimeout,
  });

  Future<void> close();
}

/// 解析后的代理端点。`type` 为 Dart findProxy 支持的协议关键字。
class ProxyEndpoint {
  const ProxyEndpoint({
    required this.type,
    required this.host,
    required this.port,
    this.username,
    this.password,
  });

  final String type; // PROXY / SOCKS5 / SOCKS4
  final String host;
  final int port;
  final String? username;
  final String? password;

  String get rule => '$type $host:$port';
}

const _proxyEnvKeys = [
  'https_proxy',
  'HTTPS_PROXY',
  'http_proxy',
  'HTTP_PROXY',
  'all_proxy',
  'ALL_PROXY',
];

(String, String)? _firstEnvProxy(String? Function(String key) lookup) {
  for (final key in _proxyEnvKeys) {
    final value = lookup(key);
    if (value != null && value.trim().isNotEmpty) {
      return (key, value.trim());
    }
  }
  return null;
}

/// 把代理值解析成带协议的端点；解析不了返回 null。
///
/// 保留 scheme 很关键：`socks5://host:port` 必须映射成 `SOCKS5 host:port`，
/// 统一拼成 `PROXY` 会用 HTTP 协议去连 SOCKS 端口（G7）。凭据单独返回，
/// 由 [applyProxyToClient] 通过 authenticateProxy 注入。
ProxyEndpoint? parseProxyValue(String raw) {
  var value = raw.trim();
  if (value.isEmpty) return null;
  // `http=host:port;https=host:port`：优先 https 条目
  if (value.contains('=')) {
    final entries = value.split(';');
    String? https;
    String? http;
    for (final entry in entries) {
      final kv = entry.split('=');
      if (kv.length != 2) continue;
      if (kv[0].trim().toLowerCase() == 'https') https = kv[1].trim();
      if (kv[0].trim().toLowerCase() == 'http') http = kv[1].trim();
    }
    value = https ?? http ?? '';
    if (value.isEmpty) return null;
  }
  // 逗号分隔的列表取第一个
  value = value.split(',').first.trim();
  if (value.isEmpty || value.toLowerCase() == 'direct') return null;
  final uri = Uri.tryParse(value.contains('://') ? value : 'http://$value');
  if (uri == null || uri.host.isEmpty) return null;
  final scheme = (uri.scheme.isEmpty ? 'http' : uri.scheme).toLowerCase();
  final type = switch (scheme) {
    'socks5' || 'socks5h' || 'socks' => 'SOCKS5',
    'socks4' || 'socks4a' => 'SOCKS4',
    _ => 'PROXY',
  };
  final port = uri.hasPort
      ? uri.port
      : switch (scheme) {
          'socks5' || 'socks5h' || 'socks' || 'socks4' || 'socks4a' => 1080,
          'https' => 443,
          _ => 80,
        };
  String? username;
  String? password;
  if (uri.userInfo.isNotEmpty) {
    final idx = uri.userInfo.indexOf(':');
    if (idx >= 0) {
      username = Uri.decodeComponent(uri.userInfo.substring(0, idx));
      password = Uri.decodeComponent(uri.userInfo.substring(idx + 1));
    } else {
      username = Uri.decodeComponent(uri.userInfo);
      password = '';
    }
  }
  return ProxyEndpoint(
    type: type,
    host: uri.host,
    port: port,
    username: username,
    password: password,
  );
}

/// 把环境变量里的代理值规范化成 Dart findProxy 规则（含协议关键字）；
/// 解析不了返回 null。
String? normalizeProxyValue(String raw) => parseProxyValue(raw)?.rule;

/// 解析当前生效的代理端点。
ProxyEndpoint? resolveProxy(
  ProxyConfig proxy, {
  String? Function(String key)? envLookup,
}) {
  switch (proxy.mode) {
    case ProxyMode.none:
      return null;
    case ProxyMode.manual:
      if (proxy.host == null || proxy.port == null) return null;
      return ProxyEndpoint(
        type: 'PROXY',
        host: proxy.host!,
        port: proxy.port!,
      );
    case ProxyMode.environment:
    case ProxyMode.system:
      // 自己解析并规范化环境变量：clash 等工具导出的值常见
      // `http://host:port` 或 `http=..;https=..` 形态。
      final found = _firstEnvProxy(envLookup ?? (key) => Platform.environment[key]);
      if (found != null) {
        final parsed = parseProxyValue(found.$2);
        if (parsed != null) return parsed;
      }
      if (proxy.host == null || proxy.port == null) return null;
      return ProxyEndpoint(
        type: 'PROXY',
        host: proxy.host!,
        port: proxy.port!,
      );
  }
}

/// 解析代理配置为 Dart `findProxy` 函数。
///
/// 规则（内核文档 §13.1 + 桌面实测补充）：
/// - none → DIRECT；
/// - manual → PROXY host:port；
/// - environment / system → 优先环境变量（HTTPS_PROXY 等），保留
///   http/socks 协议与凭据；环境变量不存在时回落配置里的 host/port。
String Function(Uri) findProxyResolver(
  ProxyConfig proxy, {
  String? Function(String key)? envLookup,
}) {
  final endpoint = resolveProxy(proxy, envLookup: envLookup);
  return (_) => endpoint?.rule ?? 'DIRECT';
}

/// 给 HttpClient 应用代理与认证信息。
void applyProxyToClient(
  HttpClient client,
  ProxyConfig proxy, {
  String? Function(String key)? envLookup,
}) {
  final endpoint = resolveProxy(proxy, envLookup: envLookup);
  client.findProxy = (_) => endpoint?.rule ?? 'DIRECT';
  final username = endpoint?.username;
  if (endpoint == null || username == null) return;
  client.authenticateProxy = (host, port, scheme, realm) async {
    client.addCredentials(
      Uri(scheme: scheme, host: host, port: port),
      realm ?? '',
      HttpClientBasicCredentials(username, endpoint.password ?? ''),
    );
    return true;
  };
}

/// 当前实际生效的代理描述（诊断/日志用；不含凭据）。
String? effectiveProxySpec(
  ProxyConfig proxy, {
  String? Function(String key)? envLookup,
}) {
  switch (proxy.mode) {
    case ProxyMode.none:
      return null;
    case ProxyMode.manual:
      return resolveProxy(proxy)?.rule;
    case ProxyMode.environment:
    case ProxyMode.system:
      final lookup = envLookup ?? (key) => Platform.environment[key];
      final found = _firstEnvProxy(lookup);
      if (found != null) {
        final rule = parseProxyValue(found.$2)?.rule ?? 'DIRECT';
        return '环境变量 ${found.$1} → $rule';
      }
      return resolveProxy(proxy, envLookup: envLookup)?.rule;
  }
}

class DartIoTransport implements Transport {
  DartIoTransport({
    required RouterConfig Function() config,
    EgressPolicy egress = const AllowAllEgress(),
  })  : _config = config,
        _egress = egress,
        _client = HttpClient() {
    reconfigure();
  }


  final RouterConfig Function() _config;
  final EgressPolicy _egress;
  final HttpClient _client;

  RouterConfig get config => _config();

  /// 配置热加载后重新应用代理与超时。
  void reconfigure() {
    _client.connectionTimeout =
        Duration(milliseconds: config.upstream.connectTimeoutMs);
    _applyProxy();
  }

  void _applyProxy() {
    applyProxyToClient(_client, config.upstream.proxy);
  }

  @override
  Future<UpstreamResponse> send(
    UpstreamRequest request, {
    required Duration firstEventTimeout,
  }) async {
    _egress.check(request.uri);
    final started = DateTime.now();
    final req = await _client.openUrl('POST', request.uri);
    req.followRedirects = false;
    request.headers.forEach(req.headers.set);
    req.add(request.body);
    HttpClientResponse response;
    try {
      response = await req.close().timeout(firstEventTimeout);
    } on TimeoutException {
      // 头都没回来：取消请求并报告超时，由选路层按 transient 处理。
      req.abort(StateError('first event timeout'));
      rethrow;
    }

    final headers = <String, String>{};
    response.headers.forEach((name, values) {
      headers[name.toLowerCase()] = values.join(',');
    });
    var cancelled = false;
    // 该响应是否已被完整消费：消费完就不必再中断连接。
    var consumed = false;
    final trackedBody = response
        .transform<List<int>>(StreamTransformer.fromHandlers(
      handleDone: (sink) {
        consumed = true;
        sink.close();
      },
    ));
    return UpstreamResponse(
      statusCode: response.statusCode,
      headers: headers,
      body: trackedBody,
      headerLatencyMs: DateTime.now().difference(started).inMilliseconds,
      cancel: () async {
        if (cancelled || consumed) return;
        cancelled = true;
        // 中断连接：abort 会让底层 socket 销毁，不再归还连接池。
        try {
          req.abort(StateError('cancelled'));
        } catch (_) {
          // 请求已完成或连接已断开：忽略。
        }
      },
    );
  }

  @override
  Future<void> close() async => _client.close(force: true);
}

/// 由白名单主机集合构成的出站策略（桌面文档 §7.2）。
class AllowlistEgress implements EgressPolicy {
  AllowlistEgress({required this.allowedHosts});

  final Set<String> allowedHosts;

  @override
  void check(Uri target) {
    if (!target.isScheme('https') && !_isLoopback(target)) {
      throw EgressDenied(target.host);
    }
    if (!allowedHosts.contains(target.host.toLowerCase())) {
      throw EgressDenied(target.host);
    }
  }

  bool _isLoopback(Uri uri) =>
      uri.host == '127.0.0.1' || uri.host == 'localhost' || uri.host == '::1';
}
