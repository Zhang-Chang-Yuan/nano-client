// 代理节点模型与分享链接解析。
//
// 面板订阅返回的是 base64 编码的分享链接列表（已实测确认），
// 本文件负责把这些链接还原成结构化的 [ProxyNode]，并能转换成
// sing-box 的 outbound JSON。
//
// 支持协议：vless / vmess / trojan / shadowsocks / shadowsocksr /
//          hysteria / hysteria2 / tuic / anytls / socks / http

import 'dart:convert';

/// 一个代理节点。
class ProxyNode {
  ProxyNode({
    required this.protocol,
    required this.tag,
    required this.server,
    required this.port,
    Map<String, String>? params,
    this.raw = '',
  }) : params = params ?? <String, String>{};

  /// sing-box 的 outbound type，例如 `vless`。
  final String protocol;

  /// 节点显示名（订阅里的备注）。
  String tag;

  final String server;
  final int port;

  /// 分享链接里的查询参数，键统一小写。
  final Map<String, String> params;

  /// 原始分享链接，便于排查。
  final String raw;

  String get endpoint => '$server:$port';

  @override
  String toString() => 'ProxyNode($protocol, $tag, $endpoint)';
}

/// 分享链接解析失败。
class NodeParseException implements Exception {
  NodeParseException(this.message);

  final String message;

  @override
  String toString() => 'NodeParseException: $message';
}

/// 宽松的 base64 解码：自动补齐 padding，兼容 urlsafe 变体。
List<int> decodeBase64Loose(String input) {
  var s = input.trim().replaceAll('-', '+').replaceAll('_', '/');
  final remainder = s.length % 4;
  if (remainder > 0) s = s.padRight(s.length + (4 - remainder), '=');
  return base64.decode(s);
}

String decodeBase64LooseToString(String input) =>
    utf8.decode(decodeBase64Loose(input), allowMalformed: true);

/// 把一条分享链接解析成 [ProxyNode]；无法识别时返回 `null`。
ProxyNode? parseShareLink(String link) {
  final uri = link.trim();
  if (uri.isEmpty) return null;
  final lower = uri.toLowerCase();
  try {
    if (lower.startsWith('vmess://')) return _parseVmess(uri);
    if (lower.startsWith('vless://')) return _parseUrlStyle(uri, 'vless');
    if (lower.startsWith('trojan://')) return _parseUrlStyle(uri, 'trojan');
    if (lower.startsWith('anytls://')) return _parseUrlStyle(uri, 'anytls');
    if (lower.startsWith('tuic://')) return _parseUrlStyle(uri, 'tuic');
    if (lower.startsWith('hysteria2://')) {
      return _parseUrlStyle(uri, 'hysteria2');
    }
    if (lower.startsWith('hy2://')) {
      return _parseUrlStyle(
        uri.replaceFirst('hy2://', 'hysteria2://'),
        'hysteria2',
      );
    }
    if (lower.startsWith('hysteria://')) return _parseUrlStyle(uri, 'hysteria');
    if (lower.startsWith('ssr://')) return _parseSsr(uri);
    if (lower.startsWith('ss://')) return _parseShadowsocks(uri);
    if (lower.startsWith('socks://') || lower.startsWith('socks5://')) {
      return _parseUrlStyle(uri.replaceFirst('socks5://', 'socks://'), 'socks');
    }
    if (lower.startsWith('http://') || lower.startsWith('https://')) {
      return _parseUrlStyle(uri, 'http');
    }
  } on Object {
    return null;
  }
  return null;
}

/// 解析整份订阅内容。
///
/// 支持三种形态：
///   1. base64 编码的分享链接列表（本面板的默认形态）
///   2. 明文分享链接列表
///   3. 直接下发的 sing-box JSON 配置（返回的 `config` 非空）
///
/// 返回值中 `nodes` 为解析出的节点，`config` 为服务端配置（若存在）。
({List<ProxyNode> nodes, Map<String, dynamic>? config}) parseSubscription(
  String content,
) {
  final raw = content.trim();
  if (raw.isEmpty) return (nodes: <ProxyNode>[], config: null);

  // 情况 3：服务端直接给了 sing-box 配置
  if (raw.startsWith('{')) {
    try {
      final decoded = jsonDecode(raw);
      if (decoded is Map<String, dynamic> &&
          (decoded.containsKey('outbounds') ||
              decoded.containsKey('inbounds'))) {
        return (nodes: <ProxyNode>[], config: decoded);
      }
    } on FormatException {
      // 不是合法 JSON，继续按链接列表处理
    }
  }

  // 情况 1：base64
  var body = raw;
  if (!raw.contains('://')) {
    try {
      body = decodeBase64LooseToString(raw);
    } on Object {
      body = raw;
    }
  }

  final nodes = <ProxyNode>[];
  for (final line in body.split(RegExp(r'[\r\n]+'))) {
    final node = parseShareLink(line);
    if (node != null) nodes.add(node);
  }
  return (nodes: nodes, config: null);
}

