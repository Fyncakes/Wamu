import 'package:geolocator/geolocator.dart';

/// Kampala beachhead fallback when GPS is unavailable / denied.
const kampalaFallbackLat = 0.3476;
const kampalaFallbackLng = 32.5825;
const kampalaFallbackRadiusKm = 20.0;

const kampalaAreas = <({String id, String label, double lat, double lng, double radiusKm})>[
  (id: 'kampala', label: 'Greater Kampala', lat: 0.3476, lng: 32.5825, radiusKm: 20),
  (id: 'ntinda', label: 'Ntinda', lat: 0.3476, lng: 32.6305, radiusKm: 6),
  (id: 'nakawa', label: 'Nakawa', lat: 0.3370, lng: 32.6200, radiusKm: 6),
  (id: 'central', label: 'Kampala Rd', lat: 0.3136, lng: 32.5811, radiusKm: 5),
  (id: 'wandegeya', label: 'Wandegeya', lat: 0.3350, lng: 32.5700, radiusKm: 5),
];

class NearbyOrigin {
  const NearbyOrigin({
    required this.label,
    required this.lat,
    required this.lng,
    required this.radiusKm,
    required this.fromGps,
  });

  final String label;
  final double lat;
  final double lng;
  final double radiusKm;
  final bool fromGps;
}

/// Resolve device location for nearby shops; fall back to Kampala beachhead.
Future<NearbyOrigin> resolveNearbyOrigin({
  bool preferGps = true,
  String? areaId,
  Duration timeout = const Duration(seconds: 8),
}) async {
  if (!preferGps && areaId != null) {
    final area = kampalaAreas.firstWhere(
      (a) => a.id == areaId,
      orElse: () => kampalaAreas.first,
    );
    return NearbyOrigin(
      label: area.label,
      lat: area.lat,
      lng: area.lng,
      radiusKm: area.radiusKm,
      fromGps: false,
    );
  }

  try {
    final serviceOn = await Geolocator.isLocationServiceEnabled();
    if (!serviceOn) {
      return _kampala('Greater Kampala');
    }

    var permission = await Geolocator.checkPermission();
    if (permission == LocationPermission.denied) {
      permission = await Geolocator.requestPermission();
    }
    if (permission == LocationPermission.denied ||
        permission == LocationPermission.deniedForever) {
      return _kampala('Greater Kampala');
    }

    final pos = await Geolocator.getCurrentPosition(
      locationSettings: const LocationSettings(
        accuracy: LocationAccuracy.medium,
      ),
    ).timeout(timeout);

    return NearbyOrigin(
      label: 'Near you',
      lat: pos.latitude,
      lng: pos.longitude,
      radiusKm: 8,
      fromGps: true,
    );
  } catch (_) {
    return _kampala('Greater Kampala');
  }
}

NearbyOrigin _kampala(String label) => NearbyOrigin(
      label: label,
      lat: kampalaFallbackLat,
      lng: kampalaFallbackLng,
      radiusKm: kampalaFallbackRadiusKm,
      fromGps: false,
    );

/// Pure helper for tests — pick area coords without platform GPS.
NearbyOrigin originForAreaId(String areaId) {
  final area = kampalaAreas.firstWhere(
    (a) => a.id == areaId,
    orElse: () => kampalaAreas.first,
  );
  return NearbyOrigin(
    label: area.label,
    lat: area.lat,
    lng: area.lng,
    radiusKm: area.radiusKm,
    fromGps: false,
  );
}
