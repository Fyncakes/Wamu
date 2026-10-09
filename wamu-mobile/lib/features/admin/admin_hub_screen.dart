import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../core/server_config.dart';
import '../../core/theme/app_theme.dart';
import '../../shared/utils/ugx_formatter.dart';
import '../../shared/widgets/error_view.dart';
import '../../shared/widgets/loading_view.dart';
import '../auth/auth_provider.dart';
import 'admin_repository.dart';

/// Phone-friendly admin hub — stats + approve riders/businesses over the linked API.
class AdminHubScreen extends ConsumerStatefulWidget {
  const AdminHubScreen({super.key});

  @override
  ConsumerState<AdminHubScreen> createState() => _AdminHubScreenState();
}

class _AdminHubScreenState extends ConsumerState<AdminHubScreen>
    with SingleTickerProviderStateMixin {
  TabController? _tabs;
  Future<_AdminBundle>? _future;
  Timer? _poll;
  _AdminBundle? _latest;

  @override
  void initState() {
    super.initState();
    if (ref.read(authProvider).user?.isAdmin == true) {
      _tabs = TabController(length: 6, vsync: this);
      _future = _load();
      _poll = Timer.periodic(const Duration(seconds: 5), (_) {
        if (!mounted) return;
        _silentReload();
      });
    }
  }

  @override
  void dispose() {
    _poll?.cancel();
    _tabs?.dispose();
    super.dispose();
  }

  Future<_AdminBundle> _load() async {
    final repo = ref.read(adminRepositoryProvider);
    final stats = await repo.stats();
    final users = await repo.users();
    final riders = await repo.riders();
    final businesses = await repo.businesses();
    final orders = await repo.orders();
    final deliveries = await repo.deliveries();
    final bundle = _AdminBundle(
      stats: stats,
      users: users,
      riders: riders,
      businesses: businesses,
      orders: orders,
      deliveries: deliveries,
    );
    _latest = bundle;
    return bundle;
  }

  void _reload() {
    setState(() => _future = _load());
  }

  Future<void> _silentReload() async {
    try {
      final bundle = await _load();
      if (!mounted) return;
      setState(() {
        _latest = bundle;
        _future = Future.value(bundle);
      });
    } catch (_) {}
  }

  Future<void> _openFullWebAdmin() async {
    final origin = ServerConfig.mediaOrigin;
    final uri = Uri.tryParse(origin);
    if (uri == null) return;
    final host = uri.host;
    final candidates = <Uri>[
      if (host.startsWith('192.168.') || host == '127.0.0.1' || host == 'localhost')
        Uri(scheme: 'http', host: host, port: 3000),
      Uri(scheme: 'http', host: '192.168.100.121', port: 3000),
      Uri.parse('$origin/connect'),
    ];
    for (final u in candidates) {
      if (await canLaunchUrl(u)) {
        final ok = await launchUrl(u, mode: LaunchMode.externalApplication);
        if (ok) return;
      }
    }
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text('Open admin on Wi‑Fi: http://PC:3000 (full desktop console)'),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final isAdmin = ref.watch(authProvider).user?.isAdmin == true;
    if (!isAdmin) {
      return Scaffold(
        appBar: AppBar(title: const Text('Admin')),
        body: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const Icon(Icons.admin_panel_settings_outlined, size: 56, color: AppTheme.accentGreen),
              const SizedBox(height: 16),
              Text(
                'Admin console',
                style: Theme.of(context).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w800),
              ),
              const SizedBox(height: 8),
              const Text(
                'This account is not an admin. Log out, then sign in with the demo admin number to manage riders and shops.',
              ),
              const SizedBox(height: 16),
              const SelectableText(
                '+256700000001\nOTP 123456',
                style: TextStyle(fontWeight: FontWeight.w700, height: 1.4),
              ),
              const SizedBox(height: 20),
              FilledButton(
                onPressed: () => Navigator.of(context).maybePop(),
                style: FilledButton.styleFrom(
                  backgroundColor: AppTheme.accentGreen,
                  foregroundColor: Colors.black,
                ),
                child: const Text('Back'),
              ),
              const SizedBox(height: 8),
              OutlinedButton.icon(
                onPressed: _openFullWebAdmin,
                icon: const Icon(Icons.open_in_browser),
                label: const Text('Open web admin (:3000)'),
              ),
            ],
          ),
        ),
      );
    }

    return Scaffold(
      appBar: AppBar(
        title: const Text('Admin'),
        actions: [
          IconButton(
            tooltip: 'Full web console',
            onPressed: _openFullWebAdmin,
            icon: const Icon(Icons.open_in_browser),
          ),
          IconButton(
            tooltip: 'Refresh',
            onPressed: _reload,
            icon: const Icon(Icons.refresh),
          ),
        ],
        bottom: TabBar(
          controller: _tabs!,
          isScrollable: true,
          tabs: const [
            Tab(text: 'Overview'),
            Tab(text: 'Users'),
            Tab(text: 'Riders'),
            Tab(text: 'Shops'),
            Tab(text: 'Orders'),
            Tab(text: 'Deliveries'),
          ],
        ),
      ),
      body: FutureBuilder<_AdminBundle>(
        future: _future,
        builder: (context, snap) {
          if (snap.connectionState != ConnectionState.done && _latest == null) {
            return const LoadingView();
          }
          if (snap.hasError && _latest == null) {
            final msg = isAdminApiError(snap.error!)
                ? 'Admin API denied. Log in as +256700000001 (OTP 123456).'
                : '${snap.error}';
            return ErrorView(message: msg, onRetry: _reload);
          }
          final data = snap.data ?? _latest!;
          return TabBarView(
            controller: _tabs!,
            children: [
              _OverviewTab(stats: data.stats, onOpenWeb: _openFullWebAdmin),
              _UsersTab(users: data.users),
              _RidersTab(riders: data.riders, onChanged: _reload),
              _ShopsTab(businesses: data.businesses, onChanged: _reload),
              _LiveListTab(
                title: 'Orders (live)',
                empty: 'No orders yet',
                rows: data.orders,
                line1: (r) =>
                    '${r['status'] ?? '—'} · ${r['payment_status'] ?? ''}'.trim(),
                line2: (r) {
                  final amt = r['total_amount'] ?? r['amount'] ?? '';
                  final biz = r['business_name'] ?? r['business_id'] ?? '';
                  return 'UGX $amt · $biz';
                },
              ),
              _LiveListTab(
                title: 'Deliveries (live)',
                empty: 'No deliveries yet',
                rows: data.deliveries,
                line1: (r) => '${r['status'] ?? '—'}',
                line2: (r) =>
                    '${r['pickup_address'] ?? r['dropoff_address'] ?? r['order_id'] ?? ''}',
              ),
            ],
          );
        },
      ),
    );
  }
}

