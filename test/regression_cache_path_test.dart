import 'package:flutter_test/flutter_test.dart';
import 'package:nano_client/core/config/app_config.dart';
import 'package:nano_client/core/proxy/singbox_config.dart';
import 'package:nano_client/core/subscription/proxy_node.dart';

ProxyNode node() => ProxyNode(
  protocol: 'vless',
  tag: '东京',
  server: 'cos-cdn-a.example.win',
  port: 443,
  params: {'uuid': 'u', 'type': 'ws', 'security': 'tls', 'fp': 'qq'},
);

void main() {
  // 回归：线上实际崩溃 —— "type '_Map<String, Object>' is not a subtype of ..."
  // 只在 cachePath 非空（真实连接时必然非空）时触发。
  test('cachePath 非空时能生成并序列化配置', () {
    final config = buildSingboxConfig(
      nodes: [node()],
      proxy: const ProxyConfig(),
      availableRuleSets: const [],
      cachePath: '/tmp/cache.db',
    );

    final experimental = config['experimental'] as Map<String, dynamic>;
    expect(experimental['cache_file'], isNotNull);
    expect(experimental['clash_api'], isNotNull);

    expect(() => encodeConfig(config), returnsNormally);
  });

  test('enableTun 时也能生成并序列化配置', () {
    final config = buildSingboxConfig(
      nodes: [node()],
      proxy: const ProxyConfig(enableTun: true),
      availableRuleSets: const [],
      cachePath: '/tmp/cache.db',
    );
    expect(() => encodeConfig(config), returnsNormally);
    expect((config['inbounds'] as List).length, 2);
  });
}
