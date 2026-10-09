import 'package:dio/dio.dart';

/// Human-readable API / Dio errors for snackbars.
String apiErrorMessage(Object error, {String fallback = 'Something went wrong'}) {
  if (error is DioException) {
    switch (error.type) {
      case DioExceptionType.connectionTimeout:
      case DioExceptionType.sendTimeout:
      case DioExceptionType.receiveTimeout:
        return 'Connection timed out — check your link and try again';
      case DioExceptionType.connectionError:
        return 'Cannot reach Wamu server — check the demo URL';
      default:
        break;
    }
    final data = error.response?.data;
    if (data is Map) {
      final detail = data['detail'];
      if (detail is String && detail.trim().isNotEmpty) return detail.trim();
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
        return 'Connection timed out — check your link and try again';
      }
      return msg;
    }
  }
  final s = error.toString();
  if (s.contains('receive timeout') || s.contains('DioException')) {
    return 'Connection timed out — check your link and try again';
  }
  if (s.startsWith('Exception: ')) return s.substring(11);
  return s.isEmpty ? fallback : s;
}
