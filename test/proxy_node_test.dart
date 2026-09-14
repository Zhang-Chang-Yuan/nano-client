import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:nano_client/core/subscription/proxy_node.dart';

void main() {
  group('parseShareLink', () {
    test('解析 vless 链接（含 ws / tls / reality 参数）', () {
      const link =
          'vless://11111111-2222-3333-4444-555555555555'
          '@cos-cdn-a.example.win:443'
          '?mode=multi&security=tls&encryption=none&type=ws'
          '&sni=mms.example.sbs&fp=qq&path=%2Fnewlogin%2Flogin.do&host=cdn.example.sbs'
          '#%F0%9F%87%AF%F0%9F%87%B5%E6%97%A5%E6%9C%AC-X';

      final node = parseShareLink(link)!;

      expect(node.protocol, 'vless');
      expect(node.server, 'cos-cdn-a.example.win');
      expect(node.port, 443);
      expect(node.params['uuid'], '11111111-2222-3333-4444-555555555555');
      expect(node.params['type'], 'ws');
      expect(node.params['security'], 'tls');
      expect(node.params['sni'], 'mms.example.sbs');
      expect(node.params['fp'], 'qq');
      // 百分号编码的 path 与备注都要解码
      expect(node.params['path'], '/newlogin/login.do');
      expect(node.tag, '🇯🇵日本-X');
    });

    test('解析 vmess 链接（base64 JSON 载荷）', () {
      final payload = base64Encode(
        utf8.encode(
          jsonEncode({
            'v': '2',
            'ps': 'VMess 节点',
            'add': '1.2.3.4',
            'port': '443',
            'id': 'aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee',
            'aid': '0',
            'scy': 'auto',
            'net': 'ws',
            'host': 'a.example.com',
            'path': '/ws',
            'tls': 'tls',
            'sni': 'a.example.com',
          }),
        ),
      );

      final node = parseShareLink('vmess://$payload')!;

      expect(node.protocol, 'vmess');
      expect(node.server, '1.2.3.4');
      expect(node.port, 443);
      expect(node.tag, 'VMess 节点');
      expect(node.params['uuid'], 'aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee');
      expect(node.params['type'], 'ws');
    });

    test('解析 trojan / hysteria2 / tuic / anytls', () {
      expect(
        parseShareLink('trojan://pass%40word@t.example.com:8443?sni=x.com#T')!
            .params['password'],
        'pass@word',
      );
      expect(
        parseShareLink('hysteria2://pw@hy.example.com:443?sni=x.com#H')!
            .protocol,
        'hysteria2',
      );
      expect(
        parseShareLink('hy2://pw@hy.example.com:443#H')!.protocol,
        'hysteria2',
      );
      final tuic = parseShareLink('tuic://uuid-x:pw-y@t.example.com:443#T')!;
      expect(tuic.params['uuid'], 'uuid-x');
      expect(tuic.params['password'], 'pw-y');
      expect(
        parseShareLink('anytls://pw@a.example.com:8443#A')!.protocol,
        'anytls',
      );
    });

    test('解析 shadowsocks 的两种写法', () {
      final sip002 = parseShareLink(
        'ss://${base64Encode(utf8.encode('aes-256-gcm:pwd'))}@1.2.3.4:8388#SS1',
      )!;
      expect(sip002.protocol, 'shadowsocks');
      expect(sip002.params['method'], 'aes-256-gcm');
      expect(sip002.params['password'], 'pwd');

      final legacy = parseShareLink(
        'ss://${base64Encode(utf8.encode('aes-128-gcm:pw@5.6.7.8:8389'))}#SS2',
      )!;
      expect(legacy.server, '5.6.7.8');
      expect(legacy.port, 8389);
      expect(legacy.params['method'], 'aes-128-gcm');
    });

    test('统一 insecure 与 obfs-password 的别名', () {
      final node = parseShareLink(
        'hysteria2://pw@h.example.com:443?obfs=salamander'
        '&obfs-password=obf&allowInsecure=1#H',
      )!;
      expect(node.params['obfs_password'], 'obf');
      expect(node.params['insecure'], '1');
    });

    test('无法识别或畸形的链接返回 null 而不是抛异常', () {
      expect(parseShareLink(''), isNull);
      expect(parseShareLink('ftp://example.com'), isNull);
      expect(parseShareLink('vmess://@@@not-base64@@@'), isNull);
      expect(parseShareLink('vless://'), isNull);
    });
  });

  group('parseSubscription', () {
    test('解析 base64 编码的链接列表', () {
      final encoded = base64Encode(
        utf8.encode(
          'vless://uuid@a.example.com:443#A\ntrojan://pw@b.example.com:443#B',
        ),
      );

      final result = parseSubscription(encoded);

      expect(result.config, isNull);
      expect(result.nodes.length, 2);
      expect(result.nodes[0].protocol, 'vless');
      expect(result.nodes[1].protocol, 'trojan');
      expect(result.nodes[0].tag, 'A');
      expect(result.nodes[1].tag, 'B');
    });

    test('解析明文链接列表', () {
      final result = parseSubscription(
        'vless://uuid@a.example.com:443#A\n\n  \ntrojan://pw@b.example.com:443#B',
      );
      expect(result.nodes.length, 2);
    });

    test('服务端直接下发 sing-box 配置时原样透出', () {
      final config = jsonEncode({
        'outbounds': [
          {'type': 'direct', 'tag': 'direct'},
        ],
      });
      final result = parseSubscription(config);
      expect(result.config, isNotNull);
      expect(result.nodes, isEmpty);
    });

    test('空内容返回空结果', () {
      final result = parseSubscription('   ');
      expect(result.nodes, isEmpty);
      expect(result.config, isNull);
    });

    test('会跳过无法解析的行而不是整体失败', () {
      final encoded = base64Encode(
        utf8.encode('vless://uuid@a.example.com:443#A\ngarbage-line\nftp://x'),
      );
      final result = parseSubscription(encoded);
      expect(result.nodes.length, 1);
    });
  });
}
