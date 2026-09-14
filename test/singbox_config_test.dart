import 'package:flutter_test/flutter_test.dart';
import 'package:nano_client/core/config/app_config.dart';
import 'package:nano_client/core/proxy/singbox_config.dart';
import 'package:nano_client/core/subscription/proxy_node.dart';

ProxyNode vlessNode({String tag = '东京 01'}) => ProxyNode(
  protocol: 'vless',
  tag: tag,
  server: 'cos-cdn-a.example.win',
  port: 443,
  params: {
    'uuid': '11111111-2222-3333-4444-555555555555',
    'type': 'ws',
    'security': 'tls',
    'sni': 'mms.example.sbs',
    'fp': 'qq',
    'path': '/newlogin/login.do',
    'host': 'cdn.example.sbs',
  },
);

Map<String, dynamic> build(
  ProxyConfig proxy, {
  List<String> ruleSets = const ['geosite-cn', 'geoip-cn'],
  String? defaultNodeTag,
}) => buildSingboxConfig(
  nodes: [vlessNode()],
  proxy: proxy,
  availableRuleSets: ruleSets,
  defaultNodeTag: defaultNodeTag,
  cachePath: null,
);

List<Map<String, dynamic>> rulesOf(Map<String, dynamic> config) =>
    ((config['route'] as Map<String, dynamic>)['rules'] as List)
        .cast<Map<String, dynamic>>();

List<Map<String, dynamic>> dnsServersOf(Map<String, dynamic> config) =>
    ((config['dns'] as Map<String, dynamic>)['servers'] as List)
        .cast<Map<String, dynamic>>();

