import 'package:dio/dio.dart';
import 'package:latlong2/latlong.dart';

class OsrmStep {
  const OsrmStep({
    required this.advice,
    required this.location,
    required this.distanceMeters,
  });

  final String advice;
  final LatLng location;
  final double distanceMeters;
}

/// Public OSRM driving route (road-following polyline + spoken-style steps).
class OsrmRoute {
  const OsrmRoute({
    required this.points,
    required this.steps,
    required this.distanceMeters,
    required this.durationSeconds,
    this.stepDetails = const [],
  });

  final List<LatLng> points;
  final List<String> steps;
  final List<OsrmStep> stepDetails;
  final double distanceMeters;
  final double durationSeconds;

  String get etaLabel {
    final m = (durationSeconds / 60).round().clamp(1, 180);
    return '~$m min';
  }

  String get distanceLabel {
    if (distanceMeters >= 1000) {
      return '${(distanceMeters / 1000).toStringAsFixed(1)} km';
    }
    return '${distanceMeters.round()} m';
  }

  String get nextAdvice =>
      steps.isEmpty ? 'Follow the highlighted route.' : steps.first;

  List<LatLng> remainingFrom(LatLng here) {
    if (points.isEmpty) return [here];
    const dist = Distance();
    var best = 0;
    var bestD = double.infinity;
    for (var i = 0; i < points.length; i++) {
      final d = dist.as(LengthUnit.Meter, here, points[i]);
      if (d < bestD) {
        bestD = d;
        best = i;
      }
    }
    final rest = points.sublist(best);
    if (rest.isEmpty) return [here];
    return [here, ...rest];
  }

  String adviceAhead(LatLng here) {
    const dist = Distance();
    for (final step in stepDetails) {
      if (step.advice.toLowerCase().startsWith('start')) continue;
      final d = dist.as(LengthUnit.Meter, here, step.location);
      if (d > 18) return step.advice;
    }
    return nextAdvice;
  }
}

Future<OsrmRoute?> fetchDrivingRoute(
  LatLng from,
  LatLng to, {
  double? headingDegrees,
}) async {
  try {
    final dio = Dio(BaseOptions(
      connectTimeout: const Duration(seconds: 8),
      receiveTimeout: const Duration(seconds: 8),
    ));
    final url =
        'https://router.project-osrm.org/route/v1/driving/'
        '${from.longitude},${from.latitude};${to.longitude},${to.latitude}';
    final query = <String, dynamic>{
      'overview': 'full',
      'geometries': 'geojson',
      'steps': 'true',
      'continue_straight': 'true',
    };
    if (headingDegrees != null && headingDegrees.isFinite && headingDegrees >= 0) {
      final bearing = headingDegrees.round() % 360;
      query['bearings'] = '$bearing,75;';
      query['radiuses'] = '45;90';
    }
    final res = await dio.get<Map<String, dynamic>>(url, queryParameters: query);
    final routes = res.data?['routes'];
    if (routes is! List || routes.isEmpty) return null;
    final route = routes.first;
    if (route is! Map) return null;
    final coords = (((route['geometry'] as Map?)?['coordinates']) as List?) ?? [];
    final points = <LatLng>[];
    for (final c in coords) {
      if (c is List && c.length >= 2) {
        final lng = (c[0] as num).toDouble();
        final lat = (c[1] as num).toDouble();
        points.add(LatLng(lat, lng));
      }
    }
    final steps = <String>[];
    final details = <OsrmStep>[];
    final legs = route['legs'];
    if (legs is List) {
      for (final leg in legs) {
        if (leg is! Map) continue;
        final raw = leg['steps'];
        if (raw is! List) continue;
        for (final step in raw) {
          if (step is! Map) continue;
          final name = (step['name']?.toString() ?? '').trim();
          final maneuver = step['maneuver'];
          var type = '';
          var modifier = '';
          var loc = points.isEmpty ? from : points.first;
          if (maneuver is Map) {
            type = maneuver['type']?.toString() ?? '';
            modifier = maneuver['modifier']?.toString() ?? '';
            final locRaw = maneuver['location'];
            if (locRaw is List && locRaw.length >= 2) {
              loc = LatLng(
                (locRaw[1] as num).toDouble(),
                (locRaw[0] as num).toDouble(),
              );
            }
          }
          final advice = _advice(type: type, modifier: modifier, road: name);
          if (advice == null) continue;
          steps.add(advice);
          details.add(
            OsrmStep(
              advice: advice,
              location: loc,
              distanceMeters: (step['distance'] as num?)?.toDouble() ?? 0,
            ),
          );
        }
      }
    }
    return OsrmRoute(
      points: points,
      steps: steps,
      stepDetails: details,
      distanceMeters: (route['distance'] as num?)?.toDouble() ?? 0,
      durationSeconds: (route['duration'] as num?)?.toDouble() ?? 0,
    );
  } catch (_) {
    return null;
  }
}

String? _advice({required String type, required String modifier, required String road}) {
  if (type == 'arrive') {
    return road.isEmpty ? 'You have arrived.' : 'Arrive at $road.';
  }
  if (type == 'depart') {
    return road.isEmpty ? 'Start riding.' : 'Start on $road.';
  }
  final turn = switch (modifier) {
    'left' => 'Turn left',
    'slight left' => 'Keep left',
    'sharp left' => 'Sharp left',
    'right' => 'Turn right',
    'slight right' => 'Keep right',
    'sharp right' => 'Sharp right',
    'uturn' => 'Make a U-turn',
    _ => type == 'continue' ? 'Continue' : (type.isEmpty ? null : type.replaceAll('_', ' ')),
  };
  if (turn == null) return null;
  if (road.isEmpty) return '$turn.';
  return '$turn onto $road.';
}
