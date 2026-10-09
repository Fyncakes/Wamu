import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/network/api_client.dart';

class RidesRepository {
  RidesRepository(this._client);

  final ApiClient _client;

  Future<Map<String, dynamic>> requestRide({
    required String pickupAddress,
    required String dropoffAddress,
  }) async {
    final response = await _client.post('/rides', data: {
      'pickup_address': pickupAddress,
      'dropoff_address': dropoffAddress,
    });
    return Map<String, dynamic>.from(response.data as Map);
  }

  Future<List<Map<String, dynamic>>> myRides() async {
    final response = await _client.get('/rides');
    final data = response.data;
    if (data is List) {
      return data.whereType<Map>().map((e) => Map<String, dynamic>.from(e)).toList();
    }
    return [];
  }

  Future<Map<String, dynamic>> advanceRide(String rideId, String status) async {
    final response = await _client.patch('/rides/$rideId', data: {'status': status});
    return Map<String, dynamic>.from(response.data as Map);
  }

  Future<List<Map<String, dynamic>>> myRidesAsRider() async {
    final response = await _client.get('/rides/mine-as-rider');
    final data = response.data;
    if (data is List) {
      return data.whereType<Map>().map((e) => Map<String, dynamic>.from(e)).toList();
    }
    return [];
  }
}

final ridesRepositoryProvider = Provider<RidesRepository>((ref) {
  return RidesRepository(ref.watch(apiClientProvider));
});
