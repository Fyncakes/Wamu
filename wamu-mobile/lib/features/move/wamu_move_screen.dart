import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/theme/app_theme.dart';
import '../../shared/utils/ugx_formatter.dart';
import 'rides_repository.dart';

/// Passenger Move — thin Phase 5 MVP (Kampala boda request + status).
class WamuMoveScreen extends ConsumerStatefulWidget {
  const WamuMoveScreen({super.key});

  @override
  ConsumerState<WamuMoveScreen> createState() => _WamuMoveScreenState();
}

class _WamuMoveScreenState extends ConsumerState<WamuMoveScreen> {
  final _pickupCtrl = TextEditingController(text: 'Ntinda market');
  final _dropoffCtrl = TextEditingController(text: 'Nakawa trading centre');
  bool _busy = false;
  Map<String, dynamic>? _active;
  List<Map<String, dynamic>> _history = [];

  @override
  void initState() {
    super.initState();
    _refreshHistory();
  }

  @override
  void dispose() {
    _pickupCtrl.dispose();
    _dropoffCtrl.dispose();
    super.dispose();
  }

  Future<void> _refreshHistory() async {
    try {
      final rows = await ref.read(ridesRepositoryProvider).myRides();
      if (!mounted) return;
      Map<String, dynamic>? active;
      for (final r in rows) {
        final s = (r['status']?.toString() ?? '').toUpperCase();
        if (s != 'COMPLETED' && s != 'CANCELLED') {
          active = r;
          break;
        }
      }
      setState(() {
        _history = rows;
        _active = active;
      });
    } catch (_) {}
  }

  Future<void> _request() async {
    final pickup = _pickupCtrl.text.trim();
    final dropoff = _dropoffCtrl.text.trim();
    if (pickup.length < 4 || dropoff.length < 4) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Enter pickup and drop-off addresses')),
      );
      return;
    }
    setState(() => _busy = true);
    try {
      final ride = await ref.read(ridesRepositoryProvider).requestRide(
            pickupAddress: pickup,
            dropoffAddress: dropoff,
          );
      if (!mounted) return;
      setState(() => _active = ride);
      await _refreshHistory();
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            'Ride ${(ride['status'] ?? '').toString()} · '
            '${formatUgx(double.tryParse('${ride['fare']}') ?? 0)}',
          ),
        ),
      );
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('$e')));
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _cancelActive() async {
    final id = _active?['id']?.toString();
    if (id == null) return;
    setState(() => _busy = true);
    try {
      await ref.read(ridesRepositoryProvider).advanceRide(id, 'CANCELLED');
      await _refreshHistory();
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
    final rider = _active?['rider'] as Map?;
    final riderName = rider?['display_name']?.toString();
    return Scaffold(
      appBar: AppBar(title: const Text('Request a ride')),
      body: ListView(
        padding: const EdgeInsets.all(20),
        children: [
          Text(
            'Kampala boda — flat estimate, rider network from deliveries.',
            style: Theme.of(context).textTheme.bodyMedium,
          ),
          const SizedBox(height: 16),
          TextField(
            controller: _pickupCtrl,
            decoration: const InputDecoration(
              labelText: 'Pickup',
              hintText: 'Parish / landmark',
            ),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _dropoffCtrl,
            decoration: const InputDecoration(
              labelText: 'Drop-off',
              hintText: 'Where are you going?',
            ),
          ),
          const SizedBox(height: 16),
          FilledButton(
            onPressed: _busy ? null : _request,
            style: FilledButton.styleFrom(
              backgroundColor: AppTheme.accentGreen,
              foregroundColor: Colors.black,
              minimumSize: const Size(double.infinity, 48),
            ),
            child: Text(
              _busy ? 'Requesting…' : 'Request boda',
              style: const TextStyle(fontWeight: FontWeight.w800),
            ),
          ),
          if (_active != null) ...[
            const SizedBox(height: 24),
            Text('Active ride', style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 8),
            ListTile(
              contentPadding: EdgeInsets.zero,
              title: Text('${_active!['status']} · ${formatUgx(double.tryParse('${_active!['fare']}') ?? 0)}'),
              subtitle: Text(
                '${_active!['pickup_address']} → ${_active!['dropoff_address']}'
                '${riderName != null ? '\nRider: $riderName' : ''}',
              ),
              isThreeLine: riderName != null,
              trailing: (_active!['status']?.toString().toUpperCase() == 'COMPLETED' ||
                      _active!['status']?.toString().toUpperCase() == 'CANCELLED')
                  ? null
                  : TextButton(
                      onPressed: _busy ? null : _cancelActive,
                      child: const Text('Cancel'),
                    ),
            ),
          ],
          if (_history.isNotEmpty) ...[
            const SizedBox(height: 24),
            Text('Recent', style: Theme.of(context).textTheme.titleMedium),
            ..._history.take(8).map((r) {
              return ListTile(
                contentPadding: EdgeInsets.zero,
                title: Text('${r['status']} · ${formatUgx(double.tryParse('${r['fare']}') ?? 0)}'),
                subtitle: Text('${r['pickup_address']} → ${r['dropoff_address']}'),
              );
            }),
          ],
        ],
      ),
    );
  }
}
