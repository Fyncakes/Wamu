import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/theme/app_theme.dart';
import '../../core/network/api_error.dart';
import '../../shared/models/business_model.dart';
import '../../shared/utils/ugx_formatter.dart';
import '../../shared/widgets/wamu_network_image.dart';
import '../auth/auth_provider.dart';
import '../cart/cart_provider.dart';
import '../home/catalog_repository.dart';
import '../../shared/models/order_model.dart';
import '../orders/orders_repository.dart';

const _deliveryFee = 5000.0;

/// Cart — photos, shop context, pickup/delivery, and Mobile Money checkout.
class CartScreen extends ConsumerStatefulWidget {
  const CartScreen({super.key});

  @override
  ConsumerState<CartScreen> createState() => _CartScreenState();
}

class _CartScreenState extends ConsumerState<CartScreen> {
  bool _loading = false;
  String _fulfillment = 'PICKUP';
  String _provider = 'MTN';
  String _statusLine = '';
  final Map<String, BusinessModel> _shops = {};
  final _addressController = TextEditingController();
  final _phoneController = TextEditingController();

  @override
  void initState() {
    super.initState();
    final phone = ref.read(authProvider).user?.phone ?? '+256';
    _phoneController.text = phone;
    WidgetsBinding.instance.addPostFrameCallback((_) => _hydrateDetails());
  }

  @override
  void dispose() {
    _addressController.dispose();
    _phoneController.dispose();
    super.dispose();
  }

  Future<void> _hydrateDetails() async {
    final items = ref.read(cartProvider);
    if (items.isEmpty) return;
    final repo = ref.read(catalogRepositoryProvider);
    final shopIds = ref.read(cartProvider.notifier).shopIds;
    for (final bizId in shopIds) {
      if (_shops.containsKey(bizId)) continue;
      try {
        final shop = await repo.getBusiness(bizId);
        if (mounted) setState(() => _shops[bizId] = shop);
      } catch (_) {}
    }
    for (final item in items) {
      try {
        final fresh = await repo.getProduct(item.product.id);
        ref.read(cartProvider.notifier).patchProduct(fresh);
      } catch (_) {}
    }
  }

