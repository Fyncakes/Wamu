import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/network/api_client.dart';
import '../../core/theme/app_theme.dart';
import '../../shared/utils/ugx_formatter.dart';
import '../../shared/widgets/error_view.dart';
import '../../shared/widgets/loading_view.dart';

/// Business overview — sales snapshot for the owner hub.
class BusinessOverviewScreen extends ConsumerStatefulWidget {
  const BusinessOverviewScreen({super.key});

  @override
  ConsumerState<BusinessOverviewScreen> createState() => _BusinessOverviewScreenState();
}

class _BusinessOverviewScreenState extends ConsumerState<BusinessOverviewScreen> {
  late Future<Map<String, dynamic>> _future;

  @override
  void initState() {
    super.initState();
    _future = _load();
  }

  Future<Map<String, dynamic>> _load() async {
    final res = await ref.read(apiClientProvider).get('/dashboard/business/overview');
    return Map<String, dynamic>.from(res.data as Map);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Sales report')),
      body: FutureBuilder(
        future: _future,
        builder: (context, snap) {
          if (snap.connectionState != ConnectionState.done) return const LoadingView();
          if (snap.hasError) {
            return ErrorView(message: '${snap.error}', onRetry: () => setState(() => _future = _load()));
          }
          final d = snap.data!;
          final byStatus = Map<String, dynamic>.from(d['orders_by_status'] as Map? ?? {});
          return RefreshIndicator(
            onRefresh: () async => setState(() => _future = _load()),
            child: ListView(
              padding: const EdgeInsets.all(16),
              children: [
                Text(d['name']?.toString() ?? 'Shop', style: Theme.of(context).textTheme.headlineSmall),
                const SizedBox(height: 4),
                Text('Verification: ${d['verification_status'] ?? '—'}'),
                const SizedBox(height: 16),
                Wrap(
                  spacing: 10,
                  runSpacing: 10,
                  children: [
                    _StatChip('GMV', formatUgx((d['gmv_ugx'] as num?)?.toDouble() ?? 0)),
                    _StatChip('Paid', formatUgx((d['paid_ugx'] as num?)?.toDouble() ?? 0)),
                    _StatChip('Earnings', formatUgx((d['earnings_ugx'] as num?)?.toDouble() ?? 0)),
                    _StatChip('Orders', '${d['orders_total'] ?? 0}'),
                    _StatChip('Products', '${d['product_count'] ?? 0}'),
                    _StatChip('Reviews', '${d['review_count'] ?? 0} ★${(d['rating'] as num?)?.toStringAsFixed(1) ?? '0'}'),
                  ],
                ),
                if (d['promo_text'] != null) ...[
                  const SizedBox(height: 16),
                  Card(
                    color: AppTheme.accentGreen.withValues(alpha: 0.12),
                    child: ListTile(
                      leading: const Icon(Icons.campaign, color: AppTheme.accentGreen),
                      title: const Text('Active promo'),
                      subtitle: Text('${d['promo_text']}'),
                    ),
                  ),
                ],
                const SizedBox(height: 20),
                Text('Orders by status', style: Theme.of(context).textTheme.titleMedium),
                const SizedBox(height: 8),
                ...byStatus.entries.map(
                  (e) => ListTile(
                    dense: true,
                    title: Text(e.key),
                    trailing: Text('${e.value}', style: const TextStyle(fontWeight: FontWeight.w800)),
                  ),
                ),
                const SizedBox(height: 12),
                FilledButton(
                  onPressed: () => context.push('/business-owner/orders'),
                  child: const Text('Open orders'),
                ),
              ],
            ),
          );
        },
      ),
    );
  }
}

class _StatChip extends StatelessWidget {
  const _StatChip(this.label, this.value);
  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 150,
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(14),
        color: Theme.of(context).colorScheme.surfaceContainerHighest,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label, style: Theme.of(context).textTheme.bodySmall),
          const SizedBox(height: 4),
          Text(value, style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 15)),
        ],
      ),
    );
  }
}

class BusinessCustomersScreen extends ConsumerStatefulWidget {
  const BusinessCustomersScreen({super.key});

  @override
  ConsumerState<BusinessCustomersScreen> createState() => _BusinessCustomersScreenState();
}

class _BusinessCustomersScreenState extends ConsumerState<BusinessCustomersScreen> {
  late Future<List<Map<String, dynamic>>> _future;

  @override
  void initState() {
    super.initState();
    _future = _load();
  }

  Future<List<Map<String, dynamic>>> _load() async {
    final res = await ref.read(apiClientProvider).get('/dashboard/business/customers');
    final data = res.data;
    if (data is List) {
      return data.whereType<Map>().map((e) => Map<String, dynamic>.from(e)).toList();
    }
    return [];
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Customers')),
      body: FutureBuilder(
        future: _future,
        builder: (context, snap) {
          if (snap.connectionState != ConnectionState.done) return const LoadingView();
          if (snap.hasError) {
            return ErrorView(message: '${snap.error}', onRetry: () => setState(() => _future = _load()));
          }
          final items = snap.data ?? [];
          if (items.isEmpty) return const Center(child: Text('No customers yet'));
          return ListView.builder(
            itemCount: items.length,
            itemBuilder: (context, i) {
              final c = items[i];
              return ListTile(
                leading: const CircleAvatar(child: Icon(Icons.person)),
                title: Text(c['name']?.toString() ?? 'Customer', style: const TextStyle(fontWeight: FontWeight.w700)),
                subtitle: Text('${c['phone'] ?? ''} · ${c['orders']} orders'),
                trailing: Text(formatUgx((c['spent_ugx'] as num?)?.toDouble() ?? 0)),
              );
            },
          );
        },
      ),
    );
  }
}

