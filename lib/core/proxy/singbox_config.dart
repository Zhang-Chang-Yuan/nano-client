// sing-box 配置生成。
//
// 与 Python 版 `script/nanolib.py` 的行为保持一致，并适配 sing-box >= 1.14：
//   * 旧式 DNS 服务器写法已移除，必须使用 `type` + `server`
//   * inbound 的 `sniff` 等字段已移除，改用路由 action
//   * `geoip` / `geosite` 路由项已移除，必须改用 `.srs` 格式的 `rule_set`
//   * 必须显式提供 `route.default_domain_resolver`

import 'dart:convert';

import '../config/app_config.dart';
import '../subscription/proxy_node.dart';

/// sing-box 1.14 起已移除的出站类型。
const Set<String> kUnsupportedOutboundTypes = {'shadowsocksr'};

/// bootstrap 解析器固定使用国内明文 DNS。
///
/// 它只用于解析「代理节点自身的域名」，必须直连且稳定；若跟着 provider 走
/// （例如明文 UDP 到 8.8.8.8），在国内会被污染，导致根本连不上节点。
/// 它只暴露节点域名，不暴露用户访问的域名。
const String kBootstrapDns = '223.5.5.5';

/// 自动分流所用规则集的文件名（需放在内核工作目录下）。
const List<String> kCnRuleSets = ['geosite-cn', 'geoip-cn'];

/// 把节点列表转成 sing-box 配置。
///
/// [availableRuleSets] 为本地实际存在的规则集 tag；为空时 `auto` 模式
/// 会退化为接近全局代理。
Map<String, dynamic> buildSingboxConfig({
  required List<ProxyNode> nodes,
  required ProxyConfig proxy,
  List<String> availableRuleSets = const [],
  String listen = '127.0.0.1',
  int mixedPort = 7890,
  int clashPort = 9090,
  String clashSecret = '',
  String? cachePath,
  String? defaultNodeTag,
}) {
  final usable = nodes
      .where((n) => !kUnsupportedOutboundTypes.contains(n.protocol))
      .toList();
  if (usable.isEmpty) {
    throw StateError('没有可用的节点');
  }

  final usedTags = <String, int>{};
  final outbounds = <Map<String, dynamic>>[];
  final nodeTags = <String>[];

  for (final node in usable) {
    final tag = _uniqueTag(node.tag, usedTags);
    final outbound = nodeToOutbound(node);
    outbound['tag'] = tag;
    outbounds.add(outbound);
    nodeTags.add(tag);
  }

  final defaultTag =
      (defaultNodeTag != null && nodeTags.contains(defaultNodeTag))
      ? defaultNodeTag
      : nodeTags.first;

  final selector = <String, dynamic>{
    'type': 'selector',
    'tag': 'proxy',
    'outbounds': [...nodeTags, 'direct'],
    'default': defaultTag,
    'interrupt_exist_connections': false,
  };

  // ⚠️ 这些嵌套 map 必须写成显式类型的字面量。
  //
  // 如果写成无上下文的 `{'clash_api': {...}}`，Dart 会把它推断成
  // `Map<String, Map<String, String>>` 这种**窄类型**。后面再
  // `as Map<String, dynamic>` 虽然编译能过、转型也能成功（Dart 泛型是协变的），
  // 但底层对象仍是那个窄类型，往里写别的形状的值就会在运行时抛：
  //   type '_Map<String, Object>' is not a subtype of type 'Map<String, String>'
  // 这个坑在 release 构建里才会暴露，静态分析看不出来。
  final experimental = <String, dynamic>{
    'clash_api': <String, dynamic>{
      'external_controller': '$listen:$clashPort',
      'secret': clashSecret,
    },
  };
  if (cachePath != null) {
    experimental['cache_file'] = <String, dynamic>{
      'enabled': true,
      'path': cachePath,
    };
  }

  final inbounds = <Map<String, dynamic>>[
    <String, dynamic>{
      'type': 'mixed',
      'tag': 'mixed-in',
      'listen': listen,
      'listen_port': mixedPort,
    },
  ];
  if (proxy.enableTun) {
    inbounds.add(<String, dynamic>{
      'type': 'tun',
      'tag': 'tun-in',
      'address': <String>['172.19.0.1/30', 'fdfe:dcba:9876::1/126'],
      'mtu': 9000,
      'auto_route': true,
      'strict_route': true,
      'stack': 'mixed',
    });
  }

  final config = <String, dynamic>{
    'log': <String, dynamic>{'level': proxy.logLevel, 'timestamp': true},
    'dns': buildDnsSection(proxy),
    'inbounds': inbounds,
    'outbounds': <Map<String, dynamic>>[
      selector,
      ...outbounds,
      <String, dynamic>{'type': 'direct', 'tag': 'direct'},
    ],
    'route': buildRouteSection(proxy, availableRuleSets),
    'experimental': experimental,
  };

  return config;
}

