import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';

import '../../core/theme/app_theme.dart';
import '../../shared/utils/maps_nav.dart';
import '../../shared/utils/order_tracking.dart';

/// In-app live delivery map: shop · rider · customer pins.
class DeliveryTrackingMap extends StatelessWidget {
  const DeliveryTrackingMap({
    super.key,
    required this.delivery,
    this.height = 220,
  });

  final Map<String, dynamic> delivery;
  final double height;

  @override
  Widget build(BuildContext context) {
    final pickup = _pt(delivery['pickup_lat'], delivery['pickup_lng']);
    final dropoff = _pt(delivery['dropoff_lat'], delivery['dropoff_lng']);
    final rider = _pt(delivery['rider_lat'], delivery['rider_lng']);
    final status = delivery['status']?.toString() ?? '';
    final label = deliveryStatusLabel(status);

    if (pickup == null && dropoff == null && rider == null) {
      return const SizedBox.shrink();
    }

    final points = <LatLng>[
      if (pickup != null) pickup,
      if (rider != null) rider,
      if (dropoff != null) dropoff,
    ];
    final center = rider ?? pickup ?? dropoff!;
    final bounds = points.length >= 2
        ? LatLngBounds.fromPoints(points)
        : null;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'Live track · $label',
          style: const TextStyle(fontWeight: FontWeight.w800),
        ),
        const SizedBox(height: 8),
        ClipRRect(
          borderRadius: BorderRadius.circular(12),
          child: SizedBox(
            height: height,
            width: double.infinity,
            child: FlutterMap(
              key: ValueKey(
                '${delivery['status']}_${delivery['rider_lat']}_${delivery['rider_lng']}',
              ),
              options: MapOptions(
                initialCenter: center,
                initialZoom: 13.2,
                interactionOptions: const InteractionOptions(
                  flags: InteractiveFlag.pinchZoom |
                      InteractiveFlag.drag |
                      InteractiveFlag.doubleTapZoom,
                ),
                initialCameraFit: bounds == null
                    ? null
                    : CameraFit.bounds(
                        bounds: bounds,
                        padding: const EdgeInsets.all(36),
                        maxZoom: 15,
                      ),
              ),
              children: [
                TileLayer(
                  urlTemplate: 'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
                  userAgentPackageName: 'ug.wamu.mobile',
                ),
                if (pickup != null && dropoff != null)
                  PolylineLayer(
                    polylines: [
                      Polyline(
                        points: [
                          pickup,
                          if (rider != null) rider,
                          dropoff,
                        ],
                        strokeWidth: 3.5,
                        color: AppTheme.accentGreen.withValues(alpha: 0.85),
                      ),
                    ],
                  ),
                MarkerLayer(
                  markers: [
                    if (pickup != null)
                      Marker(
                        point: pickup,
                        width: 44,
                        height: 44,
                        child: _Pin(
                          color: const Color(0xFF1565C0),
                          icon: Icons.storefront,
                          tooltip: 'Shop',
                        ),
                      ),
                    if (dropoff != null)
                      Marker(
                        point: dropoff,
                        width: 44,
                        height: 44,
                        child: _Pin(
                          color: const Color(0xFF6A1B9A),
                          icon: Icons.home_outlined,
                          tooltip: 'You',
                        ),
                      ),
                    if (rider != null)
                      Marker(
                        point: rider,
                        width: 48,
                        height: 48,
                        child: _Pin(
                          color: AppTheme.accentGreen,
                          icon: Icons.delivery_dining,
                          tooltip: 'Rider',
                          pulse: true,
                        ),
                      ),
                  ],
                ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 8),
        Wrap(
          spacing: 10,
          runSpacing: 4,
          children: const [
            _LegendDot(color: Color(0xFF1565C0), label: 'Shop'),
            _LegendDot(color: AppTheme.accentGreen, label: 'Rider'),
            _LegendDot(color: Color(0xFF6A1B9A), label: 'You'),
          ],
        ),
      ],
    );
  }

  LatLng? _pt(dynamic lat, dynamic lng) {
    final a = parseCoord(lat);
    final b = parseCoord(lng);
    if (a == null || b == null) return null;
    return LatLng(a, b);
  }
}

class _Pin extends StatelessWidget {
  const _Pin({
    required this.color,
    required this.icon,
    required this.tooltip,
    this.pulse = false,
  });

  final Color color;
  final IconData icon;
  final String tooltip;
  final bool pulse;

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: tooltip,
      child: Container(
        decoration: BoxDecoration(
          color: color,
          shape: BoxShape.circle,
          border: Border.all(color: Colors.white, width: 2.5),
          boxShadow: [
            BoxShadow(
              color: color.withValues(alpha: pulse ? 0.55 : 0.35),
              blurRadius: pulse ? 12 : 6,
              spreadRadius: pulse ? 2 : 0,
            ),
          ],
        ),
        child: Icon(icon, color: Colors.white, size: 22),
      ),
    );
  }
}

class _LegendDot extends StatelessWidget {
  const _LegendDot({required this.color, required this.label});

  final Color color;
  final String label;

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: 10,
          height: 10,
          decoration: BoxDecoration(color: color, shape: BoxShape.circle),
        ),
        const SizedBox(width: 4),
        Text(label, style: const TextStyle(fontSize: 12)),
      ],
    );
  }
}
