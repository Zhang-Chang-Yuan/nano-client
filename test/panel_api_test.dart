import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:nano_client/core/api/panel_api.dart';

/// 记录请求并按路径返回预设响应的假传输层。
class FakeTransport implements HttpTransport {
  FakeTransport(this.responses);

  /// path（或完整 URL）-> 响应
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

ApiResponse ok(Map<String, dynamic> body) =>
    ApiResponse(statusCode: 200, body: jsonEncode(body));

void main() {
  group('登录', () {
    test('使用明文 JSON 载荷，并带上包含 dart 的 User-Agent', () async {
      final transport = FakeTransport({
        '/passport/auth/login': ok({
          'status': 'success',
          'data': {
            'token': 'abc123',
            'auth_data': 'header.payload.signature',
            'is_admin': 0,
          },
        }),
      });
      final api = PanelApi(
        transport: transport,
        apiBase: 'https://panel.example.com/api/v1',
      );

      final result = await api.login(
        email: 'user@example.com',
        password: 'secret',
      );

      final request = transport.lastRequest;
      expect(request.method, 'POST');
      expect(
        request.url,
        'https://panel.example.com/api/v1/passport/auth/login',
      );
      expect(jsonDecode(request.body! as String), {
        'email': 'user@example.com',
        'password': 'secret',
      });
      // 面板按 UA 白名单过滤，缺少 dart 会拿到 200 空响应
      expect(request.headers['User-Agent'], contains('dart'));
      expect(result.authData, 'header.payload.signature');
      expect(result.token, 'abc123');
    });

    test('登录失败时抛出可读异常', () async {
      final transport = FakeTransport({
        '/passport/auth/login': const ApiResponse(
          statusCode: 422,
          body: '{"message":"邮箱不能为空","errors":{}}',
        ),
      });
      final api = PanelApi(
        transport: transport,
        apiBase: 'https://p.example.com',
      );

      expect(
        () => api.login(email: '', password: ''),
        throwsA(
          isA<PanelApiException>().having(
            (e) => e.statusCode,
            'statusCode',
            422,
          ),
        ),
      );
    });

    test('空响应体给出「UA 可能不在白名单」的明确提示', () async {
      final transport = FakeTransport({
        '/passport/auth/login': const ApiResponse(statusCode: 200, body: ''),
      });
      final api = PanelApi(
        transport: transport,
        apiBase: 'https://p.example.com',
      );

      expect(
        () => api.login(email: 'a@b.com', password: 'x'),
        throwsA(
          isA<PanelApiException>().having(
            (e) => e.message,
            'message',
            contains('User-Agent'),
          ),
        ),
      );
    });

    test('未配置服务器地址时给出明确错误', () {
      final api = PanelApi(transport: FakeTransport({}));
      expect(
        () => api.login(email: 'a@b.com', password: 'x'),
        throwsA(isA<PanelNotConfiguredException>()),
      );
    });
  });

  group('鉴权头', () {
    test('必须使用裸 JWT，不能加 Bearer 前缀', () async {
      final transport = FakeTransport({
        '/user/getSubscribe': ok({
          'status': 'success',
          'data': {'subscribe_url': 'https://sub.example.com/x?token=t'},
        }),
      });
      final api = PanelApi(
        transport: transport,
        apiBase: 'https://p.example.com',
      );

      await api.getSubscribe('my.jwt.token');

      expect(transport.lastRequest.headers['Authorization'], 'my.jwt.token');
    });

    test('fetchSubscription 同样带 dart UA（订阅接口也做白名单）', () async {
      final transport = FakeTransport({
        'https://sub.example.com': const ApiResponse(
          statusCode: 200,
          body: 'dmxlc3M6Ly8...',
        ),
      });
      final api = PanelApi(
        transport: transport,
        apiBase: 'https://p.example.com',
      );

      await api.fetchSubscription('https://sub.example.com/s?token=t');

      expect(transport.lastRequest.headers['User-Agent'], contains('dart'));
    });
  });

  group('订阅解析', () {
    test('正确取出 subscribe_url 与套餐信息', () async {
      final transport = FakeTransport({
        '/user/getSubscribe': ok({
          'status': 'success',
          'data': {
            'subscribe_url':
                'https://sub.example.com/iv/verify_mode.htm?token=t',
            'email': 'user@example.com',
            'transfer_enable': 1000,
            'u': 100,
            'd': 400,
            'expired_at': 4102444800,
            'plan': {'id': 4, 'name': '猎户座'},
          },
        }),
      });
      final api = PanelApi(
        transport: transport,
        apiBase: 'https://p.example.com',
      );

      final info = await api.getSubscribe('jwt');

      expect(info.subscribeUrl, contains('/iv/verify_mode.htm'));
      expect(info.plan?.name, '猎户座');
      expect(info.usedRatio, closeTo(0.5, 0.0001));
      expect(info.isExpired, isFalse);
    });

    test('缺少 subscribe_url 时报错', () async {
      final transport = FakeTransport({
        '/user/getSubscribe': ok({
          'status': 'success',
          'data': <String, dynamic>{},
        }),
      });
      final api = PanelApi(
        transport: transport,
        apiBase: 'https://p.example.com',
      );

      expect(() => api.getSubscribe('jwt'), throwsA(isA<PanelApiException>()));
    });

    test('未登录时面板返回的 fail 会被转成异常', () async {
      final transport = FakeTransport({
        '/user/getSubscribe': const ApiResponse(
          statusCode: 403,
          body: '{"status":"fail","message":"未登录或登陆已过期"}',
        ),
      });
      final api = PanelApi(
        transport: transport,
        apiBase: 'https://p.example.com',
      );

      expect(
        () => api.getSubscribe('bad'),
        throwsA(
          isA<PanelApiException>().having(
            (e) => e.message,
            'message',
            contains('未登录'),
          ),
        ),
      );
    });
  });

  group('配置下发', () {
    test('从 u.json 解析面板地址', () async {
      final transport = FakeTransport({
        'u.json': ok({
          'url': 'https://account.example.com/api/v1',
          'chatUrl': 'https://chat.example.com',
          'owUrl': 'https://ow.example.com',
        }),
      });

      final panel = await PanelApi.fetchPanelConfig(
        transport,
        'https://cfg.example.com/u.json',
      );

      expect(panel.apiBase, 'https://account.example.com/api/v1');
      expect(panel.chatUrl, 'https://chat.example.com');
      expect(panel.owUrl, 'https://ow.example.com');
    });

    test('逐个尝试配置源，命中第一个可用的', () async {
      final transport = FakeTransport({
        'good.json': ok({'url': 'https://good.example.com/api/v1'}),
      });

      final panel = await PanelApi.fetchPanelConfigFromAny(transport, [
        'https://bad1.example.com/u.json',
        'https://good.json',
      ]);

      expect(panel.apiBase, 'https://good.example.com/api/v1');
      expect(transport.requests.length, 2);
    });

    test('全部不可用时抛出异常', () async {
      final transport = FakeTransport({});
      expect(
        () => PanelApi.fetchPanelConfigFromAny(transport, ['https://x/u.json']),
        throwsA(isA<PanelApiException>()),
      );
    });
  });
}