class _AdminBundle {
  const _AdminBundle({
    required this.stats,
    required this.users,
    required this.riders,
    required this.businesses,
    required this.orders,
    required this.deliveries,
  });

  final Map<String, dynamic> stats;
  final List<Map<String, dynamic>> users;
  final List<Map<String, dynamic>> riders;
  final List<Map<String, dynamic>> businesses;
  final List<Map<String, dynamic>> orders;
  final List<Map<String, dynamic>> deliveries;
}

class _OverviewTab extends StatelessWidget {
  const _OverviewTab({required this.stats, required this.onOpenWeb});

  final Map<String, dynamic> stats;
  final VoidCallback onOpenWeb;

  int _i(String k) => int.tryParse('${stats[k] ?? 0}') ?? 0;
  double _d(String k) => double.tryParse('${stats[k] ?? 0}') ?? 0;

  @override
  Widget build(BuildContext context) {
    final cards = [
      ('Users', '${_i('users')}'),
      ('Riders', '${_i('riders')}'),
      ('Approved riders', '${_i('riders_approved')}'),
      ('Pending riders', '${_i('riders_pending')}'),
      ('Businesses', '${_i('businesses')}'),
      ('Orders', '${_i('orders')}'),
      ('Payments', '${_i('payments')}'),
      ('GMV', formatUgx(_d('revenue_ugx'))),
    ];
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        Text(
          'Phone admin — approve riders & shops here. Full analytics stay on the web console.',
          style: Theme.of(context).textTheme.bodyMedium,
        ),
        const SizedBox(height: 12),
        OutlinedButton.icon(
          onPressed: onOpenWeb,
          icon: const Icon(Icons.laptop_windows_outlined),
          label: const Text('Open full web dashboard'),
        ),
        const SizedBox(height: 16),
        GridView.count(
          shrinkWrap: true,
          physics: const NeverScrollableScrollPhysics(),
          crossAxisCount: 2,
          mainAxisSpacing: 10,
          crossAxisSpacing: 10,
          childAspectRatio: 1.55,
          children: [
            for (final c in cards)
              Container(
                padding: const EdgeInsets.all(14),
                decoration: BoxDecoration(
                  color: Theme.of(context).cardColor,
                  borderRadius: BorderRadius.circular(14),
                  border: Border.all(
                    color: AppTheme.accentGreen.withValues(alpha: 0.25),
                  ),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      c.$1,
                      style: Theme.of(context).textTheme.labelMedium,
                    ),
                    const Spacer(),
                    Text(
                      c.$2,
                      style: const TextStyle(
                        fontWeight: FontWeight.w800,
                        fontSize: 20,
                      ),
                    ),
                  ],
                ),
              ),
          ],
        ),
      ],
    );
  }
}

