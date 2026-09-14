import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:nano_client/core/config/app_config.dart';
import 'package:nano_client/core/proxy/singbox_config.dart';
import 'package:nano_client/core/subscription/proxy_node.dart';

/// 找到一个可用的 sing-box 可执行文件；找不到就跳过本文件的测试。
///
/// 仓库里不含内核（见 .gitignore），本地执行过
/// `dart run tool/fetch_core.dart` 或从 CI 产物里取过才会有。
///
/// 必须返回**绝对路径**：校验时会把工作目录切到临时目录，
/// 相对路径会解析失败。
String? findSingBox() {
  final name = Platform.isWindows ? 'sing-box.exe' : 'sing-box';
  final cwd = Directory.current.absolute.path;
  for (final path in ['$cwd/assets/bin/$name', '$cwd/tool/sing-box']) {
    if (File(path).existsSync()) return path;
  }
  return null;
}

/// 用真实节点形状构造配置。
Map<String, dynamic> realWorldConfig({
  required ProxyConfig proxy,
  String? cachePath,
}) => buildSingboxConfig(
  nodes: [
    // 与线上订阅里的链接形状一致（vless + ws + tls）
    ProxyNode(
      protocol: 'vless',
      tag: '🇯🇵日本-X',
      server: 'cos-cdn-a.example.win',
      port: 443,
      params: {
        'uuid': '11111111-2222-3333-4444-555555555555',
        'mode': 'multi',
        'security': 'tls',
        'encryption': 'none',
        'type': 'ws',
        'sni': 'mms.example.sbs',
        'fp': 'qq',
        'path': '/newlogin/login.do',
        'host': 'cdn.example.sbs',
      },
    ),
    ProxyNode(
      protocol: 'trojan',
      tag: '🇸🇬狮城-E',
      server: 'sg.example.com',
      port: 8443,
      params: {'password': 'pw', 'sni': 'sg.example.com', 'type': 'grpc'},
    ),
  ],
  proxy: proxy,
  availableRuleSets: const ['geosite-cn', 'geoip-cn'],
  cachePath: cachePath,
  defaultNodeTag: '🇸🇬狮城-E',
);

void main() {
  final singbox = findSingBox();

  /// 把配置落盘并交给官方内核校验。
  void checkWithCore(String label, Map<String, dynamic> config) {
    final dir = Directory.systemTemp.createTempSync('nano_cfg');
    addTearDown(() {
      if (dir.existsSync()) dir.deleteSync(recursive: true);
    });

    final file = File('${dir.path}/config.json');
    file.writeAsStringSync(encodeConfig(config));

    // 规则集用相对路径引用，这里软链过去，确保 auto 模式的分流能真正生效
    final ruleSetDir = Directory('${dir.path}/rule-set')..createSync();
    for (final tag in const ['geosite-cn', 'geoip-cn']) {
      final src = File('assets/rule-set/$tag.srs');
      if (src.existsSync()) {
        src.copySync('${ruleSetDir.path}/$tag.srs');
      }
    }

    final result = Process.runSync(singbox!, [
      'check',
      '-c',
      file.path,
    ], workingDirectory: dir.path);

    expect(
      result.exitCode,
      0,
      reason:
          '$label 生成的配置未通过 sing-box check：\n'
          '${result.stdout}\n${result.stderr}',
    );
  }

  group('生成的配置能被官方内核接受', () {
    test('自动模式 + cache_file（线上崩溃的那条路径）', () {
      checkWithCore(
        'auto',
        realWorldConfig(
          proxy: const ProxyConfig(),
          cachePath: '/tmp/nano-cache.db',
        ),
      );
    });

    test('全局模式（私密 DNS）', () {
      checkWithCore(
        'global',
        realWorldConfig(
          proxy: const ProxyConfig(routeMode: RouteMode.global),
          cachePath: '/tmp/nano-cache.db',
        ),
      );
    });

    test('安全模式', () {
      checkWithCore(
        'safe',
        realWorldConfig(
          proxy: const ProxyConfig(safeDns: true),
          cachePath: '/tmp/nano-cache.db',
        ),
      );
    });

    test('TUN 模式', () {
      checkWithCore(
        'tun',
        realWorldConfig(
          proxy: const ProxyConfig(enableTun: true),
          cachePath: '/tmp/nano-cache.db',
        ),
      );
    });
  }, skip: singbox == null ? '未找到 sing-box 内核，跳过真机校验' : null);
}