/// 宽松的百分号解码。
///
/// 节点备注、密码等字段经常包含**未编码**的空格或 `%`，直接调用
/// `Uri.decodeComponent` 会抛 `ArgumentError`，进而让整条链接被丢弃，
/// 因此这里解码失败时原样返回。
String _decodeComponent(String? value) {
  if (value == null || value.isEmpty) return '';
  try {
    return Uri.decodeComponent(value);
  } on ArgumentError {
    return value;
  } on FormatException {
    return value;
  }
}

String _fragment(String? fragment, String fallback) {
  if (fragment == null || fragment.isEmpty) return fallback;
  final decoded = _decodeComponent(fragment);
  return decoded.isEmpty ? fallback : decoded;
}

ProxyNode _parseVmess(String uri) {
  final payload = decodeBase64LooseToString(uri.substring('vmess://'.length));
  final decoded = jsonDecode(payload);
  if (decoded is! Map) {
    throw NodeParseException('vmess 载荷不是 JSON 对象');
  }
  final json = decoded.cast<String, dynamic>();
  final server = '${json['add'] ?? ''}';
  final port = int.tryParse('${json['port'] ?? 443}') ?? 443;
  final network = '${json['net'] ?? 'tcp'}'.toLowerCase();
  final host = '${json['host'] ?? ''}';
  return ProxyNode(
    protocol: 'vmess',
    tag: _fragment('${json['ps'] ?? ''}', '$server:$port'),
    server: server,
    port: port,
    params: {
      'uuid': '${json['id'] ?? ''}',
      'aid': '${json['aid'] ?? 0}',
      'security': '${json['scy'] ?? json['security'] ?? 'auto'}',
      'type': network,
      'host': host,
      'path': '${json['path'] ?? ''}',
      'tls': '${json['tls'] ?? ''}',
      'sni': json['sni'] != null && '${json['sni']}'.isNotEmpty
          ? '${json['sni']}'
          : host,
      'alpn': '${json['alpn'] ?? ''}',
      'fp': '${json['fp'] ?? ''}',
    },
    raw: uri,
  );
}

ProxyNode _parseUrlStyle(String uri, String protocol) {
  // 这类链接是标准 URI 形式（user@host:port?query#fragment），
  // 直接交给 Uri 解析，避免手写状态机出错。
  final parsed = Uri.parse(uri);
  if (parsed.host.isEmpty) {
    throw NodeParseException('缺少主机名: $uri');
  }

  final userInfo = _decodeComponent(parsed.userInfo);
  final host = parsed.host;
  final port = parsed.hasPort ? parsed.port : 443;

  final params = <String, String>{};
  parsed.queryParameters.forEach((key, value) {
    params[key.toLowerCase()] = value;
  });

  switch (protocol) {
    case 'vless':
      params['uuid'] = userInfo;
    case 'trojan':
    case 'anytls':
      params['password'] = userInfo;
    case 'tuic':
      final idx = userInfo.indexOf(':');
      params['uuid'] = idx >= 0 ? userInfo.substring(0, idx) : userInfo;
      params['password'] = idx >= 0 ? userInfo.substring(idx + 1) : '';
    case 'hysteria2':
      final idx = userInfo.indexOf(':');
      if (idx >= 0) {
        params['username'] = userInfo.substring(0, idx);
        params['password'] = userInfo.substring(idx + 1);
      } else {
        params['password'] = userInfo;
      }
    case 'hysteria':
      params['auth'] = userInfo;
  }

  // 统一别名，便于 sing-box 转换时只认一种键
  final obfsPassword = params['obfs-password'];
  if (obfsPassword != null && obfsPassword.isNotEmpty) {
    params['obfs_password'] = obfsPassword;
  }
  final allowInsecure = params['allowinsecure'];
  if (allowInsecure != null && !params.containsKey('insecure')) {
    params['insecure'] = allowInsecure;
  }

  final tag = _fragment(parsed.fragment, params['remarks'] ?? '$host:$port');
  return ProxyNode(
    protocol: protocol,
    tag: tag,
    server: host,
    port: port,
    params: params,
    raw: uri,
  );
}

