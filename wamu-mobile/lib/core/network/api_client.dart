import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../server_config.dart';
import '../storage/secure_storage.dart';

/// HTTP client wrapper around Dio with auth header injection + silent refresh.
///
/// All feature repositories should depend on [apiClientProvider] rather than
/// constructing Dio directly, keeping base URL and interceptors consistent.
class ApiClient {
  ApiClient(this._dio);

  final Dio _dio;

  Dio get dio => _dio;

  Future<Response<T>> get<T>(
    String path, {
    Map<String, dynamic>? queryParameters,
  }) =>
      _dio.get<T>(path, queryParameters: queryParameters);

  Future<Response<T>> post<T>(
    String path, {
    dynamic data,
    Map<String, dynamic>? queryParameters,
  }) =>
      _dio.post<T>(path, data: data, queryParameters: queryParameters);

  Future<Response<T>> put<T>(String path, {dynamic data}) =>
      _dio.put<T>(path, data: data);

  Future<Response<T>> patch<T>(String path, {dynamic data}) =>
      _dio.patch<T>(path, data: data);

  Future<Response<T>> delete<T>(
    String path, {
    Map<String, dynamic>? queryParameters,
  }) =>
      _dio.delete<T>(path, queryParameters: queryParameters);
}

bool _isAuthPath(String path) {
  return path.contains('/auth/refresh') ||
      path.contains('/auth/request-otp') ||
      path.contains('/auth/verify-otp') ||
      path.contains('/auth/device-link/claim');
}

final apiClientProvider = Provider<ApiClient>((ref) {
  // Rebuild Dio whenever the user changes the PC / tunnel URL.
  final baseUrl = ref.watch(serverConfigProvider).apiBaseUrl;
  final storage = ref.watch(secureStorageProvider);
  // Phone demos go through Cloudflare quick tunnels — 30s is often too tight
  // for Discover JSON + media uploads on slow mobile links.
  final dio = Dio(
    BaseOptions(
      baseUrl: baseUrl,
      connectTimeout: const Duration(seconds: 45),
      receiveTimeout: const Duration(seconds: 90),
      sendTimeout: const Duration(seconds: 90),
      headers: {'Content-Type': 'application/json', 'Accept': 'application/json'},
    ),
  );

  // Queued so concurrent 401s share one refresh instead of racing rotations.
  dio.interceptors.add(
    QueuedInterceptorsWrapper(
      onRequest: (options, handler) async {
        final token = await storage.getToken();
        if (token != null && token.isNotEmpty) {
          options.headers['Authorization'] = 'Bearer $token';
        }
        if (options.data is FormData) {
          options.headers.remove('Content-Type');
        }
        handler.next(options);
      },
      onError: (error, handler) async {
        if (error.response?.statusCode != 401) {
          return handler.next(error);
        }
        final opts = error.requestOptions;
        if (_isAuthPath(opts.path) || opts.extra['auth_retried'] == true) {
          return handler.next(error);
        }

        final refresh = await storage.getRefreshToken();
        if (refresh == null || refresh.isEmpty) {
          await storage.clearAuth();
          return handler.next(error);
        }

        try {
          final refreshDio = Dio(
            BaseOptions(
              baseUrl: baseUrl,
              connectTimeout: const Duration(seconds: 45),
              receiveTimeout: const Duration(seconds: 45),
              headers: {
                'Content-Type': 'application/json',
                'Accept': 'application/json',
              },
            ),
          );
          final res = await refreshDio.post<Map<String, dynamic>>(
            '/auth/refresh',
            data: {'refresh_token': refresh},
          );
          final data = res.data;
          final access = data?['access_token']?.toString();
          final newRefresh = data?['refresh_token']?.toString();
          if (access == null || access.isEmpty) {
            await storage.clearAuth();
            return handler.next(error);
          }
          await storage.saveToken(access);
          if (newRefresh != null && newRefresh.isNotEmpty) {
            await storage.saveRefreshToken(newRefresh);
          }

          opts.extra['auth_retried'] = true;
          opts.headers['Authorization'] = 'Bearer $access';
          final retry = await dio.fetch(opts);
          return handler.resolve(retry);
        } catch (_) {
          await storage.clearAuth();
          return handler.next(error);
        }
      },
    ),
  );

  return ApiClient(dio);
});
