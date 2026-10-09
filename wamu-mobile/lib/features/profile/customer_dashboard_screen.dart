import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/network/api_client.dart';
import '../../core/theme/app_theme.dart';
import '../../shared/utils/ugx_formatter.dart';
import '../../shared/widgets/error_view.dart';
import '../../shared/widgets/loading_view.dart';
import '../../shared/widgets/wamu_network_image.dart';

/// Customer hub — links every buyer surface in one place.
class CustomerDashboardScreen extends StatelessWidget {
  const CustomerDashboardScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final tiles = <_DashTile>[
      _DashTile(Icons.home_outlined, 'Home / Videos', 'Discover shops via short videos', '/home'),
      _DashTile(Icons.search, 'Search', 'Find shops and products', '/search'),
      _DashTile(Icons.storefront_outlined, 'Nearby shops', 'Categories & Kampala areas', '/shops'),
      _DashTile(Icons.shopping_cart_outlined, 'Cart', 'Checkout with MoMo', '/cart'),
      _DashTile(Icons.receipt_long, 'Orders', 'Track live orders', '/orders'),
      _DashTile(Icons.chat_bubble_outline, 'Messages', 'Chat to order', '/chats'),
      _DashTile(Icons.account_balance_wallet_outlined, 'Payments', 'MoMo payment history', '/me/payments'),
      _DashTile(Icons.favorite_border, 'Favorites', 'Saved shops', '/favorites'),
      _DashTile(Icons.person_add_alt_1, 'Following', 'Shops you follow', '/me/following'),
      _DashTile(Icons.notifications_outlined, 'Notifications', 'Order and chat alerts', '/notifications'),
      _DashTile(Icons.rate_review_outlined, 'My reviews', 'Ratings you left', '/me/reviews'),
      _DashTile(Icons.delivery_dining, 'Delivery history', 'Past drop-offs', '/me/deliveries'),
      _DashTile(Icons.settings_outlined, 'Profile / settings', 'Account and privacy', '/settings'),
    ];