  Future<void> _checkout() async {
    final cart = ref.read(cartProvider.notifier);
    if (ref.read(cartProvider).isEmpty) return;
    final phone = _phoneController.text.trim();
    if (!phone.startsWith('+256') || phone.length < 12) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Enter a valid +256 Mobile Money number')),
      );
      return;
    }
    if (_fulfillment == 'DELIVERY' && _addressController.text.trim().length < 8) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Add a delivery address in Kampala')),
      );
      return;
    }
    final shopCount = cart.shopCount;
    setState(() {
      _loading = true;
      _statusLine = shopCount > 1
          ? 'Creating $shopCount shop orders + paying with $_provider…'
          : 'Creating order + paying with $_provider…';
    });
    try {
      final ordersRepo = ref.read(ordersRepositoryProvider);
      final List<OrderModel> orders;
      if (shopCount > 1) {
        final batch = await ordersRepo.createOrderBatch(
          cart.toBatchOrderPayload(
            fulfillment: _fulfillment,
            deliveryAddress:
                _fulfillment == 'DELIVERY' ? _addressController.text.trim() : null,
          ),
        );
        orders = batch.orders;
      } else {
        final order = await ordersRepo.createOrder(
          cart.toOrderPayload(
            fulfillment: _fulfillment,
            deliveryAddress:
                _fulfillment == 'DELIVERY' ? _addressController.text.trim() : null,
          ),
        );
        orders = [order];
      }

      var allOk = true;
      var anyFailed = false;
      for (var i = 0; i < orders.length; i++) {
        final order = orders[i];
        if (mounted) {
          setState(() {
            _statusLine = orders.length > 1
                ? 'Paying shop ${i + 1}/${orders.length} with $_provider…'
                : 'Processing $_provider payment…';
          });
        }
        final payment = await ordersRepo.payOrderAndAwait(
          orderId: order.id,
          idempotencyKey: cart.newIdempotencyKey(),
          provider: _provider,
          phone: phone,
          onStatus: (s) {
            if (!mounted) return;
            setState(() {
              _statusLine = s == 'SUCCESS'
                  ? (orders.length > 1
                      ? 'Shop ${i + 1}/${orders.length} paid'
                      : 'Payment confirmed')
                  : s == 'FAILED'
                      ? 'Payment failed'
                      : 'Confirming $_provider payment… ($s)';
            });
          },
        );
        final status = (payment['status']?.toString() ?? '').toUpperCase();
        if (status != 'SUCCESS') {
          allOk = false;
          if (status == 'FAILED') anyFailed = true;
        }
      }

      if (allOk) {
        cart.clear();
      }
      if (!mounted) return;
      setState(() => _statusLine = allOk ? 'Payment confirmed' : 'Payment incomplete');
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            allOk
                ? (orders.length > 1
                    ? '$_provider paid · ${orders.length} shop orders placed'
                    : '$_provider paid · order placed')
                : anyFailed
                    ? '$_provider payment failed — open Orders to Pay each shop'
                    : '$_provider still processing — check Orders shortly',
          ),
        ),
      );
      context.go('/orders');
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(apiErrorMessage(e, fallback: 'Checkout failed'))),
        );
      }
    } finally {
      if (mounted) {
        setState(() {
          _loading = false;
          _statusLine = '';
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final items = ref.watch(cartProvider);
    final cart = ref.read(cartProvider.notifier);
    final subtotal = ref.watch(cartTotalProvider);
    final delivery = _fulfillment == 'DELIVERY' ? _deliveryFee : 0.0;
    final total = subtotal + delivery;
    final theme = Theme.of(context);
    final dark = theme.brightness == Brightness.dark;
    final qty = items.fold<int>(0, (n, i) => n + i.quantity);
    final shopCount = cart.shopCount;
    final byShop = cart.itemsByShop;

    return Scaffold(
      appBar: AppBar(
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('Cart'),
            if (items.isNotEmpty)
              Text(
                shopCount > 1
                    ? '$qty items · $shopCount shops'
                    : '$qty ${qty == 1 ? 'item' : 'items'}',
                style: theme.textTheme.labelSmall,
              ),
          ],
        ),
        actions: [
          if (items.isNotEmpty)
            TextButton(
              onPressed: _loading
                  ? null
                  : () {
                      ref.read(cartProvider.notifier).clear();
                      setState(() => _shops.clear());
                    },
              child: const Text('Clear'),
            ),
        ],
      ),
      body: items.isEmpty
          ? _EmptyCart(onBrowse: () => context.go('/home'))
          : ListView(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
              children: [
                if (shopCount > 1) ...[
                  Container(
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: AppTheme.accentGreen.withValues(alpha: dark ? 0.14 : 0.1),
                      borderRadius: BorderRadius.circular(14),
                    ),
                    child: Text(
                      'Multi-shop bag · one checkout, separate merchant orders',
                      style: theme.textTheme.bodySmall?.copyWith(
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                  const SizedBox(height: 14),
                ],
                for (final entry in byShop.entries) ...[
                  if (_shops[entry.key] != null) ...[
                    _ShopBanner(shop: _shops[entry.key]!),
                    const SizedBox(height: 10),
                  ] else ...[
                    Text(
                      'Shop',
                      style: theme.textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w700),
                    ),
                    const SizedBox(height: 8),
                  ],
                  ...entry.value.map((item) {
                    return Padding(
                      padding: const EdgeInsets.only(bottom: 12),
                      child: Dismissible(
                        key: ValueKey(item.product.id),
                        direction: DismissDirection.endToStart,
                        background: Container(
                          alignment: Alignment.centerRight,
                          padding: const EdgeInsets.only(right: 20),
                          decoration: BoxDecoration(
                            color: const Color(0xFFC0392B).withValues(alpha: 0.18),
                            borderRadius: BorderRadius.circular(20),
                          ),
                          child: const Icon(Icons.delete_outline, color: Color(0xFFC0392B)),
                        ),
                        onDismissed: (_) =>
                            ref.read(cartProvider.notifier).removeProduct(item.product.id),
                        child: _CartItemCard(
                          item: item,
                          onMinus: () => ref.read(cartProvider.notifier).updateQuantity(
                                item.product.id,
                                item.quantity - 1,
                              ),
                          onPlus: () => ref.read(cartProvider.notifier).updateQuantity(
                                item.product.id,
                                item.quantity + 1,
                              ),
                          onOpen: () => context.push('/product/${item.product.id}'),
                        ),
                      ),
                    );
                  }),
                  const SizedBox(height: 4),
                ],
                const SizedBox(height: 8),
                Text('How you’ll get it', style: theme.textTheme.titleMedium),
                const SizedBox(height: 10),
                Row(
                  children: [
                    Expanded(
                      child: _FulfillCard(
                        selected: _fulfillment == 'PICKUP',
                        icon: Icons.storefront_outlined,
                        title: 'Pickup',
                        subtitle: 'Collect at the shop',
                        badge: 'Free',
                        onTap: () => setState(() => _fulfillment = 'PICKUP'),
                      ),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: _FulfillCard(
                        selected: _fulfillment == 'DELIVERY',
                        icon: Icons.delivery_dining,
                        title: 'Delivery',
                        subtitle: 'Rider brings it',
                        badge: formatUgx(_deliveryFee),
                        onTap: () => setState(() => _fulfillment = 'DELIVERY'),
                      ),
                    ),
                  ],
                ),
                if (_fulfillment == 'DELIVERY') ...[
                  const SizedBox(height: 12),
                  TextField(
                    controller: _addressController,
                    textCapitalization: TextCapitalization.words,
                    decoration: InputDecoration(
                      labelText: 'Delivery address',
                      hintText: 'e.g. Kisaasi, Kampala',
                      prefixIcon: const Icon(Icons.place_outlined),
                      filled: true,
                      fillColor: dark ? AppTheme.messengerElevated : const Color(0xFFF4F1EC),
                    ),
                  ),
                ],
                const SizedBox(height: 22),
                Text('Pay with Mobile Money', style: theme.textTheme.titleMedium),
                const SizedBox(height: 10),
                Row(
                  children: [
                    Expanded(
                      child: _PayTile(
                        selected: _provider == 'MTN',
                        title: 'MTN MoMo',
                        color: const Color(0xFFFFCC00),
                        onTap: _loading ? null : () => setState(() => _provider = 'MTN'),
                      ),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: _PayTile(
                        selected: _provider == 'AIRTEL',
                        title: 'Airtel Money',
                        color: const Color(0xFFE4002B),
                        onTap: _loading ? null : () => setState(() => _provider = 'AIRTEL'),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: _phoneController,
                  keyboardType: TextInputType.phone,
                  enabled: !_loading,
                  decoration: InputDecoration(
                    labelText: '$_provider number',
                    hintText: '+2567…',
                    prefixIcon: const Icon(Icons.phone_android),
                    filled: true,
                    fillColor: dark ? AppTheme.messengerElevated : const Color(0xFFF4F1EC),
                  ),
                ),
                if (_statusLine.isNotEmpty) ...[
                  const SizedBox(height: 14),
                  Row(
                    children: [
                      const SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(strokeWidth: 2, color: AppTheme.accentGreen),
                      ),
                      const SizedBox(width: 10),
                      Expanded(child: Text(_statusLine)),
                    ],
                  ),
                ],
              ],
            ),
      bottomNavigationBar: items.isEmpty
          ? null
          : _CheckoutBar(
              subtotal: subtotal,
              delivery: delivery,
              total: total,
              loading: _loading,
              provider: _provider,
              onPay: _checkout,
            ),
    );
  }
}

class _EmptyCart extends StatelessWidget {
  const _EmptyCart({required this.onBrowse});

  final VoidCallback onBrowse;

  @override
  Widget build(BuildContext context) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 120,
              height: 120,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: dark ? AppTheme.messengerElevated : const Color(0xFFE8F7EF),
              ),
              child: const Icon(Icons.shopping_bag_outlined, size: 56, color: AppTheme.accentGreen),
            ),
            const SizedBox(height: 20),
            Text('Your bag is empty', style: Theme.of(context).textTheme.headlineSmall),
            const SizedBox(height: 8),
            Text(
              'Add meals from Discover or a shop nearby.',
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.bodyMedium,
            ),
            const SizedBox(height: 20),
            FilledButton(onPressed: onBrowse, child: const Text('Browse shops')),
          ],
        ),
      ),
    );
  }
}

