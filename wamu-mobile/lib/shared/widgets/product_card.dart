import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../core/theme/app_theme.dart';
import '../models/product_model.dart';
import '../utils/ugx_formatter.dart';
import 'wamu_network_image.dart';

/// Merchant listing card — image, name, and UGX price only (no description).
class ProductCard extends StatefulWidget {
  const ProductCard({
    super.key,
    required this.product,
    this.onAddToCart,
  });

  final ProductModel product;
  final VoidCallback? onAddToCart;

  @override
  State<ProductCard> createState() => _ProductCardState();
}

class _ProductCardState extends State<ProductCard>
    with SingleTickerProviderStateMixin {
  bool _pressed = false;
  late final AnimationController _shimmer;

  @override
  void initState() {
    super.initState();
    _shimmer = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 2200),
    )..repeat(reverse: true);
  }

  @override
  void dispose() {
    _shimmer.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final product = widget.product;
    final theme = Theme.of(context);
    final onSurface = theme.colorScheme.onSurface;
    final cardColor = theme.brightness == Brightness.dark
        ? AppTheme.messengerElevated
        : theme.colorScheme.surface;
    return AnimatedScale(
      scale: _pressed ? 0.97 : 1,
      duration: const Duration(milliseconds: 140),
      curve: Curves.easeOut,
      child: Material(
        color: cardColor,
        elevation: 0,
        borderRadius: BorderRadius.circular(18),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: () => context.push('/product/${product.id}'),
          onHighlightChanged: (v) => setState(() => _pressed = v),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Expanded(
                flex: 7,
                child: Stack(
                  fit: StackFit.expand,
                  children: [
                    AnimatedScale(
                      scale: _pressed ? 1.05 : 1.0,
                      duration: const Duration(milliseconds: 280),
                      curve: Curves.easeOutCubic,
                      child: LayoutBuilder(
                        builder: (context, constraints) {
                          return WamuNetworkImage(
                            imageUrl: product.imageUrl,
                            width: constraints.maxWidth,
                            height: constraints.maxHeight,
                          );
                        },
                      ),
                    ),
                    const DecoratedBox(
                      decoration: BoxDecoration(
                        gradient: LinearGradient(
                          begin: Alignment.topCenter,
                          end: Alignment.bottomCenter,
                          colors: [
                            Color(0x00000000),
                            Color(0x22000000),
                            Color(0x99000000),
                          ],
                          stops: [0.45, 0.75, 1],
                        ),
                      ),
                    ),
                    Positioned(
                      left: 10,
                      bottom: 10,
                      child: AnimatedBuilder(
                        animation: _shimmer,
                        builder: (context, child) {
                          final glow = 0.22 + (_shimmer.value * 0.28);
                          return Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 10,
                              vertical: 6,
                            ),
                            decoration: BoxDecoration(
                              color: AppTheme.accentGreen,
                              borderRadius: BorderRadius.circular(999),
                              boxShadow: [
                                BoxShadow(
                                  color: AppTheme.accentGreen.withValues(alpha: glow),
                                  blurRadius: 12,
                                  offset: const Offset(0, 3),
                                ),
                              ],
                            ),
                            child: child,
                          );
                        },
                        child: Text(
                          formatUgx(product.price),
                          style: const TextStyle(
                            color: Colors.black,
                            fontSize: 12,
                            fontWeight: FontWeight.w800,
                          ),
                        ),
                      ),
                    ),
                    if (!product.inStock)
                      Positioned(
                        top: 10,
                        left: 10,
                        child: Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 8,
                            vertical: 4,
                          ),
                          decoration: BoxDecoration(
                            color: Colors.black.withValues(alpha: 0.72),
                            borderRadius: BorderRadius.circular(8),
                          ),
                          child: const Text(
                            'Sold out',
                            style: TextStyle(
                              color: Colors.white,
                              fontSize: 11,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ),
                      ),
                    if (widget.onAddToCart != null && product.inStock)
                      Positioned(
                        top: 8,
                        right: 8,
                        child: Material(
                          color: Colors.black.withValues(alpha: 0.55),
                          shape: const CircleBorder(),
                          child: IconButton(
                            visualDensity: VisualDensity.compact,
                            padding: EdgeInsets.zero,
                            constraints: const BoxConstraints(
                              minWidth: 36,
                              minHeight: 36,
                            ),
                            icon: const Icon(
                              Icons.add_shopping_cart_rounded,
                              color: Colors.white,
                              size: 18,
                            ),
                            onPressed: widget.onAddToCart,
                          ),
                        ),
                      ),
                  ],
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(12, 10, 12, 12),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      product.name,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: onSurface,
                        fontWeight: FontWeight.w700,
                        fontSize: 14,
                        height: 1.25,
                      ),
                    ),
                    const SizedBox(height: 6),
                    Text(
                      formatUgx(product.price),
                      style: const TextStyle(
                        color: AppTheme.accentGreen,
                        fontWeight: FontWeight.w800,
                        fontSize: 13,
                      ),
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

/// 2-column product grid that calls [onNearEnd] for infinite scroll.
class ProductInfiniteGrid extends StatelessWidget {
  const ProductInfiniteGrid({
    super.key,
    required this.products,
    required this.hasMore,
    required this.loadingMore,
    required this.onNearEnd,
    this.onAddToCart,
    this.padding = const EdgeInsets.symmetric(horizontal: 16),
    this.shrinkWrap = false,
    this.physics,
  });

  final List<ProductModel> products;
  final bool hasMore;
  final bool loadingMore;
  final VoidCallback onNearEnd;
  final void Function(ProductModel product)? onAddToCart;
  final EdgeInsetsGeometry padding;
  final bool shrinkWrap;
  final ScrollPhysics? physics;

  @override
  Widget build(BuildContext context) {
    final extra = (hasMore || loadingMore) ? 1 : 0;
    return NotificationListener<ScrollNotification>(
      onNotification: (n) {
        if (n.metrics.axis != Axis.vertical) return false;
        if (n.metrics.pixels >= n.metrics.maxScrollExtent - 480) {
          onNearEnd();
        }
        return false;
      },
      child: GridView.builder(
        shrinkWrap: shrinkWrap,
        physics: physics,
        padding: padding,
        gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
          crossAxisCount: 2,
          childAspectRatio: 0.68,
          crossAxisSpacing: 12,
          mainAxisSpacing: 14,
        ),
        itemCount: products.length + extra,
        itemBuilder: (context, index) {
          if (index >= products.length) {
            return const Center(
              child: Padding(
                padding: EdgeInsets.all(16),
                child: SizedBox(
                  width: 28,
                  height: 28,
                  child: CircularProgressIndicator(strokeWidth: 2.5),
                ),
              ),
            );
          }
          final product = products[index];
          return ProductCard(
            key: ValueKey('product_${product.id}'),
            product: product,
            onAddToCart: onAddToCart == null ? null : () => onAddToCart!(product),
          );
        },
      ),
    );
  }
}

/// Sliver variant for [CustomScrollView] shop pages.
class ProductInfiniteSliverGrid extends StatelessWidget {
  const ProductInfiniteSliverGrid({
    super.key,
    required this.products,
    required this.hasMore,
    required this.loadingMore,
    this.onAddToCart,
    this.padding = const EdgeInsets.fromLTRB(16, 0, 16, 8),
  });

  final List<ProductModel> products;
  final bool hasMore;
  final bool loadingMore;
  final void Function(ProductModel product)? onAddToCart;
  final EdgeInsets padding;

  @override
  Widget build(BuildContext context) {
    final extra = (hasMore || loadingMore) ? 1 : 0;
    return SliverPadding(
      padding: padding,
      sliver: products.isEmpty && !loadingMore
          ? const SliverToBoxAdapter(child: SizedBox.shrink())
          : SliverGrid(
              gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                crossAxisCount: 2,
                childAspectRatio: 0.68,
                crossAxisSpacing: 12,
                mainAxisSpacing: 14,
              ),
              delegate: SliverChildBuilderDelegate(
                (context, index) {
                  if (index >= products.length) {
                    return const Center(
                      child: Padding(
                        padding: EdgeInsets.all(12),
                        child: SizedBox(
                          width: 28,
                          height: 28,
                          child: CircularProgressIndicator(strokeWidth: 2.5),
                        ),
                      ),
                    );
                  }
                  final product = products[index];
                  return ProductCard(
                    key: ValueKey('product_${product.id}'),
                    product: product,
                    onAddToCart:
                        onAddToCart == null ? null : () => onAddToCart!(product),
                  );
                },
                childCount: products.length + extra,
              ),
            ),
    );
  }
}