    return Scaffold(
      appBar: AppBar(title: const Text('Customer dashboard')),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 32),
        children: [
          Text(
            'Everything for buying on Wamu',
            style: Theme.of(context).textTheme.titleMedium?.copyWith(
                  color: AppTheme.messengerMuted,
                ),
          ),
          const SizedBox(height: 12),
          ...tiles.map(
            (t) => Card(
              margin: const EdgeInsets.only(bottom: 8),
              child: ListTile(
                leading: Icon(t.icon, color: AppTheme.accentGreen),
                title: Text(t.title, style: const TextStyle(fontWeight: FontWeight.w700)),
                subtitle: Text(t.subtitle),
                trailing: const Icon(Icons.chevron_right),
                onTap: () {
                  if (t.route == '/home' ||
                      t.route == '/chats' ||
                      t.route == '/shops' ||
                      t.route == '/orders' ||
                      t.route == '/settings') {
                    context.go(t.route);
                  } else {
                    context.push(t.route);
                  }
                },
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _DashTile {
  const _DashTile(this.icon, this.title, this.subtitle, this.route);
  final IconData icon;
  final String title;
  final String subtitle;
  final String route;
}

class _DashboardListScreen extends ConsumerStatefulWidget {
  const _DashboardListScreen({
    required this.title,
    required this.path,
    required this.builder,
  });

  final String title;
  final String path;
  final Widget Function(BuildContext, Map<String, dynamic>) builder;

  @override
  ConsumerState<_DashboardListScreen> createState() => _DashboardListScreenState();
}

class _DashboardListScreenState extends ConsumerState<_DashboardListScreen> {
  late Future<List<Map<String, dynamic>>> _future;

  @override
  void initState() {
    super.initState();
    _future = _load();
  }

  Future<List<Map<String, dynamic>>> _load() async {
    final res = await ref.read(apiClientProvider).get(widget.path);
    final data = res.data;
    if (data is List) {
      return data.whereType<Map>().map((e) => Map<String, dynamic>.from(e)).toList();
    }
    return [];
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(widget.title)),
      body: FutureBuilder(
        future: _future,
        builder: (context, snap) {
          if (snap.connectionState != ConnectionState.done) {
            return const LoadingView();
          }
          if (snap.hasError) {
            return ErrorView(
              message: '${snap.error}',
              onRetry: () => setState(() => _future = _load()),
            );
          }
          final items = snap.data ?? [];
          if (items.isEmpty) {
            return Center(
              child: Text('Nothing here yet', style: Theme.of(context).textTheme.bodyLarge),
            );
          }
          return RefreshIndicator(
            onRefresh: () async => setState(() => _future = _load()),
            child: ListView.separated(
              padding: const EdgeInsets.all(16),
              itemCount: items.length,
              separatorBuilder: (_, __) => const SizedBox(height: 8),
              itemBuilder: (context, i) => widget.builder(context, items[i]),
            ),
          );
        },
      ),
    );
  }
}

class PaymentsWalletScreen extends ConsumerWidget {
  const PaymentsWalletScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return _DashboardListScreen(
      title: 'Payments',
      path: '/dashboard/me/payments',
      builder: (context, p) {
        final status = (p['status'] ?? '').toString().toUpperCase();
        final color = status == 'SUCCESS'
            ? Colors.green
            : status == 'FAILED'
                ? Colors.red
                : Colors.orange;
        return Card(
          child: ListTile(
            leading: Icon(Icons.phone_android, color: color),
            title: Text(
              '${p['provider'] ?? 'MoMo'} · ${formatUgx((p['amount'] as num?)?.toDouble() ?? 0)}',
              style: const TextStyle(fontWeight: FontWeight.w700),
            ),
            subtitle: Text('$status · ${p['phone'] ?? ''}'),
            trailing: TextButton(
              onPressed: () => context.push('/orders/${p['order_id']}'),
              child: const Text('Order'),
            ),
          ),
        );
      },
    );
  }
}

class FollowingScreen extends ConsumerWidget {
  const FollowingScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return _DashboardListScreen(
      title: 'Following',
      path: '/dashboard/me/following',
      builder: (context, b) {
        return Card(
          child: ListTile(
            leading: ClipRRect(
              borderRadius: BorderRadius.circular(8),
              child: WamuNetworkImage(
                imageUrl: b['logo_url']?.toString(),
                width: 44,
                height: 44,
              ),
            ),
            title: Text(b['name']?.toString() ?? 'Shop', style: const TextStyle(fontWeight: FontWeight.w700)),
            subtitle: Text('★ ${(b['rating'] as num?)?.toStringAsFixed(1) ?? '0.0'}'),
            onTap: () => context.push('/business/${b['business_id']}'),
          ),
        );
      },
    );
  }
}

class MyReviewsScreen extends ConsumerWidget {
  const MyReviewsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return _DashboardListScreen(
      title: 'My reviews',
      path: '/dashboard/me/reviews',
      builder: (context, r) {
        return Card(
          child: ListTile(
            leading: Text('★${r['rating']}', style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 18)),
            title: Text(r['business_name']?.toString() ?? 'Shop', style: const TextStyle(fontWeight: FontWeight.w700)),
            subtitle: Text(r['comment']?.toString().isNotEmpty == true ? r['comment'].toString() : 'No comment'),
            onTap: () => context.push('/business/${r['business_id']}'),
          ),
        );
      },
    );
  }
}

class CustomerDeliveryHistoryScreen extends ConsumerWidget {
  const CustomerDeliveryHistoryScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return _DashboardListScreen(
      title: 'Delivery history',
      path: '/dashboard/me/deliveries',
      builder: (context, d) {
        return Card(
          child: ListTile(
            leading: const Icon(Icons.delivery_dining, color: AppTheme.accentGreen),
            title: Text(d['status']?.toString() ?? '', style: const TextStyle(fontWeight: FontWeight.w700)),
            subtitle: Text(
              [
                if (d['dropoff_address'] != null) d['dropoff_address'],
                if (d['rider_name'] != null) 'Rider: ${d['rider_name']}',
                formatUgx((d['fee'] as num?)?.toDouble() ?? 0),
              ].join(' · '),
            ),
            onTap: () => context.push('/orders/${d['order_id']}'),
          ),
        );
      },
    );
  }
}