class BusinessStaffScreen extends ConsumerStatefulWidget {
  const BusinessStaffScreen({super.key});

  @override
  ConsumerState<BusinessStaffScreen> createState() => _BusinessStaffScreenState();
}

class _BusinessStaffScreenState extends ConsumerState<BusinessStaffScreen> {
  late Future<List<Map<String, dynamic>>> _future;
  final _phone = TextEditingController();

  @override
  void initState() {
    super.initState();
    _future = _load();
  }

  @override
  void dispose() {
    _phone.dispose();
    super.dispose();
  }

  Future<List<Map<String, dynamic>>> _load() async {
    final res = await ref.read(apiClientProvider).get('/dashboard/business/staff');
    final data = res.data;
    if (data is List) {
      return data.whereType<Map>().map((e) => Map<String, dynamic>.from(e)).toList();
    }
    return [];
  }

  Future<void> _add() async {
    final phone = _phone.text.trim();
    if (phone.isEmpty) return;
    try {
      await ref.read(apiClientProvider).post('/dashboard/business/staff', data: {
        'phone': phone.startsWith('+') ? phone : '+256${phone.replaceAll(RegExp(r'^0'), '')}',
        'role': 'STAFF',
      });
      _phone.clear();
      setState(() => _future = _load());
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('$e')));
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Staff / accounts')),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.all(16),
            child: Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _phone,
                    decoration: const InputDecoration(
                      labelText: 'Staff phone (+256…)',
                      border: OutlineInputBorder(),
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                FilledButton(onPressed: _add, child: const Text('Add')),
              ],
            ),
          ),
          Expanded(
            child: FutureBuilder(
              future: _future,
              builder: (context, snap) {
                if (snap.connectionState != ConnectionState.done) return const LoadingView();
                if (snap.hasError) {
                  return ErrorView(message: '${snap.error}', onRetry: () => setState(() => _future = _load()));
                }
                final items = snap.data ?? [];
                return ListView.builder(
                  itemCount: items.length,
                  itemBuilder: (context, i) {
                    final s = items[i];
                    return ListTile(
                      leading: const Icon(Icons.badge_outlined),
                      title: Text(s['name']?.toString() ?? '', style: const TextStyle(fontWeight: FontWeight.w700)),
                      subtitle: Text('${s['phone']} · ${s['role']}'),
                    );
                  },
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}

class BusinessSettingsScreen extends ConsumerStatefulWidget {
  const BusinessSettingsScreen({super.key});

  @override
  ConsumerState<BusinessSettingsScreen> createState() => _BusinessSettingsScreenState();
}

class _BusinessSettingsScreenState extends ConsumerState<BusinessSettingsScreen> {
  final _name = TextEditingController();
  final _phone = TextEditingController();
  final _desc = TextEditingController();
  final _promo = TextEditingController();
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
    _phone.dispose();
    _desc.dispose();
    _promo.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    try {
      final res = await ref.read(apiClientProvider).get('/dashboard/business/overview');
      final d = Map<String, dynamic>.from(res.data as Map);
      _name.text = d['name']?.toString() ?? '';
      _promo.text = d['promo_text']?.toString() ?? '';
      final mine = await ref.read(apiClientProvider).get('/businesses/mine');
      final list = (mine.data as List).cast<Map>();
      if (list.isNotEmpty) {
        _phone.text = list.first['phone']?.toString() ?? '';
        final desc = list.first['description']?.toString() ?? '';
        _desc.text = desc.contains('\nPROMO:') ? desc.split('\nPROMO:').first : desc;
        if (_promo.text.isEmpty && desc.contains('\nPROMO:')) {
          _promo.text = desc.split('\nPROMO:').last;
        }
      }
    } catch (_) {}
    if (mounted) setState(() => _loading = false);
  }

  Future<void> _save() async {
    setState(() => _saving = true);
    try {
      await ref.read(apiClientProvider).patch('/dashboard/business/settings', data: {
        'name': _name.text.trim(),
        'phone': _phone.text.trim(),
        'description': _desc.text.trim(),
        'promo_text': _promo.text.trim(),
      });
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Saved')));
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
      appBar: AppBar(title: const Text('Business settings')),
      body: _loading
          ? const LoadingView()
          : ListView(
              padding: const EdgeInsets.all(16),
              children: [
                TextField(controller: _name, decoration: const InputDecoration(labelText: 'Shop name')),
                const SizedBox(height: 12),
                TextField(controller: _phone, decoration: const InputDecoration(labelText: 'Business phone')),
                const SizedBox(height: 12),
                TextField(
                  controller: _desc,
                  maxLines: 3,
                  decoration: const InputDecoration(labelText: 'Description'),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: _promo,
                  decoration: const InputDecoration(
                    labelText: 'Current promotion',
                    hintText: 'e.g. Free delivery this weekend',
                  ),
                ),
                const SizedBox(height: 20),
                FilledButton(
                  onPressed: _saving ? null : _save,
                  child: Text(_saving ? 'Saving…' : 'Save settings'),
                ),
              ],
            ),
    );
  }
}

class BusinessPromotionsScreen extends StatelessWidget {
  const BusinessPromotionsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Promotions')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          const Text(
            'Set a storefront promo banner that customers see on your shop. '
            'Use Business settings to edit the promo text.',
          ),
          const SizedBox(height: 16),
          FilledButton.icon(
            onPressed: () => context.push('/business-owner/settings'),
            icon: const Icon(Icons.campaign),
            label: const Text('Edit promo in settings'),
          ),
          const SizedBox(height: 12),
          OutlinedButton.icon(
            onPressed: () => context.push('/business-owner/videos'),
            icon: const Icon(Icons.videocam_outlined),
            label: const Text('Promote with a shop video'),
          ),
        ],
      ),
    );
  }
}
