import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/network/api_client.dart';
import '../../core/theme/app_theme.dart';
import '../../shared/utils/ugx_formatter.dart';
import '../../shared/widgets/error_view.dart';
import '../../shared/widgets/loading_view.dart';

/// Rider earnings, vehicle, safety, and online controls.
class RiderDashboardScreen extends ConsumerStatefulWidget {
  const RiderDashboardScreen({super.key});

  @override
  ConsumerState<RiderDashboardScreen> createState() => _RiderDashboardScreenState();
}

class _RiderDashboardScreenState extends ConsumerState<RiderDashboardScreen> {
  late Future<Map<String, dynamic>> _future;
  bool _busy = false;
  Timer? _poll;
  Map<String, dynamic>? _latest;

  @override
  void initState() {
    super.initState();
    _future = _load();
    _poll = Timer.periodic(const Duration(seconds: 5), (_) {
      if (!mounted) return;
      _silentReload();
    });
  }

  @override
  void dispose() {
    _poll?.cancel();
    super.dispose();
  }

  Future<Map<String, dynamic>> _load() async {
    try {
      final res = await ref.read(apiClientProvider).get('/dashboard/riders/me/earnings');
      final data = Map<String, dynamic>.from(res.data as Map);
      _latest = data;
      return data;
    } catch (_) {
      // Not enrolled yet — empty sentinel for onboarding CTA
      final data = {'status': 'NONE', 'enrolled': false};
      _latest = data;
      return data;
    }
  }

  Future<void> _silentReload() async {
    try {
      final data = await _load();
      if (!mounted) return;
      setState(() => _future = Future.value(data));
    } catch (_) {}
  }

  Future<void> _toggleOnline(bool online) async {
    setState(() => _busy = true);
    try {
      await ref.read(apiClientProvider).patch('/dashboard/riders/me/availability', data: {
        'available_delivery': online,
        'available_rides': online,
      });
      setState(() => _future = _load());
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('$e')));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Rider dashboard')),
      body: FutureBuilder(
        future: _future,
        builder: (context, snap) {
          if (snap.connectionState != ConnectionState.done) return const LoadingView();
          if (snap.hasError) {
            return ErrorView(
              message: '${snap.error}',
              onRetry: () => setState(() => _future = _load()),
            );
          }
          final d = snap.data!;
          final status = '${d['status'] ?? 'NONE'}'.toUpperCase();
          if (status != 'APPROVED') {
            return Padding(
              padding: const EdgeInsets.all(24),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  const Icon(Icons.verified_user_outlined, size: 56, color: AppTheme.accentGreen),
                  const SizedBox(height: 16),
                  Text(
                    status == 'NONE' || status == 'DRAFT'
                        ? 'Become a Wamu Rider'
                        : 'Verification: $status',
                    style: Theme.of(context).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w800),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    status == 'UNDER_REVIEW' || status == 'SUBMITTED'
                        ? 'Admin is reviewing your documents. You can deliver once approved.'
                        : status == 'NEEDS_REUPLOAD' || status == 'REJECTED'
                            ? 'Fix your documents and resubmit for review.'
                            : 'Register, upload ID / licence / insurance / selfie, then wait for admin approval.',
                  ),
                  const SizedBox(height: 20),
                  FilledButton(
                    onPressed: () => context.push('/rider/onboarding'),
                    style: FilledButton.styleFrom(
                      backgroundColor: AppTheme.accentGreen,
                      foregroundColor: Colors.black,
                    ),
                    child: Text(
                      status == 'NONE' || status == 'DRAFT'
                          ? 'Start registration'
                          : 'Open verification',
                    ),
                  ),
                ],
              ),
            );
          }
          final online = d['available_delivery'] == true;
          return ListView(
            padding: const EdgeInsets.all(16),
            children: [
              SwitchListTile(
                title: Text(online ? 'Online — accepting jobs' : 'Offline'),
                subtitle: const Text('Toggle delivery & ride availability'),
                value: online,
                activeThumbColor: Colors.black,
                activeTrackColor: AppTheme.accentGreen,
                onChanged: _busy ? null : _toggleOnline,
              ),
              const Divider(),
              ListTile(
                leading: const Icon(Icons.payments_outlined, color: AppTheme.accentGreen),
                title: const Text('Earnings'),
                subtitle: Text(
                  '${formatUgx((d['earnings_ugx'] as num?)?.toDouble() ?? 0)} · '
                  '${d['completed_deliveries'] ?? 0} completed',
                ),
              ),
              ListTile(
                leading: const Icon(Icons.star_outline, color: AppTheme.accentGreen),
                title: const Text('Ratings'),
                subtitle: Text('★ ${(d['rating'] as num?)?.toStringAsFixed(1) ?? '5.0'} · ${d['delivery_count'] ?? 0} deliveries'),
              ),
              ListTile(
                leading: const Icon(Icons.two_wheeler, color: AppTheme.accentGreen),
                title: const Text('Vehicle'),
                subtitle: Text('${d['vehicle_type'] ?? 'BODA'} · ${d['plate_number'] ?? 'No plate'}'),
                trailing: const Icon(Icons.edit),
                onTap: () => context.push('/rider/vehicle'),
              ),
              ListTile(
                leading: const Icon(Icons.verified_user_outlined, color: AppTheme.accentGreen),
                title: const Text('Documents / verification'),
                subtitle: Text('Status: ${d['status'] ?? '—'} · Wamu Verified'),
                trailing: const Icon(Icons.chevron_right),
                onTap: () => context.push('/rider/onboarding'),
              ),
              ListTile(
                leading: const Icon(Icons.history, color: AppTheme.accentGreen),
                title: const Text('Delivery history'),
                subtitle: const Text('Open jobs workbench'),
                onTap: () => context.push('/deliveries'),
              ),
              ListTile(
                leading: const Icon(Icons.map_outlined, color: AppTheme.accentGreen),
                title: const Text('Live map'),
                subtitle: const Text('Route, turn advice, Google Maps navigation'),
                onTap: () => context.push('/rider/live-map'),
              ),
              ListTile(
                leading: const Icon(Icons.health_and_safety_outlined, color: AppTheme.accentGreen),
                title: const Text('Safety / support'),
                subtitle: const Text('Help center & emergency tips'),
                onTap: () => context.push('/help'),
              ),
              ListTile(
                leading: const Icon(Icons.settings_outlined, color: AppTheme.accentGreen),
                title: const Text('Rider settings'),
                onTap: () => context.push('/rider/vehicle'),
              ),
              const SizedBox(height: 12),
              FilledButton(
                onPressed: () => context.push('/rider/live-map'),
                child: const Text('Open live map'),
              ),
              const SizedBox(height: 8),
              FilledButton(
                onPressed: () => context.push('/deliveries'),
                child: const Text('Open delivery workbench'),
              ),
            ],
          );
        },
      ),
    );
  }
}

