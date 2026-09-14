// 面板（V2Board）API 客户端。
//
// 本文件中的协议细节全部来自对 APK 的逆向与真实账号实测，
// 详见仓库根目录的 `doc/03-api-verified.md`。三处关键点：
//
//   1. 面板对 User-Agent 做白名单，必须包含 `dart`（不区分大小写），
//      否则返回 HTTP 200 但 body 为空 —— 极易被误判成"接口挂了"。
//   2. 授权头**不能**加 `Bearer ` 前缀，必须直接放登录返回的 JWT `auth_data`。
//      这是该面板与标准 V2Board 的差异。
//   3. `subscribe_url` 的出口 IP 会轮换，**不可缓存**，每次都要重新获取。

import 'dart:convert';

import '../config/app_config.dart';

/// 面板要求的 User-Agent。
///
/// Dart 的 `HttpClient` 默认 UA 就是 `Dart/<sdk 版本> (dart:io)`，
/// 这里显式写死，避免不同运行时的默认值变化导致被面板拒绝。
const String kPanelUserAgent = 'Dart/3.11.5 (dart:io)';

/// 面板返回 `status != success` 时抛出。
class PanelApiException implements Exception {
  PanelApiException(this.message, {this.statusCode, this.path});

  final String message;
  final int? statusCode;
  final String? path;

  @override
  String toString() {
    final where = path == null ? '' : ' ($path)';
    return 'PanelApiException$where: $message'
        '${statusCode == null ? '' : ' [HTTP $statusCode]'}';
  }
}

/// 面板配置不完整时抛出。
class PanelNotConfiguredException implements Exception {
  PanelNotConfiguredException(this.message);

  final String message;

  @override
  String toString() => 'PanelNotConfiguredException: $message';
}

/// 抽象出 HTTP 传输层，便于在测试中替换为假实现，无需引入额外的 mock 包。
class ApiRequest {
  const ApiRequest({
    required this.method,
    required this.url,
    this.headers = const {},
    this.body,
    this.timeout = const Duration(seconds: 30),
  });

  final String method;
  final String url;
  final Map<String, String> headers;
  final Object? body;
  final Duration timeout;
}

class ApiResponse {
  const ApiResponse({required this.statusCode, required this.body});

  final int statusCode;
  final String body;

  bool get isOk => statusCode >= 200 && statusCode < 300;
}

abstract class HttpTransport {
  Future<ApiResponse> send(ApiRequest request);
}

/// 登录结果。
class LoginResult {
  const LoginResult({
    required this.token,
    required this.authData,
    required this.isAdmin,
  });

  /// 32 位十六进制 token。仅用于拼接订阅地址。
  final String token;

  /// JWT，用于 `Authorization` 头。
  final String authData;

  final bool isAdmin;

  Map<String, dynamic> toJson() => {
    'token': token,
    'authData': authData,
    'isAdmin': isAdmin,
  };

  static LoginResult fromJson(Map<String, dynamic> json) => LoginResult(
    token: (json['token'] as String?) ?? '',
    authData: (json['authData'] as String?) ?? '',
    isAdmin: (json['isAdmin'] as bool?) ?? false,
  );
}

/// 套餐信息。
class PanelPlan {
  const PanelPlan({this.id, this.name, this.speedLimit, this.content});

  final int? id;
  final String? name;
  final int? speedLimit;
  final String? content;

  static PanelPlan? fromJson(Object? value) {
    if (value is! Map) return null;
    final json = value.cast<String, dynamic>();
    return PanelPlan(
      id: json['id'] is int ? json['id'] as int : int.tryParse('${json['id']}'),
      name: json['name'] as String?,
      speedLimit: json['speed_limit'] is int
          ? json['speed_limit'] as int
          : int.tryParse('${json['speed_limit']}'),
      content: json['content'] as String?,
    );
  }
}

/// `/user/getSubscribe` 的返回。
class SubscribeInfo {
  const SubscribeInfo({
    required this.subscribeUrl,
    this.token,
    this.email,
    this.uuid,
    this.expiredAt,
    this.transferEnable,
    this.usedUpload,
    this.usedDownload,
    this.plan,
  });

