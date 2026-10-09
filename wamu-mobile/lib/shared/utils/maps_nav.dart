import 'package:url_launcher/url_launcher.dart';

/// Open Google Maps directions / pin for delivery tracking.
Future<bool> openMapsNavigation({
  double? lat,
  double? lng,
  String? address,
  String? label,
  double? originLat,
  double? originLng,
}) async {
  final dest = _destination(lat: lat, lng: lng, address: address);
  if (dest == null) return false;
  final origin = (originLat != null && originLng != null)
      ? '${originLat.toStringAsFixed(6)},${originLng.toStringAsFixed(6)}'
      : null;
  final uri = Uri.parse(
    'https://www.google.com/maps/dir/?api=1'
    '${origin != null ? '&origin=$origin' : ''}'
    '&destination=$dest'
    '&travelmode=driving'
    '&dir_action=navigate',
  );
  if (await canLaunchUrl(uri)) {
    return launchUrl(uri, mode: LaunchMode.externalApplication);
  }
  final search = Uri.parse(
    'https://www.google.com/maps/search/?api=1&query=$dest',
  );
  return launchUrl(search, mode: LaunchMode.externalApplication);
}

Future<bool> openMapsPin({
  double? lat,
  double? lng,
  String? address,
}) async {
  final dest = _destination(lat: lat, lng: lng, address: address);
  if (dest == null) return false;
  final uri = Uri.parse(
    'https://www.google.com/maps/search/?api=1&query=$dest',
  );
  return launchUrl(uri, mode: LaunchMode.externalApplication);
}

String? _destination({double? lat, double? lng, String? address}) {
  if (lat != null && lng != null) {
    return '${lat.toStringAsFixed(6)},${lng.toStringAsFixed(6)}';
  }
  final a = address?.trim();
  if (a != null && a.isNotEmpty) {
    return Uri.encodeComponent(a);
  }
  return null;
}

double? parseCoord(dynamic v) {
  if (v == null) return null;
  if (v is num) return v.toDouble();
  return double.tryParse(v.toString());
}