void main() {
  group('自动模式', () {
    final config = build(const ProxyConfig());

    test('默认走 proxy', () {
      expect((config['route'] as Map<String, dynamic>)['final'], 'proxy');
    });

    test('包含国内域名与国内 IP 两条直连规则', () {
      final rules = rulesOf(config);
      expect(
        rules.any(
          (r) => (r['rule_set'] as List?)?.contains('geosite-cn') ?? false,
        ),
        isTrue,
      );
      expect(
        rules.any(
          (r) => (r['rule_set'] as List?)?.contains('geoip-cn') ?? false,
        ),
        isTrue,
      );
      expect(rules.any((r) => r['action'] == 'resolve'), isTrue);
    });

    test('私有地址始终直连', () {
      expect(
        rulesOf(
          config,
        ).any((r) => r['ip_is_private'] == true && r['outbound'] == 'direct'),
        isTrue,
      );
    });

    test('DNS 使用明文且不经过代理', () {
      final servers = dnsServersOf(config);
      final main = servers.firstWhere((s) => s['tag'] == 'dns-main');
      expect(main['type'], 'udp');
      expect(main.containsKey('detour'), isFalse);
    });

    test('缺少规则集时自动退化为更粗的分流，但不报错', () {
      final degraded = build(const ProxyConfig(), ruleSets: const []);
      final rules = rulesOf(degraded);
      expect(rules.any((r) => r.containsKey('rule_set')), isFalse);
      expect(
        (degraded['route'] as Map<String, dynamic>).containsKey('rule_set'),
        isFalse,
      );
    });
  });

  group('全局模式', () {
    final config = build(const ProxyConfig(routeMode: RouteMode.global));

    test('不包含任何分流规则', () {
      final rules = rulesOf(config);
      expect(rules.any((r) => r.containsKey('rule_set')), isFalse);
      // 只保留 sniff / hijack-dns / 私有地址直连
      expect(rules.length, 3);
      expect(rules.last['ip_is_private'], isTrue);
    });

    test('DNS 走加密 DoT 并经代理，避免全局模式下泄漏', () {
      final main = dnsServersOf(config)
          .firstWhere((s) => s['tag'] == 'dns-main');
      expect(main['type'], 'tls');
      expect(main['detour'], 'proxy');
    });
  });

  group('安全模式', () {
    final config = build(const ProxyConfig(safeDns: true));

    test('路由仍是自动分流', () {
      expect(
        rulesOf(
          config,
        ).any((r) => (r['rule_set'] as List?)?.contains('geosite-cn') ?? false),
        isTrue,
      );
    });

    test('DNS 加密', () {
      final main = dnsServersOf(config)
          .firstWhere((s) => s['tag'] == 'dns-main');
      expect(main['type'], 'tls');
      expect(main['detour'], 'proxy');
    });
  });

  group('bootstrap 解析器', () {
    test('始终是国内明文 DNS 且直连，否则解析不出节点域名', () {
      for (final proxy in [
        const ProxyConfig(),
        const ProxyConfig(routeMode: RouteMode.global),
        const ProxyConfig(safeDns: true),
        const ProxyConfig(dnsProvider: DnsProvider.cloudflare, safeDns: true),
      ]) {
        final bootstrap = dnsServersOf(build(proxy))
            .firstWhere((s) => s['tag'] == 'dns-bootstrap');
        expect(bootstrap['server'], kBootstrapDns);
        expect(bootstrap['type'], 'udp');
        expect(bootstrap.containsKey('detour'), isFalse);
      }
    });

    test('default_domain_resolver 指向 bootstrap', () {
      final route = build(const ProxyConfig())['route'] as Map<String, dynamic>;
      expect(route['default_domain_resolver'], {'server': 'dns-bootstrap'});
    });
  });

  group('outbound 生成', () {
    test('vless + ws + tls 的字段映射正确', () {
      final config = build(const ProxyConfig());
      final outbounds = (config['outbounds'] as List)
          .cast<Map<String, dynamic>>();
      final node = outbounds.firstWhere((o) => o['type'] == 'vless');

      expect(node['uuid'], '11111111-2222-3333-4444-555555555555');
      expect(node['server'], 'cos-cdn-a.example.win');
      expect(node['server_port'], 443);
      expect((node['tls'] as Map)['enabled'], isTrue);
      expect((node['tls'] as Map)['server_name'], 'mms.example.sbs');
      expect((node['tls'] as Map)['utls'], {
        'enabled': true,
        'fingerprint': 'qq',
      });
      expect((node['transport'] as Map)['type'], 'ws');
      expect((node['transport'] as Map)['path'], '/newlogin/login.do');
      expect((node['transport'] as Map)['headers'], {
        'Host': 'cdn.example.sbs',
      });
    });

    test('hysteria2 等协议强制启用 TLS', () {
      final node = ProxyNode(
        protocol: 'hysteria2',
        tag: 'hy2',
        server: 'h.example.com',
        port: 443,
        params: {'password': 'pw'},
      );
      final outbound = nodeToOutbound(node);
      expect((outbound['tls'] as Map)['enabled'], isTrue);
    });

    test('不支持的协议会被剔除，而不是生成非法配置', () {
      final nodes = [
        vlessNode(),
        ProxyNode(
          protocol: 'shadowsocksr',
          tag: 'ssr',
          server: 's.example.com',
          port: 443,
          params: {'method': 'aes-256-cfb', 'password': 'p'},
        ),
      ];
      final config = buildSingboxConfig(
        nodes: nodes,
        proxy: const ProxyConfig(),
        availableRuleSets: const [],
      );
      final outbounds = (config['outbounds'] as List)
          .cast<Map<String, dynamic>>();
      expect(outbounds.any((o) => o['type'] == 'shadowsocksr'), isFalse);
      expect(outbounds.any((o) => o['type'] == 'vless'), isTrue);
    });

    test('同名的两个节点会被自动去重命名', () {
      final config = buildSingboxConfig(
        nodes: [
          vlessNode(tag: '同名'),
          vlessNode(tag: '同名'),
        ],
        proxy: const ProxyConfig(),
        availableRuleSets: const [],
      );
      final tags = ((config['outbounds'] as List).cast<Map<String, dynamic>>())
          .where((o) => o['type'] == 'vless')
          .map((o) => o['tag'])
          .toList();
      expect(tags.toSet().length, 2);
    });

    test('没有可用节点时抛错', () {
      expect(
        () => buildSingboxConfig(
          nodes: const [],
          proxy: const ProxyConfig(),
          availableRuleSets: const [],
        ),
        throwsStateError,
      );
    });

    test('Selector 默认节点优先使用指定值', () {
      final config = buildSingboxConfig(
        nodes: [
          vlessNode(tag: 'A'),
          vlessNode(tag: 'B'),
        ],
        proxy: const ProxyConfig(),
        availableRuleSets: const [],
        defaultNodeTag: 'B',
      );
      final selector = (config['outbounds'] as List)
          .cast<Map<String, dynamic>>()
          .firstWhere((o) => o['type'] == 'selector');
      expect(selector['default'], 'B');
    });
  });
}
