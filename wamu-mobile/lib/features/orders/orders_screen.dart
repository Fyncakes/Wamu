import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:uuid/uuid.dart';

import '../../core/network/api_error.dart';
import '../../core/theme/app_theme.dart';
import '../../shared/models/order_model.dart';
import '../../shared/utils/maps_nav.dart';
import '../../shared/utils/order_payment_style.dart';
import '../../shared/utils/order_tracking.dart';
import '../../shared/utils/ugx_formatter.dart';
import '../../shared/widgets/error_view.dart';
import '../../shared/widgets/loading_view.dart';
import '../../shared/widgets/momo_provider_picker.dart';
import '../businesses/favorites_repository.dart';
import '../discover/videos_feed_visibility.dart';
import '../move/riders_repository.dart';
import 'delivery_tracking_map.dart';
import 'orders_repository.dart';

Color _statusColor(String status) {
  switch (status.toUpperCase()) {
    case 'PENDING':
      return Colors.orange;
    case 'CONFIRMED':
    case 'PROCESSING':
    case 'READY':
    case 'OUT_FOR_DELIVERY':
      return Colors.blue;
    case 'DELIVERED':
      return Colors.green;
    case 'CANCELLED':
    case 'REFUNDED':
      return Colors.red;
    default:
      return Colors.grey;
  }
}

/// Orders tab with status chips and navigation to order detail.
class OrdersScreen extends ConsumerStatefulWidget {
  const OrdersScreen({super.key});

  @override
  ConsumerState<OrdersScreen> createState() => _OrdersScreenState();
}

class _OrdersScreenState extends ConsumerState<OrdersScreen>
    with WidgetsBindingObserver {
  List<OrderModel>? _orders;
  Object? _error;
  bool _loading = true;
  Timer? _poll;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _refresh(showSpinner: true);
  }

  @override
  void dispose() {
    _poll?.cancel();
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _refresh();
    }
  }

  void _schedulePoll() {
    _poll?.cancel();
    final orders = _orders;
    if (orders == null) return;
    final active = listHasActiveOrders(
      orders.map((o) => (status: o.status, paymentStatus: o.paymentStatus)),
    );
    if (!active) return;
    _poll = Timer.periodic(const Duration(seconds: 5), (_) {
      if (!mounted) return;
      if (ref.read(shellTabIndexProvider) != ShellTabs.orders) return;
      _refresh();
    });
  }

  Future<void> _refresh({bool showSpinner = false}) async {
    if (showSpinner && mounted) setState(() => _loading = true);
    try {
      final orders = await ref.read(ordersRepositoryProvider).getOrders();
      if (!mounted) return;
      setState(() {
        _orders = orders;
        _error = null;
        _loading = false;
      });
      _schedulePoll();
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e;
        _loading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Orders'),
        actions: [
          if (_poll?.isActive == true)
            const Padding(
              padding: EdgeInsets.only(right: 12),
              child: Center(
                child: SizedBox(
                  width: 14,
                  height: 14,
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
              ),
            ),
        ],
      ),
      body: _loading && _orders == null
          ? const LoadingView(message: 'Loading orders…')
          : _error != null && _orders == null
              ? ErrorView(message: '$_error', onRetry: () => _refresh(showSpinner: true))
              : (_orders == null || _orders!.isEmpty)
                  ? Center(
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(Icons.receipt_long_outlined, size: 64, color: Colors.grey.shade400),
                          const SizedBox(height: 12),
                          const Text('No orders yet'),
                          TextButton(
                            onPressed: () => context.go('/home'),
                            child: const Text('Browse shops'),
                          ),
                        ],
                      ),
                    )
                  : RefreshIndicator(
                      onRefresh: () => _refresh(),
            child: ListView.builder(
                        padding: const EdgeInsets.symmetric(vertical: 8),
                        itemCount: _orders!.length,
              itemBuilder: (context, index) {
                          final order = _orders![index];
                          final shortId =
                              order.id.length > 8 ? order.id.substring(0, 8) : order.id;
                          final payLabel = order.paymentLabel;
                return Card(
                            margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
                  child: ListTile(
                              title: Text('Order · $shortId'),
                              subtitle: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  Text(
                                    '${order.items.map((i) => i.name).take(2).join(', ')}'
                                    '${order.items.length > 2 ? '…' : ''}',
                                  ),
                                  if (payLabel.isNotEmpty)
                                    Text(
                                      payLabel,
                                      style: TextStyle(
                                        fontSize: 12,
                                        fontWeight: FontWeight.w600,
                                        color: orderPaymentColor(order.paymentStatus),
                                      ),
                                    ),
                                ],
                              ),
                              isThreeLine: payLabel.isNotEmpty,
                              trailing: Column(
                                mainAxisAlignment: MainAxisAlignment.center,
                                crossAxisAlignment: CrossAxisAlignment.end,
                                children: [
                                  Text(
                                    formatUgx(order.total),
                                    style: const TextStyle(fontWeight: FontWeight.w700),
                                  ),
                                  const SizedBox(height: 4),
                                  Container(
                                    padding: const EdgeInsets.symmetric(
                                      horizontal: 8,
                                      vertical: 2,
                                    ),
                                    decoration: BoxDecoration(
                                      color: _statusColor(order.status).withValues(alpha: 0.15),
                                      borderRadius: BorderRadius.circular(12),
                                    ),
                                    child: Text(
                                      order.status,
                                      style: TextStyle(
                                        fontSize: 11,
                                        color: _statusColor(order.status),
                                        fontWeight: FontWeight.w600,
                                      ),
                                    ),
                                  ),
                                ],
                              ),
                              onTap: () async {
                                await context.push('/orders/${order.id}');
                                if (mounted) _refresh();
                              },
                            ),
                          );
                        },
                      ),
                    ),
    );
  }
}

