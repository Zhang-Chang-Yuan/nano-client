// 基于 dio 的 [HttpTransport] 实现。
//
// 放在单独文件里，是为了让 `panel_api.dart` 等核心逻辑不直接依赖 dio，
// 从而可以在纯 Dart 单元测试中使用假传输层。

import 'package:dio/dio.dart';

import 'panel_api.dart';

class DioTransport implements HttpTransport {
  DioTransport({Dio? dio})
    : _dio =
          dio ??
          Dio(
            BaseOptions(
              connectTimeout: const Duration(seconds: 15),
              receiveTimeout: const Duration(seconds: 30),
              // 由调用方判断状态码，避免 4xx 直接抛异常丢失响应体
              validateStatus: (_) => true,
              responseType: ResponseType.plain,
            ),
          );

  final Dio _dio;

  @override
  Future<ApiResponse> send(ApiRequest request) async {
    final response = await _dio.request<String>(
      request.url,
      data: request.body,
      options: Options(
        method: request.method,
        headers: request.headers,
        sendTimeout: request.timeout,
        receiveTimeout: request.timeout,
        validateStatus: (_) => true,
        responseType: ResponseType.plain,
      ),
    );
    return ApiResponse(
      statusCode: response.statusCode ?? 0,
      body: response.data ?? '',
    );
  }
}