class _UsersTab extends StatelessWidget {
  const _UsersTab({required this.users});

  final List<Map<String, dynamic>> users;

  String _name(Map<String, dynamic> u) {
    final profile = u['profile'];
    if (profile is Map) {
      final first = profile['first_name']?.toString() ?? '';
      final last = profile['last_name']?.toString() ?? '';
      final full = '$first $last'.trim();
      if (full.isNotEmpty) return full;
      final username = profile['username']?.toString();
      if (username != null && username.isNotEmpty) return username;
    }
    return u['phone']?.toString() ?? 'User';
  }

  @override
  Widget build(BuildContext context) {
    if (users.isEmpty) {
      return const Center(child: Text('No users yet'));
    }
    return ListView.separated(
      padding: const EdgeInsets.all(12),
      itemCount: users.length,
      separatorBuilder: (_, __) => const Divider(height: 1),
      itemBuilder: (context, i) {
        final u = users[i];
        final role = (u['role']?.toString() ?? 'CUSTOMER').toUpperCase();
        final email = u['email']?.toString();
        final phone = u['phone']?.toString() ?? '';
        final status = u['status']?.toString() ?? '';
        return ListTile(
          leading: CircleAvatar(
            backgroundColor: AppTheme.accentGreen.withValues(alpha: 0.2),
            child: Text(
              _name(u).isNotEmpty ? _name(u)[0].toUpperCase() : '?',
              style: const TextStyle(color: AppTheme.accentGreen, fontWeight: FontWeight.w700),
            ),
          ),
          title: Text(_name(u), style: const TextStyle(fontWeight: FontWeight.w600)),
          subtitle: Text(
            [
              phone,
              if (email != null && email.isNotEmpty) email,
              'Role: $role',
              if (status.isNotEmpty) status,
            ].join(' · '),
          ),
          isThreeLine: true,
        );
      },
    );
  }
}

class _RidersTab extends ConsumerWidget {
  const _RidersTab({required this.riders, required this.onChanged});

  final List<Map<String, dynamic>> riders;
  final VoidCallback onChanged;

  bool _pending(String status) =>
      status == 'DRAFT' ||
      status == 'PENDING' ||
      status == 'SUBMITTED' ||
      status == 'UNDER_REVIEW' ||
      status == 'NEEDS_REUPLOAD';

