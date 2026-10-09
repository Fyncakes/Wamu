import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/network/api_client.dart';

class RidersRepository {
  RidersRepository(this._client);

  final ApiClient _client;

  Future<Map<String, dynamic>?> deliveryForOrder(String orderId) async {
    try {
      final response = await _client.get('/deliveries/by-order/$orderId');
      return response.data as Map<String, dynamic>?;
    } catch (_) {
      return null;
    }
  }

  Future<Map<String, dynamic>?> myRiderProfile() async {
    try {
      final response = await _client.get('/riders/me');
      final data = response.data;
      if (data is Map<String, dynamic>) return data;
      if (data is Map) return Map<String, dynamic>.from(data);
      return null;
    } catch (_) {
      return null;
    }
  }

  Future<Map<String, dynamic>> enrollRider({
    required String displayName,
    String vehicleType = 'BODA',
    String? plateNumber,
  }) async {
    final response = await _client.post('/riders/me', data: {
      'display_name': displayName,
      'vehicle_type': vehicleType,
      if (plateNumber != null && plateNumber.isNotEmpty) 'plate_number': plateNumber,
      'lat': 0.3476,
      'lng': 32.5825,
    });
    return Map<String, dynamic>.from(response.data as Map);
  }

  Future<List<Map<String, dynamic>>> myDeliveries() async {
    final response = await _client.get('/deliveries/mine');
    final data = response.data;
    if (data is List) {
      return data.whereType<Map>().map((e) => Map<String, dynamic>.from(e)).toList();
    }
    return [];
  }

  Future<List<Map<String, dynamic>>> openDeliveries() async {
    final response = await _client.get('/deliveries/open');
    final data = response.data;
    if (data is List) {
      return data.whereType<Map>().map((e) => Map<String, dynamic>.from(e)).toList();
    }
    return [];
  }

  Future<Map<String, dynamic>> claimDelivery(String deliveryId) async {
    final response = await _client.post('/deliveries/$deliveryId/claim');
    return Map<String, dynamic>.from(response.data as Map);
  }

  Future<Map<String, dynamic>> advanceDelivery(
    String deliveryId,
    String status, {
    String? proofNote,
    double? lat,
    double? lng,
  }) async {
    final response = await _client.patch('/deliveries/$deliveryId', data: {
      'status': status,
      if (proofNote != null && proofNote.isNotEmpty) 'proof_note': proofNote,
      if (lat != null) 'lat': lat,
      if (lng != null) 'lng': lng,
    });
    return Map<String, dynamic>.from(response.data as Map);
  }

  Future<void> updateMyLocation({required double lat, required double lng}) async {
    await _client.patch('/riders/me/location', data: {'lat': lat, 'lng': lng});
  }

  Future<Map<String, dynamic>> registerRider({
    required String fullName,
    String? dateOfBirth,
    String? nin,
    String? emergencyContactName,
    String? emergencyContactPhone,
    String? locationText,
    String vehicleType = 'BODA',
    String? plateNumber,
    double? lat,
    double? lng,
  }) async {
    final response = await _client.post('/riders/me/register', data: {
      'full_name': fullName,
      if (dateOfBirth != null) 'date_of_birth': dateOfBirth,
      if (nin != null) 'nin': nin,
      if (emergencyContactName != null) 'emergency_contact_name': emergencyContactName,
      if (emergencyContactPhone != null) 'emergency_contact_phone': emergencyContactPhone,
      if (locationText != null) 'location_text': locationText,
      'vehicle_type': vehicleType,
      if (plateNumber != null && plateNumber.isNotEmpty) 'plate_number': plateNumber,
      'lat': lat ?? 0.3476,
      'lng': lng ?? 32.5825,
    });
    return Map<String, dynamic>.from(response.data as Map);
  }

  Future<Map<String, dynamic>> updateVehicleDocs(Map<String, dynamic> body) async {
    final response = await _client.patch('/riders/me/vehicle-docs', data: body);
    return Map<String, dynamic>.from(response.data as Map);
  }

  Future<Map<String, dynamic>> uploadDocument({
    required String docType,
    required String url,
    String? mimeType,
    String? objectKey,
  }) async {
    final response = await _client.post('/riders/me/documents', data: {
      'doc_type': docType,
      'url': url,
      if (mimeType != null) 'mime_type': mimeType,
      if (objectKey != null) 'object_key': objectKey,
    });
    return Map<String, dynamic>.from(response.data as Map);
  }

  Future<Map<String, dynamic>> submitVerification() async {
    final response = await _client.post('/riders/me/submit-verification');
    return Map<String, dynamic>.from(response.data as Map);
  }

  Future<Map<String, dynamic>> myVerification() async {
    final response = await _client.get('/riders/me/verification');
    return Map<String, dynamic>.from(response.data as Map);
  }

  Future<List<Map<String, dynamic>>> listRiders() async {
    final response = await _client.get('/riders');
    final data = response.data;
    if (data is List) {
      return data.whereType<Map>().map((e) => Map<String, dynamic>.from(e)).toList();
    }
    return [];
  }
}

final ridersRepositoryProvider = Provider<RidersRepository>((ref) {
  return RidersRepository(ref.watch(apiClientProvider));
});
