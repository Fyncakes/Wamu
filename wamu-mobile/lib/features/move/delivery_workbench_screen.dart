import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:go_router/go_router.dart';

import '../../core/theme/app_theme.dart';
import '../../shared/utils/maps_nav.dart';
import '../../shared/utils/ugx_formatter.dart';
import '../../shared/widgets/error_view.dart';
import '../../shared/widgets/loading_view.dart';
import '../home/nearby_location.dart';
import 'riders_repository.dart';
import 'rides_repository.dart';

/// Delivery workbench — advance assigned deliveries (Master Plan MVP).
class DeliveryWorkbenchScreen extends ConsumerStatefulWidget {
  const DeliveryWorkbenchScreen({super.key});

  @override
  ConsumerState<DeliveryWorkbenchScreen> createState() => _DeliveryWorkbenchScreenState();
}

class _DeliveryWorkbenchScreenState extends ConsumerState<DeliveryWorkbenchScreen>
    with WidgetsBindingObserver {
  late Future<_WorkbenchData> _future;
  bool _busy = false;
  bool _live = false;
  Timer? _poll;
  final Set<String> _seenOpenIds = {};
  bool _openJobsSeeded = false;

  static const _nextStatus = <String, String>{
    'REQUESTED': 'ACCEPTED',
    'ACCEPTED': 'GOING_TO_PICKUP',
    'GOING_TO_PICKUP': 'AT_PICKUP',
    'AT_PICKUP': 'PICKED_UP',
    'PICKED_UP': 'IN_TRANSIT',
    'IN_TRANSIT': 'DELIVERED',
  };

  static const _nextRideStatus = <String, String>{
    'ACCEPTED': 'IN_TRANSIT',
    'IN_TRANSIT': 'COMPLETED',
  };

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _future = _load().then((data) {
      _schedulePoll(data);
      return data;
    });
  }

  @override
  void dispose() {
    _poll?.cancel();
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) _reload();
  }

  Future<_WorkbenchData> _load() async {
    final repo = ref.read(ridersRepositoryProvider);
    Map<String, dynamic>? profile;
    try {
      profile = await repo.myRiderProfile();
    } catch (_) {
      profile = null;
    }
    if (profile == null) {
      return const _WorkbenchData(
        profile: null,
        deliveries: [],
        open: [],
        rides: [],
      );
    }
    // Push live GPS so customer tracking uses the rider phone, not a simulated path.
    unawaited(_pushLiveLocation());
    final deliveries = await repo.myDeliveries();
    List<Map<String, dynamic>> open = [];
    try {
      open = await repo.openDeliveries();
    } catch (_) {
      open = [];
    }
    List<Map<String, dynamic>> rides = [];
    try {
      rides = await ref.read(ridesRepositoryProvider).myRidesAsRider();
    } catch (_) {
      rides = [];
    }
    return _WorkbenchData(
      profile: profile,
      deliveries: deliveries,
      open: open,
      rides: rides,
    );
  }

  void _alertNewOpenJobs(List<Map<String, dynamic>> open) {
    final ids = <String>{
      for (final d in open)
        if ((d['id']?.toString() ?? '').isNotEmpty) d['id'].toString(),
    };
    if (!_openJobsSeeded) {
      _seenOpenIds.addAll(ids);
      _openJobsSeeded = true;
      return;
    }
    final fresh = ids.difference(_seenOpenIds);
    _seenOpenIds
      ..clear()
      ..addAll(ids);
    if (fresh.isEmpty || !mounted) return;
    final count = fresh.length;
    ScaffoldMessenger.of(context).clearSnackBars();
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          count == 1
              ? 'New delivery job available — claim it below'
              : '$count new delivery jobs available',
        ),
        backgroundColor: AppTheme.accentGreen.withValues(alpha: 0.95),
        duration: const Duration(seconds: 6),
      ),
    );
  }

  Future<({double lat, double lng})?> _currentGps() async {
    final origin = await resolveNearbyOrigin(preferGps: true);
    if (!origin.fromGps) return null;
    return (lat: origin.lat, lng: origin.lng);
  }

  Future<void> _pushLiveLocation() async {
    try {
      final gps = await _currentGps();
      if (gps == null) return;
      await ref.read(ridersRepositoryProvider).updateMyLocation(
            lat: gps.lat,
            lng: gps.lng,
          );
    } catch (_) {
      // Location is best-effort; workbench still works without it.
    }
  }

  void _reload() => setState(() {
        _future = _load().then((data) {
          _schedulePoll(data);
          return data;
        });
      });

  void _schedulePoll(_WorkbenchData data) {
    _poll?.cancel();
    // Always poll while the workbench is open so the first open job is not missed.
    final live = data.profile != null;
    if (mounted) setState(() => _live = live);
    _alertNewOpenJobs(data.open);
    if (!live) return;
    _poll = Timer.periodic(const Duration(seconds: 5), (_) {
      if (!mounted) return;
      _reload();
    });
  }

  Future<void> _claim(Map<String, dynamic> delivery) async {
    final id = delivery['id']?.toString();
    if (id == null) return;
    setState(() => _busy = true);
    try {
      await _pushLiveLocation();
      await ref.read(ridersRepositoryProvider).claimDelivery(id);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Delivery claimed')),
        );
        _reload();
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('$e')));
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _enroll() async {
    if (!mounted) return;
    await context.push('/rider/onboarding');
    if (mounted) _reload();
  }

  Future<void> _advance(Map<String, dynamic> delivery) async {
    final id = delivery['id']?.toString();
    final status = (delivery['status']?.toString() ?? '').toUpperCase();
    final next = _nextStatus[status];
    if (id == null || next == null) return;

    String? proofNote;
    if (next == 'DELIVERED') {
      final ctrl = TextEditingController(text: 'Handed to customer');
      final ok = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('Proof of delivery'),
          content: TextField(
            controller: ctrl,
            autofocus: true,
            decoration: const InputDecoration(
              hintText: 'e.g. Handed to customer / left at gate',
            ),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
            FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Complete')),
          ],
        ),
      );
      proofNote = ctrl.text.trim();
      ctrl.dispose();
      if (ok != true || proofNote.length < 3 || !mounted) return;
    }

    setState(() => _busy = true);
    try {
      final gps = await _currentGps();
      await ref.read(ridersRepositoryProvider).advanceDelivery(
            id,
            next,
            proofNote: proofNote,
            lat: gps?.lat,
            lng: gps?.lng,
          );
      if (mounted) _reload();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('$e')));
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _advanceRide(Map<String, dynamic> ride) async {
    final id = ride['id']?.toString();
    final status = (ride['status']?.toString() ?? '').toUpperCase();
    final next = _nextRideStatus[status];
    if (id == null || next == null) return;
    setState(() => _busy = true);
    try {
      await ref.read(ridesRepositoryProvider).advanceRide(id, next);
      if (mounted) _reload();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('$e')));
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Deliveries'),
        actions: [
          if (_live)
            const Padding(
              padding: EdgeInsets.only(right: 12),
              child: Center(
                child: Row(
                  children: [
                    Icon(Icons.sensors, size: 16),
                    SizedBox(width: 4),
                    Text('Live', style: TextStyle(fontSize: 12, fontWeight: FontWeight.w700)),
                  ],
                ),
              ),
            ),
          IconButton(
            tooltip: 'Refresh',
            onPressed: _busy ? null : _reload,
            icon: const Icon(Icons.refresh),
          ),
        ],
      ),
      body: FutureBuilder<_WorkbenchData>(
        future: _future,
        builder: (context, snapshot) {
          if (snapshot.connectionState == ConnectionState.waiting && !snapshot.hasData) {
            return const LoadingView(message: 'Loading deliveries…');
          }
          if (snapshot.hasError && !snapshot.hasData) {
            return ErrorView(message: '${snapshot.error}', onRetry: _reload);
          }
          final data = snapshot.data!;
          if (data.profile == null) {
            return Center(
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Icon(Icons.delivery_dining, size: 56, color: AppTheme.accentGreen),
                    const SizedBox(height: 12),
                    Text(
                      'Deliver for Wamu',
                      style: Theme.of(context).textTheme.titleLarge,
                    ),
                    const SizedBox(height: 8),
                    const Text(
                      'Complete rider registration, upload ID / licence / insurance, '
                      'and wait for Wamu admin verification.',
                      textAlign: TextAlign.center,
                    ),
                    const SizedBox(height: 20),
                    FilledButton(
                      onPressed: _busy ? null : _enroll,
                      style: FilledButton.styleFrom(
                        backgroundColor: AppTheme.accentGreen,
                        foregroundColor: Colors.black,
                      ),
                      child: const Text('Become a Wamu Rider'),
                    ),
                  ],
                ),
              ),
            );
          }

          final riderStatus = (data.profile!['status']?.toString() ?? '').toUpperCase();
          if (riderStatus != 'APPROVED') {
            return Center(
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(
                      riderStatus == 'SUSPENDED' ? Icons.block : Icons.verified_user_outlined,
                      size: 56,
                      color: AppTheme.accentGreen,
                    ),
                    const SizedBox(height: 12),
                    Text(
                      'Rider status: $riderStatus',
                      style: Theme.of(context).textTheme.titleLarge,
                      textAlign: TextAlign.center,
                    ),
                    const SizedBox(height: 8),
                    Text(
                      riderStatus == 'NEEDS_REUPLOAD' || riderStatus == 'REJECTED' || riderStatus == 'DRAFT'
                          ? 'Continue your verification application to unlock deliveries.'
                          : 'Admin is reviewing your documents. You will unlock deliveries when approved.',
                      textAlign: TextAlign.center,
                    ),
                    const SizedBox(height: 20),
                    FilledButton(
                      onPressed: () => context.push('/rider/onboarding'),
                      style: FilledButton.styleFrom(
                        backgroundColor: AppTheme.accentGreen,
                        foregroundColor: Colors.black,
                      ),
                      child: const Text('Open verification'),
                    ),
                  ],
                ),
              ),
            );
          }

          final active = data.deliveries
              .where((d) {
                final s = (d['status']?.toString() ?? '').toUpperCase();
                return s != 'DELIVERED' && s != 'CANCELLED';
              })
              .toList();
          final done = data.deliveries
              .where((d) => (d['status']?.toString() ?? '').toUpperCase() == 'DELIVERED')
              .toList();
          final activeRides = data.rides
              .where((r) {
                final s = (r['status']?.toString() ?? '').toUpperCase();
                return s != 'COMPLETED' && s != 'CANCELLED';
              })
              .toList();

          return RefreshIndicator(
            onRefresh: () async => _reload(),
            child: ListView(
              padding: const EdgeInsets.all(16),
              children: [
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  leading: const CircleAvatar(
                    backgroundColor: AppTheme.accentGreen,
                    child: Icon(Icons.two_wheeler, color: Colors.black),
                  ),
                  title: Text(data.profile!['display_name']?.toString() ?? 'Rider'),
                  subtitle: Text(
                    '${data.profile!['wamu_rider_ref'] ?? ''} · '
                    '${data.profile!['vehicle_type'] ?? 'BODA'}',
                  ),
                ),
                const SizedBox(height: 8),
                if (activeRides.isNotEmpty) ...[
                  Text(
                    'Passenger rides (${activeRides.length})',
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                  const SizedBox(height: 8),
                  ...activeRides.map((r) {
                    final status = (r['status']?.toString() ?? '').toUpperCase();
                    final next = _nextRideStatus[status];
                    final fare = r['fare'];
                    final fareLabel = fare is num ? formatUgx(fare.toDouble()) : '$fare';
                    return Card(
                      color: Colors.blueGrey.withValues(alpha: 0.08),
                      child: ListTile(
                        title: Text(status),
                        subtitle: Text(
                          '${r['pickup_address'] ?? 'Pickup'} → ${r['dropoff_address'] ?? 'Dropoff'}\n'
                          'Fare $fareLabel',
                        ),
                        isThreeLine: true,
                        trailing: next == null || _busy
                            ? null
                            : FilledButton(
                                onPressed: () => _advanceRide(r),
                                child: Text(next == 'COMPLETED' ? 'Complete' : 'Start trip'),
                              ),
                      ),
                    );
                  }),
                  const SizedBox(height: 16),
                ],
                if (data.open.isNotEmpty) ...[
                  Text(
                    'Open jobs (${data.open.length})',
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                  const SizedBox(height: 8),
                  ...data.open.map((d) {
                    final fee = d['fee'];
                    final feeLabel = fee is num ? formatUgx(fee.toDouble()) : '$fee';
                    final shopName = d['shop_name']?.toString();
                    return Card(
                      color: AppTheme.accentGreen.withValues(alpha: 0.08),
                      child: Padding(
                        padding: const EdgeInsets.fromLTRB(12, 12, 12, 8),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            const Text('REQUESTED', style: TextStyle(fontWeight: FontWeight.w800)),
                            Text(
                              '${shopName != null && shopName.isNotEmpty ? '$shopName · ' : ''}'
                              '${d['pickup_address'] ?? 'Pickup'} → ${d['dropoff_address'] ?? 'Dropoff'}',
                            ),
                            Text('Fee $feeLabel'),
                            const SizedBox(height: 8),
                            Wrap(
                              spacing: 8,
                              children: [
                                OutlinedButton.icon(
                                  onPressed: () => openMapsNavigation(
                                    lat: parseCoord(d['pickup_lat']),
                                    lng: parseCoord(d['pickup_lng']),
                                    address: d['pickup_address']?.toString(),
                                  ),
                                  icon: const Icon(Icons.storefront, size: 18),
                                  label: const Text('Preview shop map'),
                                ),
                                if (!_busy)
                                  FilledButton(
                                    onPressed: () => _claim(d),
                                    style: FilledButton.styleFrom(
                                      backgroundColor: AppTheme.accentGreen,
                                      foregroundColor: Colors.black,
                                    ),
                                    child: const Text('Claim'),
                                  ),
                              ],
                            ),
                          ],
                        ),
                      ),
                    );
                  }),
                  const SizedBox(height: 16),
                ],
                Text('Active', style: Theme.of(context).textTheme.titleMedium),
                const SizedBox(height: 8),
                if (active.isEmpty)
                  const Padding(
                    padding: EdgeInsets.symmetric(vertical: 24),
                    child: Text(
                      'No active deliveries — claim an open job above, or wait for auto-assign.',
                    ),
                  )
                else
                  ...active.map((d) {
                    final status = (d['status']?.toString() ?? '').toUpperCase();
                    final next = _nextStatus[status];
                    final fee = d['fee'];
                    final feeLabel = fee is num ? formatUgx(fee.toDouble()) : '$fee';
                    final toShop = status == 'ACCEPTED' ||
                        status == 'GOING_TO_PICKUP' ||
                        status == 'AT_PICKUP';
                    final shopName = d['shop_name']?.toString();
                    return Card(
                      child: Padding(
                        padding: const EdgeInsets.fromLTRB(12, 12, 12, 8),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(status, style: const TextStyle(fontWeight: FontWeight.w800)),
                            const SizedBox(height: 4),
                            Text(
                              '${shopName != null && shopName.isNotEmpty ? '$shopName · ' : ''}'
                              '${d['pickup_address'] ?? 'Shop'} → ${d['dropoff_address'] ?? 'Customer'}',
                            ),
                            Text('Fee $feeLabel'),
                            if (d['eta_minutes'] != null)
                              Text('ETA ~${d['eta_minutes']} min'),
                            const SizedBox(height: 10),
                            Wrap(
                              spacing: 8,
                              runSpacing: 8,
                              children: [
                                FilledButton.tonalIcon(
                                  onPressed: () => context.push(
                                    '/rider/live-map?deliveryId=${Uri.encodeQueryComponent(d['id'].toString())}',
                                  ),
                                  icon: const Icon(Icons.map, size: 18),
                                  label: const Text('Live map'),
                                ),
                                if (toShop)
                                  OutlinedButton.icon(
                                    onPressed: () => openMapsNavigation(
                                      lat: parseCoord(d['pickup_lat']),
                                      lng: parseCoord(d['pickup_lng']),
                                      address: d['pickup_address']?.toString(),
                                      label: shopName,
                                    ),
                                    icon: const Icon(Icons.storefront, size: 18),
                                    label: const Text('Map to shop'),
                                  ),
                                if (!toShop ||
                                    status == 'PICKED_UP' ||
                                    status == 'IN_TRANSIT' ||
                                    status == 'AT_PICKUP')
                                  OutlinedButton.icon(
                                    onPressed: () => openMapsNavigation(
                                      lat: parseCoord(d['dropoff_lat']),
                                      lng: parseCoord(d['dropoff_lng']),
                                      address: d['dropoff_address']?.toString(),
                                      label: 'Customer',
                                    ),
                                    icon: const Icon(Icons.person_pin_circle, size: 18),
                                    label: const Text('Map to customer'),
                                  ),
                                if (next != null && !_busy)
                                  FilledButton(
                                    onPressed: () => _advance(d),
                                    child: Text(
                                      next == 'DELIVERED' ? 'Delivered' : 'Mark $next',
                                    ),
                                  ),
                              ],
                            ),
                          ],
                        ),
                      ),
                    );
                  }),
                if (done.isNotEmpty) ...[
                  const SizedBox(height: 20),
                  Text('Completed', style: Theme.of(context).textTheme.titleMedium),
                  const SizedBox(height: 8),
                  ...done.take(10).map(
                        (d) => ListTile(
                          dense: true,
                          title: Text(d['dropoff_address']?.toString() ?? 'Delivery'),
                          subtitle: Text(d['status']?.toString() ?? ''),
                        ),
                      ),
                ],
              ],
            ),
          );
        },
      ),
    );
  }
}

class _WorkbenchData {
  const _WorkbenchData({
    required this.profile,
    required this.deliveries,
    required this.open,
    this.rides = const [],
  });

  final Map<String, dynamic>? profile;
  final List<Map<String, dynamic>> deliveries;
  final List<Map<String, dynamic>> open;
  final List<Map<String, dynamic>> rides;
}