  Future<void> _openDetail(BuildContext context, WidgetRef ref, String id) async {
    try {
      final detail = await ref.read(adminRepositoryProvider).riderVerification(id);
      if (!context.mounted) return;
      await showModalBottomSheet<void>(
        context: context,
        isScrollControlled: true,
        builder: (ctx) {
          final checks = detail['ai_checks'] is Map
              ? Map<String, dynamic>.from(detail['ai_checks'] as Map)
              : <String, dynamic>{};
          final checkMap = checks['checks'] is Map
              ? Map<String, dynamic>.from(checks['checks'] as Map)
              : <String, dynamic>{};
          final docs = detail['documents'] is List ? detail['documents'] as List : const [];
          final status = '${detail['status'] ?? ''}'.toUpperCase();
          return DraggableScrollableSheet(
            expand: false,
            initialChildSize: 0.85,
            builder: (_, scroll) => ListView(
              controller: scroll,
              padding: const EdgeInsets.all(16),
              children: [
                Text(
                  '${detail['display_name'] ?? 'Rider'}',
                  style: Theme.of(ctx).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w800),
                ),
                Text('${detail['wamu_rider_ref'] ?? ''} · ${detail['phone'] ?? ''}'),
                Text('Status: $status · AI: ${detail['ai_result'] ?? '—'}'),
                if (detail['nin'] != null) Text('NIN: ${detail['nin']}'),
                const SizedBox(height: 12),
                Text('AI analysis', style: Theme.of(ctx).textTheme.titleMedium),
                ...checkMap.entries.map(
                  (e) => ListTile(
                    dense: true,
                    contentPadding: EdgeInsets.zero,
                    title: Text(e.key.replaceAll('_', ' ')),
                    trailing: Text('${e.value}', style: const TextStyle(fontWeight: FontWeight.w700)),
                  ),
                ),
                const SizedBox(height: 8),
                Text('Documents', style: Theme.of(ctx).textTheme.titleMedium),
                ...docs.whereType<Map>().map(
                      (d) => ListTile(
                        dense: true,
                        contentPadding: EdgeInsets.zero,
                        title: Text('${d['doc_type']}'),
                        subtitle: Text('${d['url'] ?? ''}'),
                      ),
                    ),
                const SizedBox(height: 12),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    if (_pending(status))
                      FilledButton(
                        onPressed: () async {
                          await ref.read(adminRepositoryProvider).approveRider(id, note: 'Approved on phone');
                          if (ctx.mounted) Navigator.pop(ctx);
                          onChanged();
                        },
                        style: FilledButton.styleFrom(
                          backgroundColor: AppTheme.accentGreen,
                          foregroundColor: Colors.black,
                        ),
                        child: const Text('Approve'),
                      ),
                    if (_pending(status))
                      OutlinedButton(
                        onPressed: () async {
                          await ref.read(adminRepositoryProvider).requestRiderReupload(
                                id,
                                note: 'Please re-upload documents',
                                reuploadFields: const ['SELFIE', 'NATIONAL_ID_FRONT'],
                              );
                          if (ctx.mounted) Navigator.pop(ctx);
                          onChanged();
                        },
                        child: const Text('Request re-upload'),
                      ),
                    if (_pending(status) || status == 'APPROVED')
                      OutlinedButton(
                        onPressed: () async {
                          await ref.read(adminRepositoryProvider).rejectRider(id, note: 'Rejected');
                          if (ctx.mounted) Navigator.pop(ctx);
                          onChanged();
                        },
                        child: const Text('Reject'),
                      ),
                    if (status == 'APPROVED')
                      OutlinedButton(
                        onPressed: () async {
                          await ref.read(adminRepositoryProvider).suspendRider(id, note: 'Suspended');
                          if (ctx.mounted) Navigator.pop(ctx);
                          onChanged();
                        },
                        child: const Text('Suspend'),
                      ),
                  ],
                ),
                const SizedBox(height: 8),
                Text(
                  '${detail['government_verification']?['note'] ?? ''}',
                  style: Theme.of(ctx).textTheme.bodySmall,
                ),
              ],
            ),
          );
        },
      );
    } catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('$e')));
      }
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (riders.isEmpty) {
      return const Center(child: Text('No riders yet'));
    }
    final pendingStatuses = {
      'DRAFT',
      'PENDING',
      'SUBMITTED',
      'UNDER_REVIEW',
      'NEEDS_REUPLOAD',
    };
    final ordered = [...riders]..sort((a, b) {
          final as = '${a['status'] ?? ''}'.toUpperCase();
          final bs = '${b['status'] ?? ''}'.toUpperCase();
          final ap = pendingStatuses.contains(as) ? 0 : 1;
          final bp = pendingStatuses.contains(bs) ? 0 : 1;
          if (ap != bp) return ap.compareTo(bp);
          return 0;
        });
    final pendingCount =
        ordered.where((r) => pendingStatuses.contains('${r['status'] ?? ''}'.toUpperCase())).length;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
          child: Text(
            pendingCount == 0
                ? 'No riders waiting — submit docs on the rider phone, then Approve here.'
                : '$pendingCount waiting for approval — tap Approve (or open for docs).',
            style: Theme.of(context).textTheme.bodySmall,
          ),
        ),
        Expanded(
          child: ListView.separated(
            padding: const EdgeInsets.symmetric(vertical: 8),
            itemCount: ordered.length,
            separatorBuilder: (_, __) => const Divider(height: 1),
            itemBuilder: (context, i) {
              final r = ordered[i];
              final id = '${r['id'] ?? ''}';
              final status = '${r['status'] ?? r['rider_status'] ?? ''}'.toUpperCase();
              final name =
                  '${r['display_name'] ?? r['name'] ?? r['full_name'] ?? r['phone'] ?? 'Rider'}';
              final phone = '${r['phone'] ?? ''}';
              final ai = '${r['ai_result'] ?? ''}';
              final refId = '${r['wamu_rider_ref'] ?? ''}';
              final pending = _pending(status);
              return ListTile(
                title: Text(name, style: const TextStyle(fontWeight: FontWeight.w700)),
                subtitle: Text('$refId · $phone · $status${ai.isEmpty ? '' : ' · AI $ai'}'),
                onTap: () => _openDetail(context, ref, id),
                trailing: pending
                    ? FilledButton(
                        style: FilledButton.styleFrom(
                          backgroundColor: AppTheme.accentGreen,
                          foregroundColor: Colors.black,
                        ),
                        onPressed: () async {
                          try {
                            await ref.read(adminRepositoryProvider).approveRider(
                                  id,
                                  note: 'Approved on phone',
                                );
                            onChanged();
                          } catch (e) {
                            if (context.mounted) {
                              ScaffoldMessenger.of(context).showSnackBar(
                                SnackBar(content: Text('$e')),
                              );
                            }
                          }
                        },
                        child: const Text('Approve'),
                      )
                    : Text(status, style: const TextStyle(fontSize: 12)),
              );
            },
          ),
        ),
      ],
    );
  }
}