/// Full order detail with live status + delivery tracking.
class OrderDetailScreen extends ConsumerStatefulWidget {
  const OrderDetailScreen({super.key, required this.orderId});

  final String orderId;

  @override
  ConsumerState<OrderDetailScreen> createState() => _OrderDetailScreenState();
}

class _OrderDetailScreenState extends ConsumerState<OrderDetailScreen>
    with WidgetsBindingObserver {
  OrderModel? _order;
  Map<String, dynamic>? _delivery;
  Object? _error;
  bool _loading = true;
  bool _busy = false;
  bool _live = false;
  Timer? _poll;
  String _retryProvider = 'MTN';

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _refresh(showSpinner: true);
  }

  @override
  void dispose() {
    _poll?.cancel();
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _refresh();
    }
  }

  void _schedulePoll() {
    _poll?.cancel();
    final order = _order;
    if (order == null) {
      setState(() => _live = false);
      return;
    }
    final needs = orderNeedsLiveTracking(
      order.status,
      paymentStatus: order.paymentStatus,
    );
    setState(() => _live = needs);
    if (!needs) return;
    _poll = Timer.periodic(const Duration(seconds: 4), (_) => _refresh());
  }

  Future<void> _refresh({bool showSpinner = false}) async {
    if (showSpinner && mounted) setState(() => _loading = true);
    try {
      final order = await ref.read(ordersRepositoryProvider).getOrder(widget.orderId);
      Map<String, dynamic>? delivery;
      try {
        delivery =
            await ref.read(ridersRepositoryProvider).deliveryForOrder(widget.orderId);
      } catch (_) {
        delivery = null;
      }
      if (!mounted) return;
      setState(() {
        _order = order;
        _delivery = delivery;
        _error = null;
        _loading = false;
        if (order.paymentProvider != null && order.paymentProvider!.isNotEmpty) {
          _retryProvider = order.paymentProvider!;
        }
      });
      _schedulePoll();
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e;
        _loading = false;
      });
    }
  }

  Future<void> _cancel() async {
    setState(() => _busy = true);
    try {
      await ref.read(ordersRepositoryProvider).updateStatus(widget.orderId, 'CANCELLED');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Order cancelled')),
        );
        await _refresh();
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('$e')));
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _retryPayment(OrderModel order) async {
    setState(() => _busy = true);
    try {
      final payment = await ref.read(ordersRepositoryProvider).payOrderAndAwait(
            orderId: order.id,
            idempotencyKey: const Uuid().v4(),
            provider: _retryProvider,
          );
      if (!mounted) return;
      final status = payment['status']?.toString() ?? 'UNKNOWN';
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            status == 'SUCCESS'
                ? '$_retryProvider payment confirmed'
                : status == 'FAILED'
                    ? '$_retryProvider payment failed'
                    : '$_retryProvider $status — still waiting on MoMo',
          ),
        ),
      );
      await _refresh();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(apiErrorMessage(e))),
        );
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _reportIssue(OrderModel order) async {
    const reasons = <(String, String)>[
      ('NOT_DELIVERED', 'Not delivered'),
      ('WRONG_ITEMS', 'Wrong items'),
      ('QUALITY', 'Quality issue'),
      ('OTHER', 'Other'),
    ];
    var reason = reasons.first.$1;
    final descCtrl = TextEditingController();

    final ok = await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      builder: (ctx) {
        return StatefulBuilder(
          builder: (ctx, setModal) {
            return Padding(
              padding: EdgeInsets.only(
                left: 20,
                right: 20,
                top: 16,
                bottom: MediaQuery.of(ctx).viewInsets.bottom + 20,
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Text(
                    'Report an issue',
                    style: Theme.of(ctx).textTheme.titleLarge?.copyWith(
                          fontWeight: FontWeight.w800,
                        ),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    'We’ll review and may refund if appropriate.',
                    style: Theme.of(ctx).textTheme.bodyMedium?.copyWith(
                          color: Colors.grey.shade700,
                        ),
                  ),
                  const SizedBox(height: 12),
                  DropdownButtonFormField<String>(
                    initialValue: reason,
                    decoration: const InputDecoration(labelText: 'Reason'),
                    items: [
                      for (final r in reasons)
                        DropdownMenuItem(value: r.$1, child: Text(r.$2)),
                    ],
                    onChanged: (v) {
                      if (v != null) setModal(() => reason = v);
                    },
                  ),
                  const SizedBox(height: 8),
                  TextField(
                    controller: descCtrl,
                    decoration: const InputDecoration(
                      labelText: 'Details (optional)',
                      hintText: 'What went wrong?',
                    ),
                    maxLines: 3,
                  ),
                  const SizedBox(height: 12),
                  FilledButton(
                    onPressed: () => Navigator.pop(ctx, true),
                    style: FilledButton.styleFrom(
                      backgroundColor: Colors.red.shade700,
                      foregroundColor: Colors.white,
                    ),
                    child: const Text('Submit dispute'),
                  ),
                ],
              ),
            );
          },
        );
      },
    );

    final description = descCtrl.text.trim();
    descCtrl.dispose();
    if (ok != true || !mounted) return;

    setState(() => _busy = true);
    try {
      await ref.read(ordersRepositoryProvider).createDispute(
            orderId: order.id,
            reason: reason,
            description: description.isEmpty ? null : description,
          );
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Dispute submitted — we’ll follow up')),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('$e')));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _leaveReview(OrderModel order) async {
    final businessId = order.businessId;
    if (businessId == null) return;

    final delivery = _delivery ??
        await ref.read(ridersRepositoryProvider).deliveryForOrder(order.id);
    final hasRider = delivery != null && delivery['rider'] != null;
    final riderName =
        (delivery?['rider'] as Map?)?['display_name']?.toString() ?? 'Rider';

    var bizRating = 5;
    var riderRating = 5;
    final commentCtrl = TextEditingController();

    final ok = await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      builder: (ctx) {
        return StatefulBuilder(
          builder: (ctx, setModal) {
            return Padding(
              padding: EdgeInsets.only(
                left: 20,
                right: 20,
                top: 16,
                bottom: MediaQuery.of(ctx).viewInsets.bottom + 20,
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Text(
                    'Rate this order',
                    style: Theme.of(ctx).textTheme.titleLarge?.copyWith(
                          fontWeight: FontWeight.w800,
                        ),
                  ),
                  const SizedBox(height: 8),
                  const Text('Business'),
                  Row(
                    children: List.generate(5, (i) {
                      final star = i + 1;
                      return IconButton(
                        onPressed: () => setModal(() => bizRating = star),
                        icon: Icon(
                          star <= bizRating ? Icons.star : Icons.star_border,
                          color: AppTheme.accentGreen,
                        ),
                      );
                    }),
                  ),
                  if (hasRider) ...[
                    Text('Rider · $riderName'),
                    Row(
                      children: List.generate(5, (i) {
                        final star = i + 1;
                        return IconButton(
                          onPressed: () => setModal(() => riderRating = star),
                          icon: Icon(
                            star <= riderRating ? Icons.star : Icons.star_border,
                            color: Colors.amber.shade700,
                          ),
                        );
                      }),
                    ),
                  ],
                  TextField(
                    controller: commentCtrl,
                    decoration: const InputDecoration(
                      labelText: 'Comment (optional)',
                      hintText: 'How was the food and delivery?',
                    ),
                    maxLines: 3,
                  ),
                  const SizedBox(height: 12),
                  FilledButton(
                    onPressed: () => Navigator.pop(ctx, true),
                    style: FilledButton.styleFrom(
                      backgroundColor: AppTheme.accentGreen,
                      foregroundColor: Colors.black,
                    ),
                    child: const Text('Submit review'),
                  ),
                ],
              ),
            );
          },
        );
      },
    );

    final comment = commentCtrl.text.trim();
    commentCtrl.dispose();
    if (ok != true || !mounted) return;

    setState(() => _busy = true);
    try {
      await ref.read(reviewsRepositoryProvider).postReview(
            businessId: businessId,
            orderId: order.id,
            rating: bizRating,
            comment: comment.isEmpty ? null : comment,
            riderRating: hasRider ? riderRating : null,
          );
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Thanks for your review')),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('$e')));
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Widget _deliveryCard(Map<String, dynamic> d) {
    final rider = d['rider'] as Map<String, dynamic>?;
    final name = rider?['display_name']?.toString() ?? 'Rider';
    final refCode = rider?['wamu_rider_ref']?.toString() ?? '';
    final status = d['status']?.toString();
    final label = deliveryStatusLabel(status);
    final shopName = d['shop_name']?.toString();
    final pickup = d['pickup_address']?.toString();
    final dropoff = d['dropoff_address']?.toString();
    final eta = d['eta_minutes'];
    final statusU = (status ?? '').toUpperCase();
    final headingToCustomer =
        statusU == 'PICKED_UP' || statusU == 'IN_TRANSIT';

    return Container(
      width: double.infinity,
      margin: const EdgeInsets.only(bottom: 16),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        border: Border.all(color: AppTheme.accentGreen.withValues(alpha: 0.4)),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            rider != null ? '$name · $label' : label,
            style: const TextStyle(fontWeight: FontWeight.w800),
          ),
          if (refCode.isNotEmpty)
            Text(refCode, style: TextStyle(color: AppTheme.messengerMuted)),
          const SizedBox(height: 8),
          if (shopName != null && shopName.isNotEmpty)
            Text('From: $shopName', style: const TextStyle(fontWeight: FontWeight.w600)),
          if (pickup != null && pickup.isNotEmpty) Text('Shop: $pickup'),
          if (dropoff != null && dropoff.isNotEmpty) Text('Deliver to: $dropoff'),
          if (eta != null)
            Padding(
              padding: const EdgeInsets.only(top: 6),
              child: Text(
                headingToCustomer
                    ? 'ETA to you: ~$eta min'
                    : 'ETA to shop / you: ~$eta min',
                style: const TextStyle(
                  fontWeight: FontWeight.w700,
                  color: AppTheme.accentGreen,
                ),
              ),
            ),
          if (d['proof_note'] != null && d['proof_note'].toString().trim().isNotEmpty)
            Text('Proof: ${d['proof_note']}'),
          const SizedBox(height: 12),
          DeliveryTrackingMap(delivery: d),
          const SizedBox(height: 10),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              OutlinedButton.icon(
                onPressed: () => openMapsPin(
                  lat: parseCoord(d['pickup_lat']),
                  lng: parseCoord(d['pickup_lng']),
                  address: pickup ?? shopName,
                ),
                icon: const Icon(Icons.storefront, size: 18),
                label: const Text('Shop on map'),
              ),
              if (dropoff != null && dropoff.isNotEmpty)
                OutlinedButton.icon(
                  onPressed: () => openMapsPin(
                    lat: parseCoord(d['dropoff_lat']),
                    lng: parseCoord(d['dropoff_lng']),
                    address: dropoff,
                  ),
                  icon: const Icon(Icons.location_on_outlined, size: 18),
                  label: const Text('Drop-off pin'),
                ),
            ],
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Order details'),
        actions: [
          if (_live)
            Padding(
              padding: const EdgeInsets.only(right: 12),
              child: Row(
                children: [
                  Icon(Icons.sensors, size: 16, color: AppTheme.accentGreen),
                  const SizedBox(width: 4),
                  Text(
                    'Live',
                    style: TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w700,
                      color: AppTheme.accentGreen,
                    ),
                  ),
                ],
              ),
            ),
          IconButton(
            tooltip: 'Refresh',
            onPressed: _busy ? null : () => _refresh(),
            icon: const Icon(Icons.refresh),
          ),
        ],
      ),
      body: _loading && _order == null
          ? const LoadingView()
          : _error != null && _order == null
              ? ErrorView(message: '$_error', onRetry: () => _refresh(showSpinner: true))
              : Builder(
                  builder: (context) {
                    final order = _order!;
                    final payLabel = order.paymentLabel;
                    return RefreshIndicator(
                      onRefresh: () => _refresh(),
                      child: ListView(
                        padding: const EdgeInsets.all(16),
                        children: [
                          Row(
                            children: [
                              Expanded(
                                child: Text(
                                  formatUgx(order.total),
                                  style: Theme.of(context)
                                      .textTheme
                                      .headlineSmall
                                      ?.copyWith(fontWeight: FontWeight.w700),
                                ),
                              ),
                              Chip(
                                label: Text(order.status),
                                backgroundColor:
                                    _statusColor(order.status).withValues(alpha: 0.15),
                                labelStyle: TextStyle(color: _statusColor(order.status)),
                              ),
                            ],
                          ),
                          if (payLabel.isNotEmpty) ...[
                            const SizedBox(height: 8),
                            Text(
                              payLabel,
                              style: Theme.of(context).textTheme.titleMedium?.copyWith(
                                    color: orderPaymentColor(order.paymentStatus),
                                    fontWeight: FontWeight.w600,
                                  ),
                            ),
                          ],
                          if (order.createdAt != null)
                            Text(
                              'Placed · ${order.createdAt}',
                              style: Theme.of(context).textTheme.bodySmall,
                            ),
                          const SizedBox(height: 16),
                          if (_delivery != null) _deliveryCard(_delivery!),
                          Text('Items', style: Theme.of(context).textTheme.titleLarge),
                          const SizedBox(height: 8),
                          ...order.items.map(
                            (item) => ListTile(
                              contentPadding: EdgeInsets.zero,
                              title: Text(item.name),
                              subtitle:
                                  Text('${item.quantity} × ${formatUgx(item.price)}'),
                              trailing: Text(formatUgx(item.price * item.quantity)),
                            ),
                          ),
                          const Divider(height: 32),
                          if (order.canRetryPayment) ...[
                            MomoProviderPicker(
                              value: _retryProvider,
                              compact: true,
                              enabled: !_busy,
                              onChanged: (v) => setState(() => _retryProvider = v),
                            ),
                            const SizedBox(height: 8),
                            ElevatedButton.icon(
                              onPressed: _busy ? null : () => _retryPayment(order),
                              icon: Icon(order.needsFirstPayment ? Icons.payments_outlined : Icons.refresh),
                              label: Text(
                                order.needsFirstPayment
                                    ? 'Pay with $_retryProvider'
                                    : 'Retry with $_retryProvider',
                              ),
                            ),
                            const SizedBox(height: 12),
                          ],
                          if (order.status == 'PENDING')
                            ElevatedButton(
                              onPressed: _busy ? null : _cancel,
                              style: ElevatedButton.styleFrom(
                                backgroundColor: Colors.red.shade700,
                              ),
                              child: const Text('Cancel order'),
                            ),
                          if (order.status == 'DELIVERED')
                            FilledButton.icon(
                              onPressed: _busy ? null : () => _leaveReview(order),
                              style: FilledButton.styleFrom(
                                backgroundColor: AppTheme.accentGreen,
                                foregroundColor: Colors.black,
                              ),
                              icon: const Icon(Icons.star),
                              label: const Text('Rate business & rider'),
                            ),
                          if (order.status == 'DELIVERED' ||
                              order.status == 'OUT_FOR_DELIVERY') ...[
                            if (order.status == 'DELIVERED') const SizedBox(height: 12),
                            OutlinedButton.icon(
                              onPressed: _busy ? null : () => _reportIssue(order),
                              icon: const Icon(Icons.report_gmailerrorred_outlined),
                              label: const Text('Report an issue'),
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
