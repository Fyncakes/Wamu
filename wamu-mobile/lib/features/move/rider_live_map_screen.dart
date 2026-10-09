import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:geolocator/geolocator.dart';
import 'package:latlong2/latlong.dart';

import '../../core/theme/app_theme.dart';
import '../../shared/utils/maps_nav.dart';
import '../../shared/utils/osrm_route.dart';
import '../../shared/utils/ugx_formatter.dart';
import '../home/nearby_location.dart';
import 'riders_repository.dart';

/// Live map for an active delivery: heading-up route, next advice, Google Maps nav.
class RiderLiveMapScreen extends ConsumerStatefulWidget {
  const RiderLiveMapScreen({super.key, this.deliveryId});

  final String? deliveryId;

  @override
  ConsumerState<RiderLiveMapScreen> createState() => _RiderLiveMapScreenState();
}

class _RiderLiveMapScreenState extends ConsumerState<RiderLiveMapScreen> {
  final _map = MapController();
  Timer? _poll;
  StreamSubscription<Position>? _gps;
  Map<String, dynamic>? _job;
  OsrmRoute? _route;
  LatLng? _me;
  double? _heading;
  bool _busy = false;
  bool _follow = true;
  double _mapRotation = 0;
  String? _error;
  LatLng? _lastRouteFrom;
  LatLng? _lastRouteTo;
  double? _lastRouteHeading;
  DateTime? _lastRouteAt;

  static const _nextStatus = <String, String>{
    'REQUESTED': 'ACCEPTED',
    'ACCEPTED': 'GOING_TO_PICKUP',
    'GOING_TO_PICKUP': 'AT_PICKUP',
    'AT_PICKUP': 'PICKED_UP',
    'PICKED_UP': 'IN_TRANSIT',
    'IN_TRANSIT': 'DELIVERED',
  };

  @override
  void initState() {
    super.initState();
    _bootstrap();
  }

  @override
  void dispose() {
    _poll?.cancel();
    _gps?.cancel();
    _map.dispose();
    super.dispose();
  }

  Future<void> _bootstrap() async {
    await _reload();
    _poll = Timer.periodic(const Duration(seconds: 8), (_) => _reload());
    try {
      var perm = await Geolocator.checkPermission();
      if (perm == LocationPermission.denied) {
        perm = await Geolocator.requestPermission();
      }
      if (perm == LocationPermission.denied ||
          perm == LocationPermission.deniedForever) {
        return;
      }
      _gps = Geolocator.getPositionStream(
        locationSettings: const LocationSettings(
          accuracy: LocationAccuracy.bestForNavigation,
          distanceFilter: 5,
        ),
      ).listen((p) {
        final here = LatLng(p.latitude, p.longitude);
        if (!mounted) return;
        final headingOk = p.heading >= 0 && p.heading <= 360 && p.speed > 0.8;
        setState(() {
          _me = here;
          if (headingOk) _heading = p.heading;
        });
        _maybeFollowCamera(here);
        unawaited(
          ref.read(ridersRepositoryProvider).updateMyLocation(
                lat: p.latitude,
                lng: p.longitude,
              ),
        );
        unawaited(_refreshRoute());
      });
    } catch (_) {}
  }

  void _maybeFollowCamera(LatLng here) {
    if (!_follow) return;
    try {
      final zoom = _map.camera.zoom < 14.5 ? 16.4 : _map.camera.zoom;
      final h = _heading;
      if (h != null) {
        _map.moveAndRotate(here, zoom, h);
      } else {
        _map.move(here, zoom);
      }
    } catch (_) {}
  }

