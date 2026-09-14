import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:nano_client/core/api/panel_api.dart';
import 'package:nano_client/core/config/app_config.dart';
import 'package:nano_client/core/proxy/proxy_core.dart';
import 'package:nano_client/core/subscription/proxy_node.dart';
import 'package:nano_client/state/app_controller.dart';

/// 记录请求并返回预设响应的假传输层。
class FakeTransport implements HttpTransport {
  FakeTransport(this.responses);

  final Map<String, ApiResponse> responses;
  final List<ApiRequest> requests = [];

  @override
  Future<ApiResponse> send(ApiRequest request) async {
    requests.add(request);
    for (final entry in responses.entries) {
      if (request.url.contains(entry.key)) return entry.value;
    }
    return const ApiResponse(statusCode: 404, body: '');
  }

  ApiRequest get lastRequest => requests.last;
}

ProxyNode node(String tag) => ProxyNode(
  protocol: 'vless',
  tag: tag,
  server: 'host.example.com',
  port: 443,
  params: const {'uuid': 'u'},
);

AppState stateWith({
  required List<String> tags,
  required NodeSortMode sort,
  Map<String, int> delays = const {},
}) => AppState(
  config: AppConfig(proxy: ProxyConfig(nodeSort: sort)),
  nodes: tags.map(node).toList(),
  nodeDelays: delays,
);

void main() {
  group('节点排序', () {
    test('默认顺序保持订阅原样', () {
      final state = stateWith(
        tags: ['C', 'A', 'B'],
        sort: NodeSortMode.defaultOrder,
      );
      expect(state.sortedNodes.map((n) => n.tag), ['C', 'A', 'B']);
    });

    test('按名称排序', () {
      final state = stateWith(tags: ['C', 'A', 'B'], sort: NodeSortMode.name);
      expect(state.sortedNodes.map((n) => n.tag), ['A', 'B', 'C']);
    });

    test('按延迟升序，且未测速与超时排到最后', () {
      final state = stateWith(
        tags: ['慢', '未测', '快', '超时', '中'],
        sort: NodeSortMode.delay,
        delays: {'慢': 800, '快': 42, '中': 230, '超时': AppState.failedDelay},
      );

      expect(state.sortedNodes.map((n) => n.tag), ['快', '中', '慢', '未测', '超时']);
    });

    test('全部未测速时不会崩，顺序稳定', () {
      final state = stateWith(tags: ['A', 'B'], sort: NodeSortMode.delay);
      expect(state.sortedNodes.map((n) => n.tag), ['A', 'B']);
    });

    test('排序不会改动原始 nodes 列表', () {
      final state = stateWith(
        tags: ['B', 'A'],
        sort: NodeSortMode.name,
        delays: const {},
      );
      state.sortedNodes;
      expect(state.nodes.map((n) => n.tag), ['B', 'A']);
    });
  });

  group('Clash API 测速', () {
    test('正常返回 delay', () async {
      final transport = FakeTransport({
        '/delay': ApiResponse(
          statusCode: 200,
          body: jsonEncode({'delay': 123}),
        ),
      });
      final core = ProcessProxyCore(
        executablePath: '/nonexistent',
        transport: transport,
      );

      expect(await core.testDelay('节点 A'), 123);

      final url = transport.lastRequest.url;
      expect(url, contains('/proxies/'));
      expect(url, contains('timeout='));
      expect(url, contains(Uri.encodeComponent('节点 A')));
    });

    test('节点名里的特殊字符会被正确转义', () async {
      final transport = FakeTransport({
        '/delay': ApiResponse(statusCode: 200, body: jsonEncode({'delay': 50})),
      });
      final core = ProcessProxyCore(
        executablePath: '/nonexistent',
        transport: transport,
      );

      await core.testDelay('🇭🇰香江-E(通用) #2');
      // 未转义的话 URL 会被斜杠和括号截断
      expect(transport.lastRequest.url, isNot(contains(' #2/delay')));
      expect(transport.lastRequest.url, contains('%23'));
    });

    test('超时或失败返回 null 而不是抛异常', () async {
      final failing = FakeTransport({
        '/delay': const ApiResponse(statusCode: 504, body: ''),
      });
      final core = ProcessProxyCore(
        executablePath: '/nonexistent',
        transport: failing,
      );
      expect(await core.testDelay('X'), isNull);

      final garbage = FakeTransport({
        '/delay': const ApiResponse(statusCode: 200, body: 'not json'),
      });
      final core2 = ProcessProxyCore(
        executablePath: '/nonexistent',
        transport: garbage,
      );
      expect(await core2.testDelay('X'), isNull);
    });

    test('没有传输层时抛错', () {
      final core = ProcessProxyCore(executablePath: '/nonexistent');
      expect(() => core.testDelay('X'), throwsStateError);
    });
  });
}