/// 构造 `dns` 段。
Map<String, dynamic> buildDnsSection(ProxyConfig proxy) {
  // 私密 DNS：DoT（TCP + TLS）经代理隧道，本地 ISP 看不到内容也无从劫持。
  // 全局模式同样使用加密 DNS，避免「全局」下仍发生 DNS 泄漏。
  final secure = proxy.safeDns || proxy.routeMode == RouteMode.global;
  final type = secure ? 'tls' : 'udp';

  final servers = <Map<String, dynamic>>[
    {'type': 'udp', 'tag': 'dns-bootstrap', 'server': kBootstrapDns},
  ];
  for (final entry in {
    'dns-main': proxy.dnsProvider.primary,
    'dns-alt': proxy.dnsProvider.secondary,
  }.entries) {
    servers.add({
      'type': type,
      'tag': entry.key,
      'server': entry.value,
      if (secure) 'detour': 'proxy',
    });
  }

  return {'servers': servers, 'strategy': 'prefer_ipv4', 'final': 'dns-main'};
}

/// 构造 `route` 段。
Map<String, dynamic> buildRouteSection(
  ProxyConfig proxy,
  List<String> availableRuleSets,
) {
  final rules = <Map<String, dynamic>>[
    {'action': 'sniff'},
    {'protocol': 'dns', 'action': 'hijack-dns'},
    // 局域网/私有地址始终直连：走代理既无意义又会打断内网访问
    {'ip_is_private': true, 'action': 'route', 'outbound': 'direct'},
  ];

  final ruleSets = <Map<String, dynamic>>[];
  if (proxy.routeMode == RouteMode.auto) {
    final usable = kCnRuleSets.where(availableRuleSets.contains).toList();
    for (final tag in usable) {
      ruleSets.add({
        'type': 'local',
        'tag': tag,
        'format': 'binary',
        'path': 'rule-set/$tag.srs',
      });
    }
    // 先按域名判定国内站点，省掉一次 IP 解析
    if (usable.contains('geosite-cn')) {
      rules.add({
        'rule_set': ['geosite-cn'],
        'action': 'route',
        'outbound': 'direct',
      });
    }
    // 其余目标解析出 IP 后再按国内 IP 段判定
    if (usable.isNotEmpty) {
      rules.add({'action': 'resolve'});
    }
    if (usable.contains('geoip-cn')) {
      rules.add({
        'rule_set': ['geoip-cn'],
        'action': 'route',
        'outbound': 'direct',
      });
    }
  }

  return {
    'rules': rules,
    if (ruleSets.isNotEmpty) 'rule_set': ruleSets,
    'final': 'proxy',
    'auto_detect_interface': true,
    // bootstrap 解析器负责解析节点域名，必须直连
    'default_domain_resolver': {'server': 'dns-bootstrap'},
  };
}

/// 单个节点转 sing-box outbound。
Map<String, dynamic> nodeToOutbound(ProxyNode node) {
  final p = node.params;
  final outbound = <String, dynamic>{
    'type': node.protocol,
    'tag': node.tag,
    'server': node.server,
    'server_port': node.port,
  };

  switch (node.protocol) {
    case 'vmess':
      outbound['uuid'] = p['uuid'] ?? '';
      outbound['security'] = p['security'] ?? 'auto';
      final alterId = int.tryParse(p['aid'] ?? '') ?? 0;
      if (alterId > 0) outbound['alter_id'] = alterId;
    case 'vless':
      outbound['uuid'] = p['uuid'] ?? '';
      if ((p['flow'] ?? '').isNotEmpty) outbound['flow'] = p['flow'];
    case 'trojan':
      outbound['password'] = p['password'] ?? '';
    case 'shadowsocks':
      outbound['method'] = p['method'] ?? '';
      outbound['password'] = p['password'] ?? '';
      if ((p['plugin'] ?? '').isNotEmpty) {
        outbound['plugin'] = p['plugin'];
        if ((p['plugin_opts'] ?? '').isNotEmpty) {
          outbound['plugin_opts'] = p['plugin_opts'];
        }
      }
    case 'shadowsocksr':
      outbound['method'] = p['method'] ?? '';
      outbound['password'] = p['password'] ?? '';
      outbound['protocol'] = p['protocol'] ?? 'origin';
      outbound['obfs'] = p['obfs'] ?? 'plain';
    case 'hysteria2':
      outbound['password'] = p['password'] ?? '';
      final obfs = p['obfs'] ?? '';
      if (obfs.isNotEmpty) {
        outbound['obfs'] = {'type': obfs, 'password': p['obfs_password'] ?? ''};
      }
      final up = int.tryParse(p['up'] ?? p['upmbps'] ?? '');
      final down = int.tryParse(p['down'] ?? p['downmbps'] ?? '');
      if (up != null) outbound['up_mbps'] = up;
      if (down != null) outbound['down_mbps'] = down;
    case 'hysteria':
      outbound['auth_str'] = p['auth'] ?? '';
      final up = int.tryParse(p['upmbps'] ?? '');
      final down = int.tryParse(p['downmbps'] ?? '');
      if (up != null) outbound['up_mbps'] = up;
      if (down != null) outbound['down_mbps'] = down;
    case 'tuic':
      outbound['uuid'] = p['uuid'] ?? '';
      outbound['password'] = p['password'] ?? '';
      if ((p['congestion_control'] ?? '').isNotEmpty) {
        outbound['congestion_control'] = p['congestion_control'];
      }
      if ((p['udp_relay_mode'] ?? '').isNotEmpty) {
        outbound['udp_relay_mode'] = p['udp_relay_mode'];
      }
    case 'anytls':
      outbound['password'] = p['password'] ?? '';
    case 'socks':
    case 'http':
      if ((p['username'] ?? '').isNotEmpty) {
        outbound['username'] = p['username'];
        outbound['password'] = p['password'] ?? '';
      }
  }

  final tls = _buildTls(node);
  if (tls != null) outbound['tls'] = tls;
  final transport = _buildTransport(node);
  if (transport != null) outbound['transport'] = transport;
  return outbound;
}