class _ShopsTab extends ConsumerWidget {
  const _ShopsTab({required this.businesses, required this.onChanged});

  final List<Map<String, dynamic>> businesses;
  final VoidCallback onChanged;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (businesses.isEmpty) {
      return const Center(child: Text('No businesses yet'));
    }
    return ListView.separated(
      padding: const EdgeInsets.symmetric(vertical: 8),
      itemCount: businesses.length,
      separatorBuilder: (_, __) => const Divider(height: 1),
      itemBuilder: (context, i) {
        final b = businesses[i];
        final id = '${b['id'] ?? ''}';
        final name = '${b['name'] ?? 'Shop'}';
        final v = '${b['verification_status'] ?? ''}'.toUpperCase();
        final pending = v == 'PENDING';
        return ListTile(
          title: Text(name, style: const TextStyle(fontWeight: FontWeight.w700)),
          subtitle: Text('Verification: $v'),
          trailing: pending
              ? FilledButton(
                  style: FilledButton.styleFrom(
                    backgroundColor: AppTheme.accentGreen,
                    foregroundColor: Colors.black,
                  ),
                  onPressed: () async {
                    try {
                      await ref.read(adminRepositoryProvider).verifyBusiness(id);
                      onChanged();
                    } catch (e) {
                      if (context.mounted) {
                        ScaffoldMessenger.of(context).showSnackBar(
                          SnackBar(content: Text('$e')),
                        );
                      }
                    }
                  },
                  child: const Text('Verify'),
                )
              : Text(v, style: const TextStyle(fontSize: 12)),
        );
      },
    );
  }
}

class _LiveListTab extends StatelessWidget {
  const _LiveListTab({
    required this.title,
    required this.empty,
    required this.rows,
    required this.line1,
    required this.line2,
  });

  final String title;
  final String empty;
  final List<Map<String, dynamic>> rows;
  final String Function(Map<String, dynamic>) line1;
  final String Function(Map<String, dynamic>) line2;

  @override
  Widget build(BuildContext context) {
    if (rows.isEmpty) {
      return Center(
        child: Text(empty, style: const TextStyle(color: Colors.black54)),
      );
    }
    return ListView.separated(
      padding: const EdgeInsets.symmetric(vertical: 8),
      itemCount: rows.length,
      separatorBuilder: (_, __) => const Divider(height: 1),
      itemBuilder: (context, i) {
        final r = rows[i];
        return ListTile(
          title: Text(
            line1(r),
            style: const TextStyle(fontWeight: FontWeight.w700),
          ),
          subtitle: Text(line2(r)),
          dense: true,
        );
      },
    );
  }
}