  Future<void> _reload() async {
    try {
      final rows = await ref.read(ridersRepositoryProvider).myDeliveries();
      Map<String, dynamic>? job;
      if (widget.deliveryId != null) {
        for (final r in rows) {
          if (r['id']?.toString() == widget.deliveryId) job = r;
        }
      }
      job ??= rows.where((r) {
        final s = (r['status']?.toString() ?? '').toUpperCase();
        return s != 'DELIVERED' && s != 'CANCELLED';
      }).firstOrNull;
      if (!mounted) return;
      setState(() {
        _job = job;
        _error = job == null ? 'No active delivery. Claim a job first.' : null;
      });
      await _refreshRoute(force: true);
    } catch (e) {
      if (mounted) setState(() => _error = '$e');
    }
  }

  bool get _toShop {
    final s = (_job?['status']?.toString() ?? '').toUpperCase();
    return s == 'ACCEPTED' || s == 'GOING_TO_PICKUP' || s == 'AT_PICKUP' || s == 'REQUESTED';
  }

  LatLng? _pt(dynamic lat, dynamic lng) {
    final a = parseCoord(lat);
    final b = parseCoord(lng);
    if (a == null || b == null) return null;
    return LatLng(a, b);
  }

  LatLng? get _dest {
    if (_job == null) return null;
    if (_toShop) return _pt(_job!['pickup_lat'], _job!['pickup_lng']);
    return _pt(_job!['dropoff_lat'], _job!['dropoff_lng']);
  }

  LatLng get _origin {
    if (_me != null) return _me!;
    final rider = _pt(_job?['rider_lat'], _job?['rider_lng']);
    if (rider != null) return rider;
    return const LatLng(kampalaFallbackLat, kampalaFallbackLng);
  }

  bool _needsNewRoute(LatLng from, LatLng dest) {
    if (_route == null || _lastRouteFrom == null || _lastRouteTo == null) return true;
    const dist = Distance();
    if (dist.as(LengthUnit.Meter, from, _lastRouteFrom!) > 35) return true;
    if (dist.as(LengthUnit.Meter, dest, _lastRouteTo!) > 12) return true;
    final h = _heading;
    if (h != null && _lastRouteHeading != null) {
      var diff = (h - _lastRouteHeading!).abs() % 360;
      if (diff > 180) diff = 360 - diff;
      if (diff > 28) return true;
    }
    final at = _lastRouteAt;
    if (at != null && DateTime.now().difference(at) > const Duration(seconds: 22)) {
      return true;
    }
    return false;
  }

  Future<void> _refreshRoute({bool force = false}) async {
    final dest = _dest;
    if (dest == null) return;
    final from = _origin;
    if (!force && !_needsNewRoute(from, dest)) return;
    final route = await fetchDrivingRoute(from, dest, headingDegrees: _heading);
    if (!mounted || route == null) return;
    setState(() {
      _route = route;
      _lastRouteFrom = from;
      _lastRouteTo = dest;
      _lastRouteHeading = _heading;
      _lastRouteAt = DateTime.now();
    });
  }

  String _statusAdvice(String status) {
    switch (status) {
      case 'ACCEPTED':
      case 'GOING_TO_PICKUP':
        return 'Ride to the shop. Follow the orange line.';
      case 'AT_PICKUP':
        return 'You are at the shop. Collect the parcel, then continue.';
      case 'PICKED_UP':
      case 'IN_TRANSIT':
        return 'Deliver to the customer. Stay on the route.';
      case 'DELIVERED':
        return 'Job complete. Nice work.';
      default:
        return 'Follow the highlighted route.';
    }
  }

  Future<void> _advance() async {
    final job = _job;
    if (job == null) return;
    final status = (job['status']?.toString() ?? '').toUpperCase();
    final next = _nextStatus[status];
    if (next == null) return;
    setState(() => _busy = true);
    try {
      await ref.read(ridersRepositoryProvider).advanceDelivery(
            job['id'].toString(),
            next,
            proofNote: next == 'DELIVERED' ? 'Handed to customer' : null,
            lat: _me?.latitude,
            lng: _me?.longitude,
          );
      await _reload();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('$e')));
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _openGoogleNav() async {
    final dest = _dest;
    await openMapsNavigation(
      lat: dest?.latitude,
      lng: dest?.longitude,
      originLat: _origin.latitude,
      originLng: _origin.longitude,
      address: _toShop
          ? (_job?['pickup_address']?.toString())
          : (_job?['dropoff_address']?.toString()),
      label: _toShop ? (_job?['shop_name']?.toString()) : 'Customer',
    );
  }

