import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:nano_client/core/config/app_config.dart';
import 'package:nano_client/core/proxy/singbox_config.dart';
import 'package:nano_client/core/proxy/tun_privilege.dart';
import 'package:nano_client/core/subscription/proxy_node.dart';

ProxyNode _node() => ProxyNode(
  protocol: 'vless',
  tag: '测试节点',
  server: 'example.com',
  port: 443,
  params: const {'uuid': 'u', 'security': 'tls'},
);

/// 生成一份开启了 TUN 的配置，取出 tun inbound。
Map<String, dynamic> _tunInbound() {
  final config = buildSingboxConfig(
    nodes: [_node()],
    proxy: const ProxyConfig(enableTun: true),
    availableRuleSets: const [],
  );
  return (config['inbounds'] as List).cast<Map<String, dynamic>>().firstWhere(
    (i) => i['type'] == 'tun',
  );
}

void main() {
  group('TUN 权限', () {
    test('需要 net_admin，否则建不了网卡', () {
      expect(TunPrivilege.capabilities, contains('cap_net_admin'));
    });

    test('手工命令包含 setcap、全部 capability 与路径', () {
      final cmd = TunPrivilege.manualCommand('/tmp/sing-box');
      expect(cmd, contains('setcap'));
      expect(cmd, contains('cap_net_admin'));
      expect(cmd, contains('cap_net_raw'));
      expect(cmd, contains('/tmp/sing-box'));
      expect(cmd, startsWith('sudo'));
    });

    test('普通文件（无 capability）判为需要授权，并给出可手工执行的命令', () async {
      final dir = Directory.systemTemp.createTempSync('tun');
      addTearDown(() => dir.deleteSync(recursive: true));
      final binary = File('${dir.path}/sing-box')
        ..writeAsStringSync('#!/bin/sh\n');

      const privilege = TunPrivilege();
      final result = await privilege.check(binary.path);

      if (Platform.isLinux) {
        expect(result.status, TunPrivilegeStatus.needsGrant);
        expect(result.isReady, isFalse);
        expect(result.command, contains(binary.path));
      } else {
        expect(result.status, TunPrivilegeStatus.unsupported);
      }
    });

    test('不存在的路径不会被当成已授权', () async {
      const privilege = TunPrivilege();
      final result = await privilege.check('/nonexistent/sing-box');
      expect(result.isReady, isFalse);
    });

    test('残留检测返回布尔值且不抛异常', () async {
      const privilege = TunPrivilege();
      expect(await privilege.hasLeftovers(), isA<bool>());
    });
  });

  group('TUN 配置', () {
    test('网卡名固定，便于识别与清理残留', () {
      expect(_tunInbound()['interface_name'], kTunInterfaceName);
    });

    test('自动设置路由，并带上接管所需字段', () {
      final tun = _tunInbound();
      expect(tun['auto_route'], isTrue);
      expect(tun['strict_route'], isTrue);
      expect(tun['stack'], 'mixed');
      expect(tun['address'], isA<List<dynamic>>());
    });

    test('地址落在约定的 TUN 子网内（清理残留时按它匹配）', () {
      // 配置里写的是主机地址（172.19.0.1/30），常量描述的是网段（172.19.0.0/30）
      final network = kTunCidr.split('/').first.split('.').take(3).join('.');
      final addresses = (_tunInbound()['address'] as List).cast<String>();
      expect(addresses.first, startsWith('$network.'));
    });

    test('未开启 TUN 时不生成 tun inbound', () {
      final config = buildSingboxConfig(
        nodes: [_node()],
        proxy: const ProxyConfig(),
        availableRuleSets: const [],
      );
      final types = (config['inbounds'] as List)
          .cast<Map<String, dynamic>>()
          .map((i) => i['type']);
      expect(types, isNot(contains('tun')));
    });
  });
}