class _ShopBanner extends StatelessWidget {
  const _ShopBanner({required this.shop});

  final BusinessModel shop;

  @override
  Widget build(BuildContext context) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    return Material(
      color: dark ? AppTheme.messengerElevated : const Color(0xFFF4F1EC),
      borderRadius: BorderRadius.circular(18),
      child: InkWell(
        onTap: () => context.push('/business/${shop.id}'),
        borderRadius: BorderRadius.circular(18),
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Row(
            children: [
              ClipRRect(
                borderRadius: BorderRadius.circular(14),
                child: WamuNetworkImage(imageUrl: shop.imageUrl, width: 52, height: 52),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(shop.name, style: Theme.of(context).textTheme.titleMedium),
                    Text(
                      shop.address ?? shop.city ?? 'Kampala',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                  ],
                ),
              ),
              const Icon(Icons.chevron_right),
            ],
          ),
        ),
      ),
    );
  }
}

class _CartItemCard extends StatelessWidget {
  const _CartItemCard({
    required this.item,
    required this.onMinus,
    required this.onPlus,
    required this.onOpen,
  });

  final CartItem item;
  final VoidCallback onMinus;
  final VoidCallback onPlus;
  final VoidCallback onOpen;

  @override
  Widget build(BuildContext context) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    final product = item.product;
    return Material(
      color: dark ? AppTheme.messengerElevated : Colors.white,
      elevation: dark ? 0 : 1,
      shadowColor: Colors.black12,
      borderRadius: BorderRadius.circular(20),
      child: InkWell(
        onTap: onOpen,
        borderRadius: BorderRadius.circular(20),
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              ClipRRect(
                borderRadius: BorderRadius.circular(16),
                child: WamuNetworkImage(
                  imageUrl: product.imageUrl,
                  width: 92,
                  height: 92,
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                      Text(
                        product.name,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: Theme.of(context).textTheme.titleMedium?.copyWith(height: 1.2),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        formatUgx(product.price),
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                      const SizedBox(height: 8),
                      Row(
                        children: [
                          _QtyStepper(quantity: item.quantity, onMinus: onMinus, onPlus: onPlus),
                          const Spacer(),
                          Text(
                            formatUgx(item.subtotal),
                            style: Theme.of(context).textTheme.titleSmall?.copyWith(
                                  color: AppTheme.accentGreen,
                                  fontWeight: FontWeight.w800,
                                ),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
    );
  }
}

class _QtyStepper extends StatelessWidget {
  const _QtyStepper({
    required this.quantity,
    required this.onMinus,
    required this.onPlus,
  });

  final int quantity;
  final VoidCallback onMinus;
  final VoidCallback onPlus;

  @override
  Widget build(BuildContext context) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    return Container(
      height: 34,
      decoration: BoxDecoration(
        color: dark ? const Color(0xFF0B141A) : const Color(0xFFF0F2F5),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          _QtyBtn(icon: Icons.remove, onTap: onMinus),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8),
            child: Text(
              '$quantity',
              style: const TextStyle(fontWeight: FontWeight.w800),
            ),
          ),
          _QtyBtn(icon: Icons.add, onTap: onPlus),
        ],
      ),
    );
  }
}

class _QtyBtn extends StatelessWidget {
  const _QtyBtn({required this.icon, required this.onTap});

  final IconData icon;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      customBorder: const CircleBorder(),
      child: SizedBox(
        width: 32,
        height: 34,
        child: Icon(icon, size: 16, color: AppTheme.accentGreen),
      ),
    );
  }
}