  @override
  Widget build(BuildContext context) {
    final job = _job;
    final status = (job?['status']?.toString() ?? '').toUpperCase();
    final dest = _dest;
    final pickup = job == null ? null : _pt(job['pickup_lat'], job['pickup_lng']);
    final dropoff = job == null ? null : _pt(job['dropoff_lat'], job['dropoff_lng']);
    final destLabel = _toShop
        ? (job?['shop_name']?.toString() ?? job?['pickup_address']?.toString() ?? 'Shop')
        : (job?['dropoff_address']?.toString() ?? 'Customer');
    final next = _nextStatus[status];
    final fee = job?['fee'];
    final feeLabel = fee is num ? formatUgx(fee.toDouble()) : (fee?.toString() ?? '');
    final advice = _route?.adviceAhead(_origin) ?? _statusAdvice(status);
    final line = _route?.remainingFrom(_origin) ??
        [
          _origin,
          ?dest,
        ];

    return Scaffold(
      body: Stack(
        children: [
          FlutterMap(
            mapController: _map,
            options: MapOptions(
              initialCenter: dest ?? _origin,
              initialZoom: 15.2,
              onPositionChanged: (camera, hasGesture) {
                _mapRotation = camera.rotation;
                if (hasGesture && _follow) {
                  setState(() => _follow = false);
                }
              },
              interactionOptions: const InteractionOptions(
                flags: InteractiveFlag.pinchZoom |
                    InteractiveFlag.drag |
                    InteractiveFlag.doubleTapZoom |
                    InteractiveFlag.rotate,
              ),
            ),
            children: [
              TileLayer(
                urlTemplate:
                    'https://basemaps.cartocdn.com/rastertiles/voyager/{z}/{x}/{y}.png',
                userAgentPackageName: 'ug.wamu.mobile',
              ),
              if (line.length >= 2)
                PolylineLayer(
                  polylines: [
                    Polyline(
                      points: line,
                      strokeWidth: 7,
                      color: const Color(0xFFE67E22),
                      borderStrokeWidth: 2,
                      borderColor: Colors.white,
                    ),
                  ],
                ),
              MarkerLayer(
                markers: [
                  if (pickup != null)
                    Marker(
                      point: pickup,
                      width: 160,
                      height: 36,
                      child: _FlagPin(
                        icon: Icons.storefront,
                        label: job?['shop_name']?.toString() ?? 'Shop',
                      ),
                    ),
                  if (dropoff != null)
                    Marker(
                      point: dropoff,
                      width: 160,
                      height: 36,
                      child: _FlagPin(
                        icon: Icons.person_pin_circle,
                        label: 'Customer',
                      ),
                    ),
                  Marker(
                    point: _origin,
                    width: 40,
                    height: 40,
                    alignment: Alignment.center,
                    child: Transform.rotate(
                      angle: ((_heading ?? 0) - _mapRotation) * math.pi / 180,
                      child: const Icon(
                        Icons.navigation,
                        color: Color(0xFF1A73E8),
                        size: 36,
                        shadows: [Shadow(color: Colors.white, blurRadius: 8)],
                      ),
                    ),
                  ),
                ],
              ),
            ],
          ),
          SafeArea(
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Row(
                children: [
                  CircleAvatar(
                    backgroundColor: Colors.white,
                    child: IconButton(
                      icon: const Icon(Icons.arrow_back, color: Colors.black87),
                      onPressed: () => Navigator.pop(context),
                    ),
                  ),
                  const Spacer(),
                  CircleAvatar(
                    backgroundColor: Colors.white,
                    child: IconButton(
                      tooltip: 'Recenter on you',
                      icon: Icon(
                        _follow ? Icons.my_location : Icons.location_searching,
                        color: const Color(0xFF1A73E8),
                      ),
                      onPressed: () {
                        setState(() => _follow = true);
                        _maybeFollowCamera(_origin);
                      },
                    ),
                  ),
                ],
              ),
            ),
          ),
          Align(
            alignment: Alignment.bottomCenter,
            child: Material(
              color: Theme.of(context).scaffoldBackgroundColor,
              borderRadius: const BorderRadius.vertical(top: Radius.circular(20)),
              child: SafeArea(
                top: false,
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(16, 10, 16, 16),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Center(
                        child: Container(
                          width: 40,
                          height: 4,
                          margin: const EdgeInsets.only(bottom: 12),
                          decoration: BoxDecoration(
                            color: Colors.grey.shade400,
                            borderRadius: BorderRadius.circular(2),
                          ),
                        ),
                      ),
                      if (_error != null)
                        Text(_error!, style: const TextStyle(fontWeight: FontWeight.w600))
                      else ...[
                        Container(
                          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                          decoration: BoxDecoration(
                            color: const Color(0xFFE67E22),
                            borderRadius: BorderRadius.circular(10),
                          ),
                          child: Row(
                            children: [
                              Icon(
                                _toShop ? Icons.storefront : Icons.flag,
                                color: Colors.white,
                                size: 18,
                              ),
                              const SizedBox(width: 8),
                              Expanded(
                                child: Text(
                                  destLabel,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: const TextStyle(
                                    color: Colors.white,
                                    fontWeight: FontWeight.w800,
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ),
                        const SizedBox(height: 10),
                        Text(
                          advice,
                          style: const TextStyle(
                            fontSize: 18,
                            fontWeight: FontWeight.w800,
                            height: 1.25,
                          ),
                        ),
                        const SizedBox(height: 6),
                        Text(
                          [
                            if (status.isNotEmpty) status.replaceAll('_', ' '),
                            if (_route != null) '${_route!.distanceLabel} · ${_route!.etaLabel}',
                            if (feeLabel.isNotEmpty) feeLabel,
                          ].join(' · '),
                          style: TextStyle(color: Colors.grey.shade600, fontWeight: FontWeight.w600),
                        ),
                        const SizedBox(height: 8),
                        Text(
                          _statusAdvice(status),
                          style: TextStyle(color: Colors.grey.shade700),
                        ),
                        const SizedBox(height: 14),
                        Row(
                          children: [
                            Expanded(
                              child: OutlinedButton.icon(
                                onPressed: dest == null ? null : _openGoogleNav,
                                icon: const Icon(Icons.navigation),
                                label: const Text('Google Maps'),
                              ),
                            ),
                            const SizedBox(width: 10),
                            if (next != null)
                              Expanded(
                                child: FilledButton(
                                  onPressed: _busy ? null : _advance,
                                  style: FilledButton.styleFrom(
                                    backgroundColor: AppTheme.accentGreen,
                                    foregroundColor: Colors.black,
                                  ),
                                  child: Text(
                                    next == 'DELIVERED' ? 'Delivered' : 'Next: ${next.replaceAll('_', ' ')}',
                                    textAlign: TextAlign.center,
                                  ),
                                ),
                              ),
                          ],
                        ),
                      ],
                    ],
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _FlagPin extends StatelessWidget {
  const _FlagPin({required this.icon, required this.label});

  final IconData icon;
  final String label;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8),
      decoration: BoxDecoration(
        color: const Color(0xFFE67E22),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, color: Colors.white, size: 14),
          const SizedBox(width: 4),
          Flexible(
            child: Text(
              label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(color: Colors.white, fontSize: 11, fontWeight: FontWeight.w800),
            ),
          ),
        ],
      ),
    );
  }
}