class RiderVehicleScreen extends ConsumerStatefulWidget {
  const RiderVehicleScreen({super.key});

  @override
  ConsumerState<RiderVehicleScreen> createState() => _RiderVehicleScreenState();
}

class _RiderVehicleScreenState extends ConsumerState<RiderVehicleScreen> {
  final _name = TextEditingController();
  final _plate = TextEditingController();
  String _vehicle = 'BODA';
  bool _loading = true;
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _name.dispose();
    _plate.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    try {
      final res = await ref.read(apiClientProvider).get('/dashboard/riders/me/earnings');
      final d = Map<String, dynamic>.from(res.data as Map);
      _name.text = d['display_name']?.toString() ?? '';
      _plate.text = d['plate_number']?.toString() ?? '';
      _vehicle = d['vehicle_type']?.toString() ?? 'BODA';
    } catch (_) {}
    if (mounted) setState(() => _loading = false);
  }

  Future<void> _save() async {
    setState(() => _saving = true);
    try {
      await ref.read(apiClientProvider).patch('/dashboard/riders/me/vehicle', data: {
        'display_name': _name.text.trim(),
        'vehicle_type': _vehicle,
        'plate_number': _plate.text.trim(),
      });
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Vehicle updated')));
      context.pop();
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('$e')));
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Vehicle & settings')),
      body: _loading
          ? const LoadingView()
          : ListView(
              padding: const EdgeInsets.all(16),
              children: [
                TextField(controller: _name, decoration: const InputDecoration(labelText: 'Display name')),
                const SizedBox(height: 12),
                DropdownButtonFormField<String>(
                  initialValue: _vehicle,
                  items: const [
                    DropdownMenuItem(value: 'BODA', child: Text('Boda')),
                    DropdownMenuItem(value: 'CAR', child: Text('Car')),
                    DropdownMenuItem(value: 'BIKE', child: Text('Bike')),
                  ],
                  onChanged: (v) => setState(() => _vehicle = v ?? 'BODA'),
                  decoration: const InputDecoration(labelText: 'Vehicle type'),
                ),
                const SizedBox(height: 12),
                TextField(controller: _plate, decoration: const InputDecoration(labelText: 'Plate number')),
                const SizedBox(height: 20),
                FilledButton(
                  onPressed: _saving ? null : _save,
                  child: Text(_saving ? 'Saving…' : 'Save'),
                ),
              ],
            ),
    );
  }
}
