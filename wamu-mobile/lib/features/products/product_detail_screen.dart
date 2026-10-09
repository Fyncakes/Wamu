import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/theme/app_theme.dart';
import '../../shared/models/product_model.dart';
import '../../shared/utils/ugx_formatter.dart';
import '../../shared/widgets/error_view.dart';
import '../../shared/widgets/loading_view.dart';
import '../../shared/widgets/wamu_network_image.dart';
import '../cart/cart_provider.dart';
import '../chat/chat_repository.dart';
import '../home/catalog_repository.dart';

/// Product detail — image, name, description, UGX price, discovery rails.
class ProductDetailScreen extends ConsumerStatefulWidget {
  const ProductDetailScreen({super.key, required this.productId});

  final String productId;

  @override
  ConsumerState<ProductDetailScreen> createState() => _ProductDetailScreenState();
}

class _ProductDetailScreenState extends ConsumerState<ProductDetailScreen> {
  late Future<ProductModel> _future;
  late Future<
      ({
        List<ProductModel> items,
        List<ProductModel> sameShop,
        List<ProductModel> sameCategory,
        List<ProductModel> popular,
      })> _relatedFuture;
  bool _sharing = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void didUpdateWidget(covariant ProductDetailScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.productId != widget.productId) {
      _load();
    }
  }

  void _load() {
    final catalog = ref.read(catalogRepositoryProvider);
    _future = catalog.getProduct(widget.productId);
    _relatedFuture = catalog.getRelatedProducts(widget.productId);
  }

  Future<void> _shareToChat(ProductModel product) async {
    final bizId = product.businessId;
    if (bizId == null || bizId.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('No business linked to this product')),
      );
      return;
    }
    setState(() => _sharing = true);
    try {
      final price = formatUgx(product.price);
      final msg =
          '🛒 ${product.name} — $price\nInterested on Wamu Discover. Is this still available?';
      final convo = await ref.read(chatRepositoryProvider).startConversation(
            bizId,
            message: msg,
          );
      if (mounted) context.push('/chat/${convo.id}');
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('$e')));
      }
    } finally {
      if (mounted) setState(() => _sharing = false);
    }
  }

  void _addToCart(ProductModel product) {
    try {
      ref.read(cartProvider.notifier).addProduct(product);
      final shops = ref.read(cartProvider.notifier).shopCount;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            shops > 1
                ? 'Added · $shops shops in your bag'
                : 'Added to cart',
          ),
        ),
      );
    } catch (e) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('$e')),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Product')),
      body: FutureBuilder<ProductModel>(
        future: _future,
        builder: (context, snapshot) {
          if (snapshot.connectionState == ConnectionState.waiting) {
            return const LoadingView();
          }
          if (snapshot.hasError) {
            return ErrorView(message: '${snapshot.error}');
          }
          final product = snapshot.data!;
          final description = (product.description ?? '').trim();
          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Expanded(
                child: ListView(
                  padding: EdgeInsets.zero,
                  children: [
                    WamuNetworkImage(
                      imageUrl: product.imageUrl,
                      height: 320,
                      width: double.infinity,
                    ),
                    Padding(
                      padding: const EdgeInsets.fromLTRB(20, 20, 20, 8),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            product.name,
                            style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                                  fontWeight: FontWeight.w800,
                                ),
                          ),
                          const SizedBox(height: 10),
                          Text(
                            formatUgx(product.price),
                            style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                                  color: AppTheme.accentGreen,
                                  fontWeight: FontWeight.w800,
                                ),
                          ),
                          const SizedBox(height: 18),
                          Text(
                            'Description',
                            style: Theme.of(context).textTheme.titleMedium?.copyWith(
                                  fontWeight: FontWeight.w700,
                                ),
                          ),
                          const SizedBox(height: 8),
                          Text(
                            description.isNotEmpty
                                ? description
                                : 'No description provided for this product.',
                            style: Theme.of(context).textTheme.bodyLarge?.copyWith(
                                  height: 1.45,
                                  color: AppTheme.messengerMuted,
                                ),
                          ),
                          if (product.businessId != null) ...[
                            const SizedBox(height: 20),
                            TextButton.icon(
                              onPressed: () =>
                                  context.push('/business/${product.businessId}'),
                              icon: const Icon(Icons.storefront_outlined),
                              label: const Text('View merchant shop'),
                            ),
                          ],
                        ],
                      ),
                    ),
                    FutureBuilder(
                      future: _relatedFuture,
                      builder: (context, relatedSnap) {
                        if (relatedSnap.connectionState == ConnectionState.waiting) {
                          return const Padding(
                            padding: EdgeInsets.symmetric(vertical: 32),
                            child: Center(
                              child: SizedBox(
                                width: 28,
                                height: 28,
                                child: CircularProgressIndicator(strokeWidth: 2),
                              ),
                            ),
                          );
                        }
                        final data = relatedSnap.data;
                        if (data == null) return const SizedBox.shrink();
                        return Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            if (data.sameShop.isNotEmpty)
                              _ProductRail(
                                title: 'More from this shop',
                                subtitle: 'Keep browsing this merchant',
                                products: data.sameShop,
                                onOpen: (p) => context.push('/product/${p.id}'),
                                onAdd: _addToCart,
                              ),
                            if (data.sameCategory.isNotEmpty)
                              _ProductRail(
                                title: 'Similar products',
                                subtitle: 'Same category · other shops',
                                products: data.sameCategory,
                                onOpen: (p) => context.push('/product/${p.id}'),
                                onAdd: _addToCart,
                              ),
                            if (data.popular.isNotEmpty)
                              _ProductRail(
                                title: 'Recommended for you',
                                subtitle: 'Popular picks nearby',
                                products: data.popular,
                                onOpen: (p) => context.push('/product/${p.id}'),
                                onAdd: _addToCart,
                              ),
                            if (data.sameShop.isEmpty &&
                                data.sameCategory.isEmpty &&
                                data.popular.isEmpty &&
                                data.items.isNotEmpty)
                              _ProductRail(
                                title: 'You may also like',
                                subtitle: 'Keep discovering on Wamu',
                                products: data.items,
                                onOpen: (p) => context.push('/product/${p.id}'),
                                onAdd: _addToCart,
                              ),
                            const SizedBox(height: 12),
                          ],
                        );
                      },
                    ),
                  ],
                ),
              ),
              SafeArea(
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      SizedBox(
                        width: double.infinity,
                        child: OutlinedButton.icon(
                          onPressed: _sharing ? null : () => _shareToChat(product),
                          icon: _sharing
                              ? const SizedBox(
                                  width: 18,
                                  height: 18,
                                  child: CircularProgressIndicator(strokeWidth: 2),
                                )
                              : const Icon(Icons.chat_bubble_outline),
                          label: const Text('Chat to order'),
                        ),
                      ),
                      const SizedBox(height: 8),
                      SizedBox(
                        width: double.infinity,
                        child: FilledButton.icon(
                          onPressed: !product.inStock ? null : () => _addToCart(product),
                          icon: const Icon(Icons.add_shopping_cart),
                          label: Text(product.inStock ? 'Add to cart' : 'Sold out'),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ],
          );
        },
      ),
    );
  }
}