ProxyNode _parseShadowsocks(String uri) {
  var body = uri.substring('ss://'.length);
  String? fragment;
  final hashIndex = body.indexOf('#');
  if (hashIndex >= 0) {
    fragment = body.substring(hashIndex + 1);
    body = body.substring(0, hashIndex);
  }

  final query = <String, String>{};
  final queryIndex = body.indexOf('?');
  if (queryIndex >= 0) {
    for (final pair in body.substring(queryIndex + 1).split('&')) {
      final eq = pair.indexOf('=');
      if (eq <= 0) continue;
      query[pair.substring(0, eq).toLowerCase()] = Uri.decodeComponent(
        pair.substring(eq + 1),
      );
    }
    body = body.substring(0, queryIndex);
  }

  String method = '';
  String password = '';
  String host;
  int port;

  final atIndex = body.lastIndexOf('@');
  if (atIndex >= 0) {
    var userInfo = body.substring(0, atIndex);
    final hostPort = body.substring(atIndex + 1);
    if (!userInfo.contains(':')) {
      userInfo = decodeBase64LooseToString(userInfo);
    }
    final colon = userInfo.indexOf(':');
    method = colon >= 0 ? userInfo.substring(0, colon) : userInfo;
    password = colon >= 0 ? userInfo.substring(colon + 1) : '';
    final parsed = _splitHostPort(hostPort, 8388);
    host = parsed.$1;
    port = parsed.$2;
  } else {
    final decoded = decodeBase64LooseToString(body);
    final at = decoded.lastIndexOf('@');
    if (at < 0) throw NodeParseException('无法解析 ss:// 链接');
    final userInfo = decoded.substring(0, at);
    final colon = userInfo.indexOf(':');
    method = colon >= 0 ? userInfo.substring(0, colon) : userInfo;
    password = colon >= 0 ? userInfo.substring(colon + 1) : '';
    final parsed = _splitHostPort(decoded.substring(at + 1), 8388);
    host = parsed.$1;
    port = parsed.$2;
  }

  final params = Map<String, String>.from(query);
  params['method'] = method;
  params['password'] = password;
  return ProxyNode(
    protocol: 'shadowsocks',
    tag: _fragment(fragment, '$host:$port'),
    server: host,
    port: port,
    params: params,
    raw: uri,
  );
}

ProxyNode _parseSsr(String uri) {
  final decoded = decodeBase64LooseToString(uri.substring('ssr://'.length));
  final parts = decoded.split('/?');
  final head = parts.first.split(':');
  if (head.length < 6) throw NodeParseException('无法解析 ssr:// 链接');

  final query = <String, String>{};
  if (parts.length > 1) {
    for (final pair in parts[1].split('&')) {
      final eq = pair.indexOf('=');
      if (eq <= 0) continue;
      query[pair.substring(0, eq).toLowerCase()] = pair.substring(eq + 1);
    }
  }

  String decodeParam(String key) {
    final value = query[key];
    if (value == null || value.isEmpty) return '';
    try {
      return decodeBase64LooseToString(value);
    } on Object {
      return '';
    }
  }

  final host = head[0];
  final port = int.tryParse(head[1]) ?? 443;
  final params = <String, String>{
    'method': head[3],
    'password': decodeBase64LooseToString(head[5]),
    'protocol': head[2],
    'obfs': head[4],
  };
  final obfsParam = decodeParam('obfsparam');
  if (obfsParam.isNotEmpty) params['obfs_param'] = obfsParam;
  final protocolParam = decodeParam('protoparam');
  if (protocolParam.isNotEmpty) params['protocol_param'] = protocolParam;

  final remarks = decodeParam('remarks');
  return ProxyNode(
    protocol: 'shadowsocksr',
    tag: remarks.isEmpty ? '$host:$port' : remarks,
    server: host,
    port: port,
    params: params,
    raw: uri,
  );
}

(String, int) _splitHostPort(String hostPort, int defaultPort) {
  if (hostPort.startsWith('[')) {
    final end = hostPort.indexOf(']');
    final host = hostPort.substring(1, end);
    final portPart = hostPort.substring(end + 1).replaceFirst(':', '');
    return (host, int.tryParse(portPart) ?? defaultPort);
  }
  final colon = hostPort.lastIndexOf(':');
  if (colon < 0) return (hostPort, defaultPort);
  return (
    hostPort.substring(0, colon),
    int.tryParse(hostPort.substring(colon + 1)) ?? defaultPort,
  );
}