  final String subscribeUrl;
  final String? token;
  final String? email;
  final String? uuid;
  final int? expiredAt;
  final int? transferEnable;
  final int? usedUpload;
  final int? usedDownload;
  final PanelPlan? plan;

  /// 套餐是否已过期。
  bool get isExpired {
    final ts = expiredAt;
    if (ts == null || ts <= 0) return false;
    return DateTime.fromMillisecondsSinceEpoch(ts * 1000)
        .isBefore(DateTime.now());
  }

  /// 已用流量占比，0..1；无法计算时返回 null。
  double? get usedRatio {
    final total = transferEnable;
    if (total == null || total <= 0) return null;
    final used = (usedUpload ?? 0) + (usedDownload ?? 0);
    return (used / total).clamp(0, 1).toDouble();
  }

  static SubscribeInfo fromJson(Map<String, dynamic> json) {
    final url = (json['subscribe_url'] as String?) ?? '';
    if (url.isEmpty) {
      throw PanelApiException('响应中没有 subscribe_url');
    }
    return SubscribeInfo(
      subscribeUrl: url,
      token: json['token'] as String?,
      email: json['email'] as String?,
      uuid: json['uuid'] as String?,
      expiredAt: _asInt(json['expired_at']),
      transferEnable: _asInt(json['transfer_enable']),
      usedUpload: _asInt(json['u']),
      usedDownload: _asInt(json['d']),
      plan: PanelPlan.fromJson(json['plan']),
    );
  }
}

/// 面板客户端。
class PanelApi {
  PanelApi({required this.transport, String apiBase = ''})
    : _apiBase = _normalizeBase(apiBase);

  final HttpTransport transport;
  String _apiBase;

  String get apiBase => _apiBase;

  /// 允许在初始化向导里改地址后原地更新。
  set apiBase(String value) => _apiBase = _normalizeBase(value);

  static String _normalizeBase(String value) =>
      value.trim().replaceAll(RegExp(r'/+$'), '');

  void _ensureConfigured() {
    if (_apiBase.isEmpty) {
      throw PanelNotConfiguredException('尚未配置服务器地址');
    }
  }

  Uri _uri(String path, [Map<String, String>? query]) =>
      Uri.parse('$_apiBase/$path').replace(queryParameters: query);

  Map<String, String> _headers({String? authData}) => {
    'User-Agent': kPanelUserAgent,
    'Accept': 'application/json',
    if (authData != null && authData.isNotEmpty)
      // 关键：裸 JWT，不加 Bearer 前缀
      'Authorization': authData,
  };

  /// 解析面板统一响应体，取出 `data`。
  Map<String, dynamic> _unwrap(ApiResponse response, String path) {
    final Map<String, dynamic> json;
    try {
      final decoded = jsonDecode(response.body);
      if (decoded is! Map<String, dynamic>) {
        throw const FormatException('响应不是 JSON 对象');
      }
      json = decoded;
    } on FormatException catch (e) {
      if (response.body.trim().isEmpty) {
        throw PanelApiException(
          '面板返回了空响应。通常是因为 User-Agent 不在白名单内',
          statusCode: response.statusCode,
          path: path,
        );
      }
      throw PanelApiException(
        '响应不是合法 JSON: ${e.message}',
        statusCode: response.statusCode,
        path: path,
      );
    }

    final status = json['status'];
    if (status != 'success') {
      throw PanelApiException(
        '${json['message'] ?? '请求失败'}',
        statusCode: response.statusCode,
        path: path,
      );
    }

    final data = json['data'];
    if (data is Map<String, dynamic>) return data;
    if (data is Map) return data.cast<String, dynamic>();
    return <String, dynamic>{};
  }

  /// 账号密码登录。
  ///
  /// 载荷是**明文 JSON**，面板不做任何加密或签名（已实测确认）。
  Future<LoginResult> login({
    required String email,
    required String password,
  }) async {
    _ensureConfigured();
    const path = '/passport/auth/login';
    final response = await transport.send(
      ApiRequest(
        method: 'POST',
        url: _uri(path.substring(1)).toString(),
        headers: {..._headers(), 'Content-Type': 'application/json'},
        body: jsonEncode({'email': email, 'password': password}),
      ),
    );
    final data = _unwrap(response, path);
    final authData = (data['auth_data'] as String?) ?? '';
    final token = (data['token'] as String?) ?? '';
    if (authData.isEmpty && token.isEmpty) {
      throw PanelApiException('登录响应缺少 token/auth_data', path: path);
    }
    return LoginResult(
      token: token,
      authData: authData.isEmpty ? token : authData,
      isAdmin: _asBool(data['is_admin']),
    );
  }