class _ProductRail extends StatelessWidget {
  const _ProductRail({
    required this.title,
    required this.subtitle,
    required this.products,
    required this.onOpen,
    required this.onAdd,
  });

  final String title;
  final String subtitle;
  final List<ProductModel> products;
  final ValueChanged<ProductModel> onOpen;
  final ValueChanged<ProductModel> onAdd;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.only(top: 8, bottom: 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 12, 20, 4),
            child: Text(
              title,
              style: theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w800),
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 0, 20, 10),
            child: Text(
              subtitle,
              style: theme.textTheme.bodySmall?.copyWith(color: AppTheme.messengerMuted),
            ),
          ),
          SizedBox(
            height: 210,
            child: ListView.separated(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.symmetric(horizontal: 16),
              itemCount: products.length,
              separatorBuilder: (_, __) => const SizedBox(width: 12),
              itemBuilder: (context, i) {
                final p = products[i];
                return _RailCard(
                  product: p,
                  onOpen: () => onOpen(p),
                  onAdd: p.inStock ? () => onAdd(p) : null,
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}

class _RailCard extends StatelessWidget {
  const _RailCard({
    required this.product,
    required this.onOpen,
    required this.onAdd,
  });

  final ProductModel product;
  final VoidCallback onOpen;
  final VoidCallback? onAdd;

  @override
  Widget build(BuildContext context) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    return SizedBox(
      width: 148,
      child: Material(
        color: dark ? AppTheme.messengerElevated : Colors.white,
        borderRadius: BorderRadius.circular(16),
        child: InkWell(
          onTap: onOpen,
          borderRadius: BorderRadius.circular(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              ClipRRect(
                borderRadius: const BorderRadius.vertical(top: Radius.circular(16)),
                child: WamuNetworkImage(
                  imageUrl: product.imageUrl,
                  height: 108,
                  width: double.infinity,
                ),
              ),
              Expanded(
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(10, 8, 10, 8),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        product.name,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          fontWeight: FontWeight.w700,
                          fontSize: 13,
                          height: 1.2,
                        ),
                      ),
                      const Spacer(),
                      Row(
                        children: [
                          Expanded(
                            child: Text(
                              formatUgx(product.price),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                color: AppTheme.accentGreen,
                                fontWeight: FontWeight.w800,
                                fontSize: 12,
                              ),
                            ),
                          ),
                          if (onAdd != null)
                            InkWell(
                              onTap: onAdd,
                              customBorder: const CircleBorder(),
                              child: const Padding(
                                padding: EdgeInsets.all(4),
                                child: Icon(
                                  Icons.add_circle,
                                  color: AppTheme.accentGreen,
                                  size: 22,
                                ),
                              ),
                            ),
                        ],
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
