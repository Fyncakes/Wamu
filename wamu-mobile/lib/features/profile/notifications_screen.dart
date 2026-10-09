import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/network/api_client.dart';
import 'commerce_notif_provider.dart';

class NotificationModel {
  const NotificationModel({
    required this.id,
    required this.title,
    required this.body,
    required this.type,
    this.isRead = false,
    this.createdAt,
    this.data = const {},
  });

  factory NotificationModel.fromJson(Map<String, dynamic> json) {
    final raw = json['data'];
    final data = <String, dynamic>{};
    if (raw is Map) {
      raw.forEach((k, v) => data[k.toString()] = v);
    }
    return NotificationModel(
      id: json['id']?.toString() ?? '',
      title: json['title']?.toString() ?? '',
      body: json['body']?.toString() ?? '',
      type: json['type']?.toString() ?? '',
      isRead: json['is_read'] == true,
      createdAt: json['created_at']?.toString(),
      data: data,
    );
  }

  final String id;
  final String title;
  final String body;
  final String type;
  final bool isRead;
  final String? createdAt;
  final Map<String, dynamic> data;

  String? get deepLink => notificationDeepLink(type: type, data: data);
}

/// Maps notification type + payload to an in-app route (or null = stay).
String? notificationDeepLink({
  required String type,
  Map<String, dynamic> data = const {},
}) {
  final t = type.toUpperCase();
  String? id(String key) {
    final v = data[key]?.toString().trim();
    if (v == null || v.isEmpty) return null;
    return v;
  }

  switch (t) {
    case 'ORDER_STATUS':
    case 'PAYMENT_SUCCESS':
      final orderId = id('order_id');
      return orderId == null ? null : '/orders/$orderId';
    case 'NEW_ORDER':
      return '/business-owner/orders';
    case 'ORDER_PAID':
      final conversationId = id('conversation_id');
      if (conversationId != null) return '/chat/$conversationId';
      return '/business-owner/orders';
    case 'PAYOUT_SUCCESS':
      return '/business-owner/payouts';
    case 'PAYOUT_REVERSED':
      return '/business-owner/payouts';
    case 'BUSINESS_VERIFIED':
      return '/business-owner';
    case 'DELIVERY_CANCELLED':
      return '/deliveries';
    case 'DELIVERY_AVAILABLE':
    case 'DELIVERY_JOB':
      return '/deliveries';
    case 'NEW_MESSAGE':
      final conversationId = id('conversation_id');
      return conversationId == null ? null : '/chat/$conversationId';
    case 'REVIEW_REPLY':
      final businessId = id('business_id');
      return businessId == null ? null : '/business/$businessId';
    case 'INCOMING_CALL':
      return '/calls';
    case 'DELIVERY_ASSIGNED':
      final orderId = id('order_id');
      return orderId == null ? null : '/orders/$orderId';
    case 'ORDER_DISPUTE':
      final audience = (data['audience']?.toString() ?? '').toLowerCase();
      if (audience == 'merchant') return '/business-owner/orders';
      final orderId = id('order_id');
      return orderId == null ? null : '/orders/$orderId';
    default:
      return null;
  }
}

class NotificationsRepository {
  NotificationsRepository(this._client);

  final ApiClient _client;

  Future<List<NotificationModel>> list() async {
    final response = await _client.get('/notifications');
    final data = response.data;
    if (data is List) {
      return data.map((e) => NotificationModel.fromJson(e as Map<String, dynamic>)).toList();
    }
    return [];
  }

  Future<void> markRead(String id) async {
    await _client.post('/notifications/$id/read');
  }
}

final notificationsRepositoryProvider = Provider<NotificationsRepository>((ref) {
  return NotificationsRepository(ref.watch(apiClientProvider));
});

IconData _iconForType(String type) {
  switch (type.toUpperCase()) {
    case 'ORDER_STATUS':
    case 'NEW_ORDER':
    case 'ORDER_PAID':
    case 'ORDER_DISPUTE':
    case 'DELIVERY_ASSIGNED':
      return Icons.receipt_long_outlined;
    case 'DELIVERY_AVAILABLE':
    case 'DELIVERY_JOB':
    case 'DELIVERY_CANCELLED':
      return Icons.delivery_dining_outlined;
    case 'BUSINESS_VERIFIED':
      return Icons.verified_outlined;
    case 'PAYMENT_SUCCESS':
    case 'PAYOUT_SUCCESS':
      return Icons.payments_outlined;
    case 'NEW_MESSAGE':
      return Icons.chat_bubble_outline;
    case 'REVIEW_REPLY':
      return Icons.rate_review_outlined;
    case 'INCOMING_CALL':
      return Icons.call_outlined;
    default:
      return Icons.notifications_none;
  }
}

/// In-app notifications inbox with deep-links into orders / chat / reviews.
class NotificationsScreen extends ConsumerStatefulWidget {
  const NotificationsScreen({super.key});

  @override
  ConsumerState<NotificationsScreen> createState() => _NotificationsScreenState();
}

class _NotificationsScreenState extends ConsumerState<NotificationsScreen> {
  late Future<List<NotificationModel>> _future;

  @override
  void initState() {
    super.initState();
    _load();
  }

  void _load() {
    _future = ref.read(notificationsRepositoryProvider).list().then((rows) {
      ref.read(commerceNotifProvider.notifier).markSeen();
      ref.read(commerceNotifProvider.notifier).refresh();
      return rows;
    });
  }

  Future<void> _open(NotificationModel n) async {
    // Tapping a notification clears badge / unread, then opens the deep link.
    if (!n.isRead) {
      await ref.read(commerceNotifProvider.notifier).markReadById(n.id);
      if (mounted) setState(_load);
    } else {
      ref.read(commerceNotifProvider.notifier).markSeen();
    }
    final link = n.deepLink;
    if (link != null && mounted) {
      context.push(link);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Notifications')),
      body: FutureBuilder<List<NotificationModel>>(
        future: _future,
        builder: (context, snapshot) {
          if (snapshot.connectionState == ConnectionState.waiting) {
            return const Center(child: CircularProgressIndicator());
          }
          if (snapshot.hasError) {
            return Center(child: Text('${snapshot.error}'));
          }
          final items = snapshot.data ?? [];
          if (items.isEmpty) {
            return const Center(child: Text('No notifications yet'));
          }
          return RefreshIndicator(
            onRefresh: () async => setState(_load),
            child: ListView.separated(
              itemCount: items.length,
              separatorBuilder: (_, _) => const Divider(height: 1),
              itemBuilder: (context, index) {
                final n = items[index];
                final linkable = n.deepLink != null;
                return ListTile(
                  leading: Icon(
                    n.isRead ? _iconForType(n.type) : Icons.notifications_active,
                    color: Theme.of(context).colorScheme.primary,
                  ),
                  title: Text(
                    n.title,
                    style: TextStyle(fontWeight: n.isRead ? FontWeight.normal : FontWeight.w700),
                  ),
                  subtitle: Text(n.body),
                  trailing: linkable
                      ? const Icon(Icons.chevron_right, size: 20)
                      : null,
                  onTap: () => _open(n),
                );
              },
            ),
          );
        },
      ),
    );
  }
}
