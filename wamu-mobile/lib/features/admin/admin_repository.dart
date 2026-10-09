import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/network/api_client.dart';

class AdminRepository {
  AdminRepository(this._client);

  final ApiClient _client;

  Future<Map<String, dynamic>> stats() async {
    final res = await _client.get('/admin/stats');
    return Map<String, dynamic>.from(res.data as Map);
  }

  Future<List<Map<String, dynamic>>> users() async {
    final res = await _client.get('/admin/users');
    final data = res.data;
    final items = data is Map ? data['items'] : data;
    if (items is! List) return [];
    return items.map((e) => Map<String, dynamic>.from(e as Map)).toList();
  }

  Future<List<Map<String, dynamic>>> riders({String? status}) async {
    final res = await _client.get(
      '/admin/riders',
      queryParameters: {
        if (status != null && status.isNotEmpty) 'status': status,
      },
    );
    final data = res.data;
    final items = data is Map ? data['items'] : data;
    if (items is! List) return [];
    return items.map((e) => Map<String, dynamic>.from(e as Map)).toList();
  }

  Future<List<Map<String, dynamic>>> businesses() async {
    final res = await _client.get('/admin/businesses');
    final data = res.data;
    final items = data is Map ? data['items'] : data;
    if (items is! List) return [];
    return items.map((e) => Map<String, dynamic>.from(e as Map)).toList();
  }

  Future<List<Map<String, dynamic>>> orders() async {
    final res = await _client.get('/admin/orders');
    final data = res.data;
    final items = data is Map ? data['items'] : data;
    if (items is! List) return [];
    return items.map((e) => Map<String, dynamic>.from(e as Map)).toList();
  }

  Future<List<Map<String, dynamic>>> deliveries() async {
    final res = await _client.get('/admin/deliveries');
    final data = res.data;
    final items = data is Map ? data['items'] : data;
    if (items is! List) return [];
    return items.map((e) => Map<String, dynamic>.from(e as Map)).toList();
  }

  Future<void> approveRider(String id, {String? note}) async {
    await _client.post('/admin/riders/$id/approve', data: {
      if (note != null) 'note': note,
    });
  }

  Future<void> rejectRider(String id, {String? note}) async {
    await _client.post('/admin/riders/$id/reject', data: {
      if (note != null) 'note': note,
    });
  }

  Future<void> suspendRider(String id, {String? note}) async {
    await _client.post('/admin/riders/$id/suspend', data: {
      if (note != null) 'note': note,
    });
  }

  Future<void> requestRiderReupload(
    String id, {
    String? note,
    List<String>? reuploadFields,
  }) async {
    await _client.post('/admin/riders/$id/request-reupload', data: {
      if (note != null) 'note': note,
      if (reuploadFields != null) 'reupload_fields': reuploadFields,
    });
  }

  Future<Map<String, dynamic>> riderVerification(String id) async {
    final res = await _client.get('/admin/riders/$id/verification');
    return Map<String, dynamic>.from(res.data as Map);
  }

  Future<void> verifyBusiness(String id) async {
    await _client.post('/admin/businesses/$id/verify');
  }
}

final adminRepositoryProvider = Provider<AdminRepository>((ref) {
  return AdminRepository(ref.watch(apiClientProvider));
});

bool isAdminApiError(Object e) {
  if (e is DioException) {
    return e.response?.statusCode == 403 || e.response?.statusCode == 401;
  }
  return false;
}
