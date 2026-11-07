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

  test('environment 模式：有环境变量时交给 findProxyFromEnvironment', () {
    final f = findProxyResolver(
      const ProxyConfig(mode: ProxyMode.environment),
      envLookup: (key) => key == 'HTTPS_PROXY' ? '127.0.0.1:7897' : null,
    );
    // 环境变量存在时使用它（规范化为 host:port）。
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

  test('normalizeProxyValue 兼容常见导出格式', () {
    expect(normalizeProxyValue('127.0.0.1:7897'), '127.0.0.1:7897');
    expect(normalizeProxyValue('http://127.0.0.1:7897'), '127.0.0.1:7897');
    expect(normalizeProxyValue('http://127.0.0.1:7897/'), '127.0.0.1:7897');
    expect(
      normalizeProxyValue('http=10.0.0.1:8080;https=10.0.0.2:8443'),
      '10.0.0.2:8443',
    );
    expect(normalizeProxyValue('a.com:1,b.com:2'), 'a.com:1');
    expect(normalizeProxyValue('DIRECT'), isNull);
    expect(normalizeProxyValue(''), isNull);
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
        envLookup: (key) => key == 'https_proxy' ? '10.0.0.2:7890' : null,
      ),
      contains('环境变量'),
    );
    expect(
      effectiveProxySpec(const ProxyConfig(mode: ProxyMode.none),
          envLookup: (_) => null),
      isNull,
    );
  });
}
