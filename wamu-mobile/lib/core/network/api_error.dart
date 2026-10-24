import 'package:dio/dio.dart';

/// Human-readable API / Dio errors for snackbars.
String apiErrorMessage(Object error, {String fallback = 'Something went wrong'}) {
  if (error is DioException) {
    switch (error.type) {
      case DioExceptionType.connectionTimeout:
      case DioExceptionType.sendTimeout:
      case DioExceptionType.receiveTimeout:
        return 'Unable to load content. Check your internet connection and try again.';
      case DioExceptionType.connectionError:
        return 'Unable to load content. Check your internet connection and try again.';
      default:
        break;
    }
    final status = error.response?.statusCode ?? 0;
    if (status >= 500) {
      return 'Unable to load content. Please try again.';
    }
    final data = error.response?.data;
    if (data is Map) {
      final detail = data['detail'];
      if (detail is String && detail.trim().isNotEmpty && !_internal(detail)) {
        return detail.trim();
      }
      if (detail is List && detail.isNotEmpty) {
        final first = detail.first;
        if (first is Map && first['msg'] != null) {
          return first['msg'].toString();
        }
        return detail.first.toString();
      }
    }
    if (error.message != null && error.message!.isNotEmpty) {
      // Hide raw DioException jargon from the UI.
      final msg = error.message!;
      if (msg.contains('receive timeout') || msg.contains('took longer than')) {
        return 'Unable to load content. Check your internet connection and try again.';
      }
      return msg;
    }
  }
  final s = error.toString();
  if (s.contains('SocketException') || s.contains('Failed host lookup') || s.contains('Network')) {
    return 'Unable to load content. Check your internet connection and try again.';
  }
  if (s.contains('receive timeout') || s.contains('DioException')) {
    return 'Unable to load content. Check your internet connection and try again.';
  }
  if (_internal(s)) return fallback;
  if (s.startsWith('Exception: ')) return s.substring(11);
  return s.isEmpty ? fallback : s;
}

bool _internal(String value) {
  final lower = value.toLowerCase();
  return lower.contains('traceback') ||
      lower.contains('sqlalchemy') ||
      lower.contains('asyncpg') ||
      lower.contains('stack') ||
      lower.contains('/app/') ||
      lower.contains('password');
}