/// 这些协议在 sing-box 中强制要求 TLS。
const Set<String> _forceTlsProtocols = {
  'hysteria2',
  'hysteria',
  'tuic',
  'anytls',
};

Map<String, dynamic>? _buildTls(ProxyNode node) {
  final p = node.params;
  final security = (p['security'] ?? '').toLowerCase();
  final enabled =
      security == 'tls' ||
      security == 'reality' ||
      security == 'xtls' ||
      _isTruthy(p['tls']) ||
      _forceTlsProtocols.contains(node.protocol);
  if (!enabled) return null;

  final tls = <String, dynamic>{'enabled': true};
  final sni = p['sni'] ?? p['peer'] ?? p['host'] ?? '';
  if (sni.isNotEmpty) tls['server_name'] = sni;

  if (_isTruthy(p['insecure'] ?? p['allowinsecure'])) {
    tls['insecure'] = true;
  }

  final alpn = p['alpn'] ?? '';
  if (alpn.isNotEmpty) {
    tls['alpn'] = alpn.split(',').where((e) => e.isNotEmpty).toList();
  }

  final fingerprint = p['fp'] ?? p['fingerprint'] ?? '';
  if (fingerprint.isNotEmpty) {
    tls['utls'] = {'enabled': true, 'fingerprint': fingerprint};
  }

  if (security == 'reality') {
    final publicKey = p['pbk'] ?? p['public_key'] ?? p['public-key'] ?? '';
    if (publicKey.isNotEmpty) {
      tls['reality'] = {
        'enabled': true,
        'public_key': publicKey,
        if ((p['sid'] ?? p['short_id'] ?? p['short-id'] ?? '').isNotEmpty)
          'short_id': p['sid'] ?? p['short_id'] ?? p['short-id'],
      };
    }
  }
  return tls;
}

Map<String, dynamic>? _buildTransport(ProxyNode node) {
  final p = node.params;
  final network = (p['type'] ?? p['net'] ?? 'tcp').toLowerCase();
  final host = p['host'] ?? '';
  final path = p['path'] ?? '';

  switch (network) {
    case 'ws':
      return {
        'type': 'ws',
        'path': path.isEmpty ? '/' : path,
        if (host.isNotEmpty) 'headers': {'Host': host},
      };
    case 'grpc':
      final serviceName =
          (p['servicename'] ?? p['service_name'] ?? p['path'] ?? '')
              .replaceFirst('/', '');
      return {
        'type': 'grpc',
        if (serviceName.isNotEmpty) 'service_name': serviceName,
      };
    case 'http':
    case 'h2':
      return {
        'type': 'http',
        if (host.isNotEmpty)
          'host': host.split(',').where((e) => e.isNotEmpty).toList(),
        if (path.isNotEmpty) 'path': path,
      };
    case 'httpupgrade':
      return {
        'type': 'httpupgrade',
        if (host.isNotEmpty) 'host': host,
        if (path.isNotEmpty) 'path': path,
      };
    case 'quic':
      return {'type': 'quic'};
    default:
      return null;
  }
}

bool _isTruthy(String? value) {
  if (value == null) return false;
  final v = value.trim().toLowerCase();
  return v == '1' || v == 'true' || v == 'yes' || v == 'on';
}

String _uniqueTag(String tag, Map<String, int> used) {
  final base = tag.isEmpty ? 'node' : tag;
  final count = used[base];
  if (count == null) {
    used[base] = 1;
    return base;
  }
  used[base] = count + 1;
  return '$base #$count';
}

/// 序列化为带缩进的 JSON，便于落盘排查。
String encodeConfig(Map<String, dynamic> config) =>
    const JsonEncoder.withIndent('  ').convert(config);