class _FulfillCard extends StatelessWidget {
  const _FulfillCard({
    required this.selected,
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.badge,
    required this.onTap,
  });

  final bool selected;
  final IconData icon;
  final String title;
  final String subtitle;
  final String badge;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    return Material(
      color: selected
          ? AppTheme.accentGreen.withValues(alpha: dark ? 0.16 : 0.12)
          : (dark ? AppTheme.messengerElevated : Colors.white),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(18),
        side: BorderSide(
          color: selected ? AppTheme.accentGreen : (dark ? const Color(0xFF2A3942) : const Color(0xFFE6E0D8)),
          width: selected ? 1.6 : 1,
        ),
      ),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(18),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(12, 14, 12, 14),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(icon, color: selected ? AppTheme.accentGreen : null),
              const SizedBox(height: 10),
              Text(title, style: const TextStyle(fontWeight: FontWeight.w800)),
              const SizedBox(height: 2),
              Text(subtitle, style: Theme.of(context).textTheme.bodySmall),
              const SizedBox(height: 8),
              Text(
                badge,
                style: TextStyle(
                  fontWeight: FontWeight.w700,
                  fontSize: 12,
                  color: selected ? AppTheme.accentGreen : Theme.of(context).textTheme.bodySmall?.color,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _PayTile extends StatelessWidget {
  const _PayTile({
    required this.selected,
    required this.title,
    required this.color,
    required this.onTap,
  });

  final bool selected;
  final String title;
  final Color color;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    return Material(
      color: selected ? color.withValues(alpha: dark ? 0.22 : 0.16) : (dark ? AppTheme.messengerElevated : Colors.white),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(16),
        side: BorderSide(color: selected ? color : (dark ? const Color(0xFF2A3942) : const Color(0xFFE6E0D8)), width: selected ? 1.6 : 1),
      ),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(16),
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 14, horizontal: 10),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Container(
                width: 10,
                height: 10,
                decoration: BoxDecoration(color: color, shape: BoxShape.circle),
              ),
              const SizedBox(width: 8),
              Flexible(
                child: Text(
                  title,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 13),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _CheckoutBar extends StatelessWidget {
  const _CheckoutBar({
    required this.subtotal,
    required this.delivery,
    required this.total,
    required this.loading,
    required this.provider,
    required this.onPay,
  });

  final double subtotal;
  final double delivery;
  final double total;
  final bool loading;
  final String provider;
  final VoidCallback onPay;

  @override
  Widget build(BuildContext context) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    return Material(
      elevation: 12,
      color: dark ? AppTheme.messengerSurface : Colors.white,
      child: SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              _sumRow(context, 'Subtotal', formatUgx(subtotal)),
              const SizedBox(height: 4),
              _sumRow(
                context,
                'Delivery',
                delivery == 0 ? 'Free' : formatUgx(delivery),
              ),
              const Divider(height: 16),
              Row(
                children: [
                  Text('Total', style: Theme.of(context).textTheme.titleMedium),
                  const Spacer(),
                  Text(
                    formatUgx(total),
                    style: Theme.of(context).textTheme.titleLarge?.copyWith(
                          fontWeight: FontWeight.w800,
                          color: AppTheme.accentGreen,
                        ),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              SizedBox(
                width: double.infinity,
                height: 52,
                child: FilledButton(
                  onPressed: loading ? null : onPay,
                  child: loading
                      ? const SizedBox(
                          height: 22,
                          width: 22,
                          child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
                        )
                      : Text('Pay ${formatUgx(total)} with $provider'),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _sumRow(BuildContext context, String label, String value) {
    return Row(
      children: [
        Text(label, style: Theme.of(context).textTheme.bodyMedium),
        const Spacer(),
        Text(value, style: Theme.of(context).textTheme.bodyLarge),
      ],
    );
  }
}
