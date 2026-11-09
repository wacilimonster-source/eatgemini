import 'package:eatgemini/src/adapters/transport.dart';
import 'package:eatgemini/src/core/config.dart';
import 'package:test/test.dart';

void main() {
  test('manual 模式使用配置的主机端口', () {
    final f = findProxyResolver(const ProxyConfig(
      mode: ProxyMode.manual,
      host: '127.0.0.1',
      port: 7897,
    ));
    expect(f(Uri.parse('https://x/')), 'PROXY 127.0.0.1:7897');
  });

  test('environment 模式：有环境变量时使用规范化后的规则', () {
    final f = findProxyResolver(
      const ProxyConfig(mode: ProxyMode.environment),
      envLookup: (key) => key == 'HTTPS_PROXY' ? '127.0.0.1:7897' : null,
    );
    expect(f(Uri.parse('https://x/')), 'PROXY 127.0.0.1:7897');
  });

  test('environment 模式：环境变量不存在时回落到配置的主机端口', () {
    final f = findProxyResolver(
      const ProxyConfig(
        mode: ProxyMode.environment,
        host: '127.0.0.1',
        port: 7897,
      ),
      envLookup: (_) => null,
    );
    expect(f(Uri.parse('https://x/')), 'PROXY 127.0.0.1:7897');
  });

  test('environment 模式：环境变量和主机端口都没有 → 直连', () {
    final f = findProxyResolver(
      const ProxyConfig(mode: ProxyMode.environment),
      envLookup: (_) => null,
    );
    expect(f(Uri.parse('https://x/')), 'DIRECT');
  });

  test('none 模式永远直连（即使填了主机端口）', () {
    final f = findProxyResolver(const ProxyConfig(
      mode: ProxyMode.none,
      host: '127.0.0.1',
      port: 7897,
    ));
    expect(f(Uri.parse('https://x/')), 'DIRECT');
  });

  test('normalizeProxyValue 兼容常见导出格式并保留协议', () {
    expect(normalizeProxyValue('127.0.0.1:7897'), 'PROXY 127.0.0.1:7897');
    expect(
        normalizeProxyValue('http://127.0.0.1:7897'), 'PROXY 127.0.0.1:7897');
    expect(
        normalizeProxyValue('http://127.0.0.1:7897/'), 'PROXY 127.0.0.1:7897');
    expect(
      normalizeProxyValue('http=10.0.0.1:8080;https=10.0.0.2:8443'),
      'PROXY 10.0.0.2:8443',
    );
    expect(normalizeProxyValue('a.com:1,b.com:2'), 'PROXY a.com:1');
    expect(normalizeProxyValue('DIRECT'), isNull);
    expect(normalizeProxyValue(''), isNull);
  });

  test('SOCKS 代理保留协议，不再当成 HTTP 代理', () {
    expect(
      normalizeProxyValue('socks5://127.0.0.1:7891'),
      'SOCKS5 127.0.0.1:7891',
    );
    expect(
      normalizeProxyValue('socks5h://127.0.0.1:7891'),
      'SOCKS5 127.0.0.1:7891',
    );
    expect(
      normalizeProxyValue('socks4://127.0.0.1:7890'),
      'SOCKS4 127.0.0.1:7890',
    );
    // 无端口时按协议补默认端口。
    expect(normalizeProxyValue('socks5://127.0.0.1'), 'SOCKS5 127.0.0.1:1080');
  });

  test('认证代理保留凭据供 authenticateProxy 使用', () {
    final endpoint = parseProxyValue('http://user:p%40ss@127.0.0.1:7890')!;
    expect(endpoint.rule, 'PROXY 127.0.0.1:7890');
    expect(endpoint.username, 'user');
    expect(endpoint.password, 'p@ss');
  });

  test('environment 模式：SOCKS 环境变量映射为 SOCKS5', () {
    final f = findProxyResolver(
      const ProxyConfig(mode: ProxyMode.environment),
      envLookup: (key) =>
          key.toUpperCase() == 'ALL_PROXY' ? 'socks5://127.0.0.1:7891' : null,
    );
    expect(f(Uri.parse('https://x/')), 'SOCKS5 127.0.0.1:7891');
  });

  test('effectiveProxySpec：环境变量优先，其次配置值', () {
    expect(
      effectiveProxySpec(
        const ProxyConfig(
            mode: ProxyMode.environment, host: '127.0.0.1', port: 7897),
        envLookup: (_) => null,
      ),
      'PROXY 127.0.0.1:7897',
    );
    expect(
      effectiveProxySpec(
        const ProxyConfig(mode: ProxyMode.environment),
        envLookup: (key) =>
            key == 'https_proxy' ? 'socks5://10.0.0.2:7890' : null,
      ),
      contains('SOCKS5 10.0.0.2:7890'),
    );
    expect(
      effectiveProxySpec(const ProxyConfig(mode: ProxyMode.none),
          envLookup: (_) => null),
      isNull,
    );
  });
}
