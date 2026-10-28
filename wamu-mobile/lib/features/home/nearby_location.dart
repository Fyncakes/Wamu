import 'package:geolocator/geolocator.dart';

/// Kampala beachhead fallback when GPS is unavailable / denied.
const kampalaFallbackLat = 0.3476;
const kampalaFallbackLng = 32.5825;
const kampalaFallbackRadiusKm = 20.0;

/// Area chips for nearby shops — Greater Kampala first, then towns across Uganda.
const ugandaAreas = <({String id, String label, double lat, double lng, double radiusKm})>[
  // Greater Kampala & metro
  (id: 'kampala', label: 'Greater Kampala', lat: 0.3476, lng: 32.5825, radiusKm: 20),
  (id: 'ntinda', label: 'Ntinda', lat: 0.3476, lng: 32.6305, radiusKm: 6),
  (id: 'nakawa', label: 'Nakawa', lat: 0.3370, lng: 32.6200, radiusKm: 6),
  (id: 'central', label: 'Kampala Rd', lat: 0.3136, lng: 32.5811, radiusKm: 5),
  (id: 'wandegeya', label: 'Wandegeya', lat: 0.3350, lng: 32.5700, radiusKm: 5),
  (id: 'kololo', label: 'Kololo', lat: 0.3300, lng: 32.5920, radiusKm: 4),
  (id: 'nakasero', label: 'Nakasero', lat: 0.3190, lng: 32.5820, radiusKm: 4),
  (id: 'bugolobi', label: 'Bugolobi', lat: 0.3200, lng: 32.6200, radiusKm: 5),
  (id: 'bukoto', label: 'Bukoto', lat: 0.3500, lng: 32.6000, radiusKm: 5),
  (id: 'kamwokya', label: 'Kamwokya', lat: 0.3420, lng: 32.5900, radiusKm: 4),
  (id: 'naguru', label: 'Naguru', lat: 0.3400, lng: 32.6050, radiusKm: 4),
  (id: 'kyambogo', label: 'Kyambogo', lat: 0.3480, lng: 32.6300, radiusKm: 5),
  (id: 'luzira', label: 'Luzira', lat: 0.3000, lng: 32.6550, radiusKm: 5),
  (id: 'port-bell', label: 'Port Bell', lat: 0.2900, lng: 32.6500, radiusKm: 5),
  (id: 'makerere', label: 'Makerere', lat: 0.3350, lng: 32.5670, radiusKm: 4),
  (id: 'mulago', label: 'Mulago', lat: 0.3400, lng: 32.5770, radiusKm: 4),
  (id: 'kawempe', label: 'Kawempe', lat: 0.3800, lng: 32.5600, radiusKm: 6),
  (id: 'bwaise', label: 'Bwaise', lat: 0.3600, lng: 32.5600, radiusKm: 5),
  (id: 'makindye', label: 'Makindye', lat: 0.2900, lng: 32.5800, radiusKm: 6),
  (id: 'nsambya', label: 'Nsambya', lat: 0.3000, lng: 32.5850, radiusKm: 4),
  (id: 'kabalagala', label: 'Kabalagala', lat: 0.2950, lng: 32.6000, radiusKm: 4),
  (id: 'ggaba', label: 'Ggaba', lat: 0.2600, lng: 32.6350, radiusKm: 5),
  (id: 'munyonyo', label: 'Munyonyo', lat: 0.2450, lng: 32.6250, radiusKm: 5),
  (id: 'rubaga', label: 'Rubaga', lat: 0.3000, lng: 32.5500, radiusKm: 5),
  (id: 'mengo', label: 'Mengo', lat: 0.3050, lng: 32.5600, radiusKm: 4),
  (id: 'nateete', label: 'Nateete', lat: 0.3000, lng: 32.5200, radiusKm: 5),
  (id: 'busega', label: 'Busega', lat: 0.3100, lng: 32.5100, radiusKm: 5),
  (id: 'najjera', label: 'Najjera', lat: 0.3700, lng: 32.6500, radiusKm: 5),
  (id: 'kira', label: 'Kira', lat: 0.3900, lng: 32.6400, radiusKm: 6),
  (id: 'bweyogerere', label: 'Bweyogerere', lat: 0.3600, lng: 32.6700, radiusKm: 5),
  (id: 'kireka', label: 'Kireka', lat: 0.3500, lng: 32.6500, radiusKm: 5),
  (id: 'namugongo', label: 'Namugongo', lat: 0.3900, lng: 32.6700, radiusKm: 5),
  (id: 'seeta', label: 'Seeta', lat: 0.3700, lng: 32.7100, radiusKm: 6),
  (id: 'mukono', label: 'Mukono', lat: 0.3533, lng: 32.7553, radiusKm: 12),
  (id: 'nansana', label: 'Nansana', lat: 0.3750, lng: 32.5300, radiusKm: 8),
  (id: 'kasangati', label: 'Kasangati', lat: 0.4300, lng: 32.5800, radiusKm: 8),
  (id: 'gayaza', label: 'Gayaza', lat: 0.4500, lng: 32.6000, radiusKm: 8),
  (id: 'wakiso', label: 'Wakiso', lat: 0.4044, lng: 32.4594, radiusKm: 12),
  (id: 'kyengera', label: 'Kyengera', lat: 0.3000, lng: 32.4800, radiusKm: 6),
  (id: 'entebbe', label: 'Entebbe', lat: 0.0512, lng: 32.4637, radiusKm: 12),
  (id: 'kajjansi', label: 'Kajjansi', lat: 0.2100, lng: 32.5400, radiusKm: 6),
  (id: 'lubowa', label: 'Lubowa', lat: 0.2300, lng: 32.5600, radiusKm: 5),

  // Central region
  (id: 'masaka', label: 'Masaka', lat: -0.3411, lng: 31.7361, radiusKm: 15),
  (id: 'mityana', label: 'Mityana', lat: 0.4175, lng: 32.0422, radiusKm: 12),
  (id: 'mubende', label: 'Mubende', lat: 0.5603, lng: 31.3900, radiusKm: 12),
  (id: 'luweero', label: 'Luweero', lat: 0.8492, lng: 32.4731, radiusKm: 12),
  (id: 'kayunga', label: 'Kayunga', lat: 0.7025, lng: 32.8886, radiusKm: 12),
  (id: 'mpigi', label: 'Mpigi', lat: 0.2250, lng: 32.3136, radiusKm: 12),
  (id: 'kiboga', label: 'Kiboga', lat: 0.9167, lng: 31.7667, radiusKm: 12),
  (id: 'nakasongola', label: 'Nakasongola', lat: 1.3089, lng: 32.4564, radiusKm: 12),
  (id: 'lyantonde', label: 'Lyantonde', lat: -0.4031, lng: 31.1572, radiusKm: 12),
  (id: 'sembabule', label: 'Sembabule', lat: -0.0772, lng: 31.4567, radiusKm: 12),
  (id: 'rakai', label: 'Rakai', lat: -0.7200, lng: 31.4040, radiusKm: 12),
  (id: 'kyotera', label: 'Kyotera', lat: -0.6333, lng: 31.5500, radiusKm: 12),
  (id: 'kalungu', label: 'Kalungu', lat: -0.1667, lng: 31.7500, radiusKm: 12),
  (id: 'gomba', label: 'Gomba', lat: 0.2000, lng: 31.7000, radiusKm: 12),
  (id: 'butambala', label: 'Butambala', lat: 0.1833, lng: 32.0833, radiusKm: 10),
  (id: 'bukomansimbi', label: 'Bukomansimbi', lat: -0.1667, lng: 31.6500, radiusKm: 10),
  (id: 'kassanda', label: 'Kassanda', lat: 0.5500, lng: 31.7500, radiusKm: 12),
  (id: 'kyankwanzi', label: 'Kyankwanzi', lat: 1.2000, lng: 31.7000, radiusKm: 12),
  (id: 'nakaseke', label: 'Nakaseke', lat: 0.7500, lng: 32.2500, radiusKm: 12),
  (id: 'buikwe', label: 'Buikwe', lat: 0.3400, lng: 33.0300, radiusKm: 12),
  (id: 'lugazi', label: 'Lugazi', lat: 0.3833, lng: 32.9167, radiusKm: 10),
  (id: 'buvuma', label: 'Buvuma', lat: -0.3500, lng: 33.3000, radiusKm: 15),
  (id: 'kalangala', label: 'Kalangala', lat: -0.3200, lng: 32.2900, radiusKm: 15),

  // Eastern region
  (id: 'jinja', label: 'Jinja', lat: 0.4244, lng: 33.2042, radiusKm: 15),
  (id: 'iganga', label: 'Iganga', lat: 0.6092, lng: 33.4686, radiusKm: 12),
  (id: 'mbale', label: 'Mbale', lat: 1.0827, lng: 34.1750, radiusKm: 15),
  (id: 'tororo', label: 'Tororo', lat: 0.6930, lng: 34.1809, radiusKm: 12),
  (id: 'busia', label: 'Busia', lat: 0.4659, lng: 34.0922, radiusKm: 12),
  (id: 'soroti', label: 'Soroti', lat: 1.7145, lng: 33.6111, radiusKm: 15),
  (id: 'kamuli', label: 'Kamuli', lat: 0.9472, lng: 33.1197, radiusKm: 12),
  (id: 'pallisa', label: 'Pallisa', lat: 1.1450, lng: 33.7097, radiusKm: 12),
  (id: 'kumi', label: 'Kumi', lat: 1.4608, lng: 33.9361, radiusKm: 12),
  (id: 'kapchorwa', label: 'Kapchorwa', lat: 1.3965, lng: 34.4509, radiusKm: 12),
  (id: 'sironko', label: 'Sironko', lat: 1.2300, lng: 34.2500, radiusKm: 12),
  (id: 'bududa', label: 'Bududa', lat: 1.0167, lng: 34.3333, radiusKm: 12),
  (id: 'manafwa', label: 'Manafwa', lat: 0.9500, lng: 34.3500, radiusKm: 12),
  (id: 'bulambuli', label: 'Bulambuli', lat: 1.3000, lng: 34.3500, radiusKm: 12),
  (id: 'kween', label: 'Kween', lat: 1.4500, lng: 34.5500, radiusKm: 12),
  (id: 'bukedea', label: 'Bukedea', lat: 1.3500, lng: 34.0500, radiusKm: 12),
  (id: 'budaka', label: 'Budaka', lat: 1.0667, lng: 33.9500, radiusKm: 10),
  (id: 'kibuku', label: 'Kibuku', lat: 1.0500, lng: 33.8000, radiusKm: 10),
  (id: 'butaleja', label: 'Butaleja', lat: 0.9167, lng: 33.9500, radiusKm: 12),
  (id: 'namutumba', label: 'Namutumba', lat: 0.8333, lng: 33.6833, radiusKm: 12),
  (id: 'bugiri', label: 'Bugiri', lat: 0.5714, lng: 33.7417, radiusKm: 12),
  (id: 'mayuge', label: 'Mayuge', lat: 0.4597, lng: 33.4800, radiusKm: 12),
  (id: 'kaliro', label: 'Kaliro', lat: 0.9000, lng: 33.5000, radiusKm: 12),
  (id: 'buyende', label: 'Buyende', lat: 1.1500, lng: 33.1500, radiusKm: 12),
  (id: 'luuka', label: 'Luuka', lat: 0.7000, lng: 33.3000, radiusKm: 12),
  (id: 'namayingo', label: 'Namayingo', lat: 0.2333, lng: 33.8667, radiusKm: 12),
  (id: 'serere', label: 'Serere', lat: 1.5000, lng: 33.5500, radiusKm: 12),
  (id: 'ngora', label: 'Ngora', lat: 1.4500, lng: 33.7667, radiusKm: 10),
  (id: 'amuria', label: 'Amuria', lat: 2.0333, lng: 33.6500, radiusKm: 12),
  (id: 'katakwi', label: 'Katakwi', lat: 1.9167, lng: 34.0000, radiusKm: 12),
  (id: 'kaberamaido', label: 'Kaberamaido', lat: 1.7500, lng: 33.1500, radiusKm: 12),
  (id: 'kalaki', label: 'Kalaki', lat: 1.8333, lng: 33.3333, radiusKm: 12),
  (id: 'kapelebyong', label: 'Kapelebyong', lat: 2.2000, lng: 33.8000, radiusKm: 12),

  // Northern region
  (id: 'gulu', label: 'Gulu', lat: 2.7747, lng: 32.2990, radiusKm: 15),
  (id: 'lira', label: 'Lira', lat: 2.2499, lng: 32.8998, radiusKm: 15),
  (id: 'kitgum', label: 'Kitgum', lat: 3.2783, lng: 32.8867, radiusKm: 12),
  (id: 'pader', label: 'Pader', lat: 2.8500, lng: 33.2000, radiusKm: 12),
  (id: 'apac', label: 'Apac', lat: 1.9756, lng: 32.5386, radiusKm: 12),
  (id: 'oyam', label: 'Oyam', lat: 2.2333, lng: 32.3833, radiusKm: 12),
  (id: 'kole', label: 'Kole', lat: 2.4000, lng: 32.8000, radiusKm: 12),
  (id: 'dokolo', label: 'Dokolo', lat: 1.9167, lng: 33.1667, radiusKm: 12),
  (id: 'amolatar', label: 'Amolatar', lat: 1.6333, lng: 32.8333, radiusKm: 12),
  (id: 'otuke', label: 'Otuke', lat: 2.5000, lng: 33.5000, radiusKm: 12),
  (id: 'alebtong', label: 'Alebtong', lat: 2.2500, lng: 33.2500, radiusKm: 12),
  (id: 'kwania', label: 'Kwania', lat: 1.8000, lng: 32.7000, radiusKm: 12),
  (id: 'omoro', label: 'Omoro', lat: 2.6000, lng: 32.4000, radiusKm: 12),
  (id: 'nwoya', label: 'Nwoya', lat: 2.6500, lng: 31.9000, radiusKm: 12),
  (id: 'amuru', label: 'Amuru', lat: 2.8167, lng: 32.0000, radiusKm: 12),
  (id: 'lamwo', label: 'Lamwo', lat: 3.5500, lng: 32.8000, radiusKm: 12),
  (id: 'agago', label: 'Agago', lat: 3.0000, lng: 33.4000, radiusKm: 12),

  // West Nile
  (id: 'arua', label: 'Arua', lat: 3.0201, lng: 30.9111, radiusKm: 15),
  (id: 'nebbi', label: 'Nebbi', lat: 2.4783, lng: 31.0889, radiusKm: 12),
  (id: 'adjumani', label: 'Adjumani', lat: 3.3779, lng: 31.7909, radiusKm: 12),
  (id: 'moyo', label: 'Moyo', lat: 3.6500, lng: 31.7200, radiusKm: 12),
  (id: 'yumbe', label: 'Yumbe', lat: 3.4650, lng: 31.2469, radiusKm: 12),
  (id: 'koboko', label: 'Koboko', lat: 3.4167, lng: 30.9600, radiusKm: 12),
  (id: 'maracha', label: 'Maracha', lat: 3.2833, lng: 30.9333, radiusKm: 12),
  (id: 'zombo', label: 'Zombo', lat: 2.5000, lng: 30.9000, radiusKm: 12),
  (id: 'pakwach', label: 'Pakwach', lat: 2.4500, lng: 31.5000, radiusKm: 12),
  (id: 'obongi', label: 'Obongi', lat: 3.2500, lng: 31.5500, radiusKm: 12),
  (id: 'madiopei', label: 'Madi-Opei', lat: 3.7000, lng: 32.7000, radiusKm: 12),
  (id: 'terego', label: 'Terego', lat: 3.1500, lng: 31.1000, radiusKm: 12),

  // Western region
  (id: 'mbarara', label: 'Mbarara', lat: -0.6072, lng: 30.6545, radiusKm: 15),
  (id: 'fort-portal', label: 'Fort Portal', lat: 0.6710, lng: 30.2748, radiusKm: 15),
  (id: 'kabale', label: 'Kabale', lat: -1.2486, lng: 29.9899, radiusKm: 12),
  (id: 'kasese', label: 'Kasese', lat: 0.1833, lng: 30.0833, radiusKm: 15),
  (id: 'hoima', label: 'Hoima', lat: 1.4356, lng: 31.3436, radiusKm: 15),
  (id: 'masindi', label: 'Masindi', lat: 1.6744, lng: 31.7150, radiusKm: 12),
  (id: 'bushenyi', label: 'Bushenyi', lat: -0.5422, lng: 30.1861, radiusKm: 12),
  (id: 'ishaka', label: 'Ishaka', lat: -0.5440, lng: 30.1380, radiusKm: 10),
  (id: 'ntungamo', label: 'Ntungamo', lat: -0.8833, lng: 30.2667, radiusKm: 12),
  (id: 'rukungiri', label: 'Rukungiri', lat: -0.8411, lng: 29.9419, radiusKm: 12),
  (id: 'kanungu', label: 'Kanungu', lat: -0.9000, lng: 29.7800, radiusKm: 12),
  (id: 'kisoro', label: 'Kisoro', lat: -1.2854, lng: 29.6850, radiusKm: 12),
  (id: 'bundibugyo', label: 'Bundibugyo', lat: 0.7085, lng: 30.0634, radiusKm: 12),
  (id: 'ntoroko', label: 'Ntoroko', lat: 1.0500, lng: 30.4000, radiusKm: 12),
  (id: 'kyenjojo', label: 'Kyenjojo', lat: 0.6167, lng: 30.6500, radiusKm: 12),
  (id: 'kamwenge', label: 'Kamwenge', lat: 0.1833, lng: 30.4500, radiusKm: 12),
  (id: 'kyegegwa', label: 'Kyegegwa', lat: 0.5000, lng: 31.0500, radiusKm: 12),
  (id: 'ibanda', label: 'Ibanda', lat: -0.1333, lng: 30.5000, radiusKm: 12),
  (id: 'kiruhura', label: 'Kiruhura', lat: -0.2000, lng: 30.8500, radiusKm: 12),
  (id: 'isingiro', label: 'Isingiro', lat: -0.8333, lng: 30.8167, radiusKm: 12),
  (id: 'mitooma', label: 'Mitooma', lat: -0.6167, lng: 30.0000, radiusKm: 12),
  (id: 'rubirizi', label: 'Rubirizi', lat: -0.2667, lng: 30.1000, radiusKm: 12),
  (id: 'sheema', label: 'Sheema', lat: -0.5500, lng: 30.3500, radiusKm: 12),
  (id: 'buhweju', label: 'Buhweju', lat: -0.3500, lng: 30.3500, radiusKm: 12),
  (id: 'bunyangabu', label: 'Bunyangabu', lat: 0.5000, lng: 30.2000, radiusKm: 12),
  (id: 'kakumiro', label: 'Kakumiro', lat: 0.7800, lng: 31.3200, radiusKm: 12),
  (id: 'kagadi', label: 'Kagadi', lat: 0.9500, lng: 30.8000, radiusKm: 12),
  (id: 'kibaale', label: 'Kibaale', lat: 0.8000, lng: 31.0667, radiusKm: 12),
  (id: 'kiryandongo', label: 'Kiryandongo', lat: 1.8833, lng: 32.0667, radiusKm: 12),
  (id: 'buliisa', label: 'Buliisa', lat: 2.1167, lng: 31.4167, radiusKm: 12),
  (id: 'rubanda', label: 'Rubanda', lat: -1.1500, lng: 29.8500, radiusKm: 12),
  (id: 'rukiga', label: 'Rukiga', lat: -1.1000, lng: 30.0500, radiusKm: 12),
  (id: 'rwampara', label: 'Rwampara', lat: -0.7500, lng: 30.5000, radiusKm: 12),
  (id: 'kikuube', label: 'Kikuube', lat: 1.2500, lng: 31.1000, radiusKm: 12),

  // Karamoja
  (id: 'moroto', label: 'Moroto', lat: 2.5350, lng: 34.6667, radiusKm: 15),
  (id: 'kotido', label: 'Kotido', lat: 2.9800, lng: 34.1300, radiusKm: 12),
  (id: 'kaabong', label: 'Kaabong', lat: 3.5167, lng: 34.1333, radiusKm: 12),
  (id: 'abim', label: 'Abim', lat: 2.7167, lng: 33.6500, radiusKm: 12),
  (id: 'napak', label: 'Napak', lat: 2.2500, lng: 34.2500, radiusKm: 12),
  (id: 'amudat', label: 'Amudat', lat: 1.9500, lng: 34.9500, radiusKm: 12),
  (id: 'nabilatuk', label: 'Nabilatuk', lat: 2.0500, lng: 34.5500, radiusKm: 12),
  (id: 'karenga', label: 'Karenga', lat: 3.6500, lng: 33.8000, radiusKm: 12),
];

/// Back-compat alias used by home / rider screens.
const kampalaAreas = ugandaAreas;

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
    final area = ugandaAreas.firstWhere(
      (a) => a.id == areaId,
      orElse: () => ugandaAreas.first,
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
  final area = ugandaAreas.firstWhere(
    (a) => a.id == areaId,
    orElse: () => ugandaAreas.first,
  );
  return NearbyOrigin(
    label: area.label,
    lat: area.lat,
    lng: area.lng,
    radiusKm: area.radiusKm,
    fromGps: false,
  );
}