  /// 获取当前账号信息。
  Future<Map<String, dynamic>> getUserInfo(String authData) async {
    _ensureConfigured();
    const path = '/user/info';
    final response = await transport.send(
      ApiRequest(
        method: 'GET',
        url: _uri(path.substring(1)).toString(),
        headers: _headers(authData: authData),
      ),
    );
    return _unwrap(response, path);
  }

  /// 获取订阅信息（含 `subscribe_url`）。
  ///
  /// 注意：**不要缓存返回的 subscribe_url**，其出口 IP 会轮换。
  Future<SubscribeInfo> getSubscribe(String authData) async {
    _ensureConfigured();
    const path = '/user/getSubscribe';
    final response = await transport.send(
      ApiRequest(
        method: 'GET',
        url: _uri(path.substring(1)).toString(),
        headers: _headers(authData: authData),
      ),
    );
    return SubscribeInfo.fromJson(_unwrap(response, path));
  }

  /// 拉取订阅正文。
  ///
  /// 订阅地址同样受 User-Agent 白名单限制。
  Future<String> fetchSubscription(String subscribeUrl) async {
    final response = await transport.send(
      ApiRequest(
        method: 'GET',
        url: subscribeUrl,
        headers: {'User-Agent': kPanelUserAgent, 'Accept': '*/*'},
        timeout: const Duration(seconds: 40),
      ),
    );
    if (!response.isOk) {
      throw PanelApiException(
        '拉取订阅失败',
        statusCode: response.statusCode,
        path: subscribeUrl,
      );
    }
    return response.body;
  }

  /// 从配置下发地址（`u.json`）解析面板信息。
  static Future<PanelConfig> fetchPanelConfig(
    HttpTransport transport,
    String configUrl,
  ) async {
    final response = await transport.send(
      ApiRequest(
        method: 'GET',
        url: configUrl,
        headers: {'User-Agent': kPanelUserAgent, 'Accept': 'application/json'},
      ),
    );
    if (!response.isOk) {
      throw PanelApiException(
        '拉取配置失败',
        statusCode: response.statusCode,
        path: configUrl,
      );
    }
    final Map<String, dynamic> json;
    try {
      final decoded = jsonDecode(response.body);
      if (decoded is! Map<String, dynamic>) {
        throw const FormatException('配置不是 JSON 对象');
      }
      json = decoded;
    } on FormatException catch (e) {
      throw PanelApiException('配置解析失败: ${e.message}', path: configUrl);
    }
    final apiBase = (json['url'] as String?) ?? '';
    if (apiBase.isEmpty) {
      throw PanelApiException('配置中缺少 url 字段', path: configUrl);
    }
    return PanelConfig(
      configSource: configUrl,
      apiBase: apiBase,
      chatUrl: json['chatUrl'] as String?,
      owUrl: json['owUrl'] as String?,
    );
  }

  /// 按顺序尝试多个配置源，返回第一个成功的。
  static Future<PanelConfig> fetchPanelConfigFromAny(
    HttpTransport transport,
    List<String> configUrls,
  ) async {
    Object? lastError;
    for (final url in configUrls) {
      try {
        return await fetchPanelConfig(transport, url);
      } on Object catch (e) {
        lastError = e;
      }
    }
    throw PanelApiException('所有配置源均不可用：$lastError');
  }
}

int? _asInt(Object? value) {
  if (value == null) return null;
  if (value is int) return value;
  if (value is num) return value.toInt();
  return int.tryParse('$value');
}

bool _asBool(Object? value) {
  if (value is bool) return value;
  if (value is num) return value != 0;
  if (value is String) return value == '1' || value.toLowerCase() == 'true';
  return false;
}
