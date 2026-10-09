import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../shared/models/business_model.dart';
import '../../shared/models/product_model.dart';
import '../../shared/models/review_model.dart';
import '../../shared/widgets/error_view.dart';
import '../../shared/widgets/loading_view.dart';
import '../../shared/widgets/product_card.dart';
import '../../shared/widgets/wamu_network_image.dart';
import '../cart/cart_provider.dart';
import '../chat/chat_repository.dart';
import '../home/catalog_repository.dart';
import 'favorites_repository.dart';

/// Business storefront — product cards, reviews, chat, favorite.
class BusinessDetailScreen extends ConsumerStatefulWidget {
  const BusinessDetailScreen({
    super.key,
    required this.businessId,
    this.orderId,
  });

  final String businessId;
  /// When set (from a DELIVERED order CTA), enables verified review write.
  final String? orderId;

  @override
  ConsumerState<BusinessDetailScreen> createState() => _BusinessDetailScreenState();
}

class _BusinessDetailScreenState extends ConsumerState<BusinessDetailScreen> {
  BusinessModel? _business;
  List<ReviewModel> _reviews = [];
  final List<ProductModel> _products = [];
  Object? _error;

  bool _bootLoading = true;
  bool _isFavorite = false;
  bool _messaging = false;

  int _productPage = 0;
  bool _productsHasMore = true;
  bool _productsLoadingMore = false;
  static const _pageSize = 12;

  final _scrollController = ScrollController();

  @override
  void initState() {
    super.initState();
    _scrollController.addListener(_onScroll);
    _bootstrap();
    _loadFavoriteState();
  }

  @override
  void dispose() {
    _scrollController.removeListener(_onScroll);
    _scrollController.dispose();
    super.dispose();
  }

  void _onScroll() {
    if (!_productsHasMore || _productsLoadingMore) return;
    if (!_scrollController.hasClients) return;
    final pos = _scrollController.position;
    if (pos.pixels >= pos.maxScrollExtent - 520) {
      _loadMoreProducts();
    }
  }

  Future<void> _loadFavoriteState() async {
    try {
      final favs = await ref.read(favoritesRepositoryProvider).list();
      if (!mounted) return;
      setState(() {
        _isFavorite = favs.any((b) => b.id == widget.businessId);
      });
    } catch (_) {}
  }

  Future<void> _bootstrap() async {
    setState(() {
      _bootLoading = true;
      _error = null;
      _products.clear();
      _productPage = 0;
      _productsHasMore = true;
    });
    final catalog = ref.read(catalogRepositoryProvider);
    try {
      final business = await catalog.getBusiness(widget.businessId);
      final reviews = await catalog.getReviews(widget.businessId);
      if (!mounted) return;
      setState(() {
        _business = business;
        _reviews = reviews;
        _bootLoading = false;
      });
      await _loadMoreProducts();
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e;
        _bootLoading = false;
      });
    }
  }

  Future<void> _loadMoreProducts() async {
    if (_productsLoadingMore || !_productsHasMore) return;
    setState(() => _productsLoadingMore = true);
    final nextPage = _productPage + 1;
    try {
      final page = await ref.read(catalogRepositoryProvider).getProducts(
            businessId: widget.businessId,
            page: nextPage,
            pageSize: _pageSize,
          );
      if (!mounted) return;
      setState(() {
        _productPage = nextPage;
        _products.addAll(page.items);
        _productsHasMore = page.hasMore;
        _productsLoadingMore = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() => _productsLoadingMore = false);
    }
  }

  Future<void> _toggleFavorite() async {
    final repo = ref.read(favoritesRepositoryProvider);
    if (_isFavorite) {
      await repo.removeFavorite(widget.businessId);
    } else {
      await repo.addFavorite(widget.businessId);
    }
    setState(() => _isFavorite = !_isFavorite);
  }

  Future<void> _messageBusiness() async {
    setState(() => _messaging = true);
    try {
      final convo = await ref.read(chatRepositoryProvider).startConversation(
            widget.businessId,
            message: 'Hi! I found you on WAMU.',
          );
      if (mounted) context.push('/chat/${convo.id}');
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('$e')));
      }
    } finally {
      if (mounted) setState(() => _messaging = false);
    }
  }

  void _addToCart(ProductModel product) {
    try {
      ref.read(cartProvider.notifier).addProduct(product);
      final shops = ref.read(cartProvider.notifier).shopCount;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            shops > 1 ? 'Added · $shops shops in your bag' : 'Added to cart',
          ),
        ),
      );
    } catch (e) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('$e')));
    }
  }

  Future<void> _writeReview() async {
    final orderId = widget.orderId?.trim();
    if (orderId == null || orderId.isEmpty) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Leave a review from a delivered order'),
          ),
        );
      }
      return;
    }
    var rating = 5;
    final commentController = TextEditingController();
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setLocal) => AlertDialog(
          title: const Text('Rate this business'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: List.generate(5, (i) {
                  final star = i + 1;
                  return IconButton(
                    onPressed: () => setLocal(() => rating = star),
                    icon: Icon(
                      star <= rating ? Icons.star : Icons.star_border,
                      color: Colors.amber,
                    ),
                  );
                }),
              ),
              TextField(
                controller: commentController,
                decoration: const InputDecoration(hintText: 'Optional comment'),
                maxLines: 3,
              ),
            ],
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
            ElevatedButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Submit')),
          ],
        ),
      ),
    );
    if (ok != true || !mounted) return;
    try {
      await ref.read(reviewsRepositoryProvider).postReview(
            businessId: widget.businessId,
            orderId: orderId,
            rating: rating,
            comment: commentController.text.trim(),
          );
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Thanks for your review!')),
        );
        final reviews =
            await ref.read(catalogRepositoryProvider).getReviews(widget.businessId);
        if (mounted) setState(() => _reviews = reviews);
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('$e')));
      }
    } finally {
      commentController.dispose();
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_bootLoading && _business == null) {
      return const Scaffold(body: LoadingView());
    }
    if (_error != null && _business == null) {
      return Scaffold(
        body: ErrorView(message: '$_error', onRetry: _bootstrap),
      );
    }
    final business = _business!;
    final reviews = _reviews;

    return Scaffold(
      body: RefreshIndicator(
        onRefresh: _bootstrap,
        child: CustomScrollView(
          controller: _scrollController,
          slivers: [
            SliverAppBar(
              expandedHeight: 280,
              pinned: true,
              stretch: true,
              backgroundColor: const Color(0xFF0B141A),
              actions: [
                IconButton(
                  icon: Icon(_isFavorite ? Icons.favorite : Icons.favorite_border),
                  onPressed: _toggleFavorite,
                ),
              ],
              flexibleSpace: FlexibleSpaceBar(
                stretchModes: const [
                  StretchMode.zoomBackground,
                  StretchMode.fadeTitle,
                ],
                background: _ShopCoverHero(
                  coverUrl: business.coverUrl,
                  logoUrl: business.imageUrl,
                  shopName: business.name,
                ),
              ),
            ),
            SliverToBoxAdapter(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(16, 16, 16, 0),
                child: Row(
                  children: [
                    ClipRRect(
                      borderRadius: BorderRadius.circular(14),
                      child: WamuNetworkImage(
                        imageUrl: business.imageUrl ?? business.coverUrl,
                        width: 56,
                        height: 56,
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            business.name,
                            style: Theme.of(context).textTheme.titleLarge?.copyWith(
                                  fontWeight: FontWeight.w800,
                                ),
                          ),
                          if (business.rating != null)
                            Text(
                              '★ ${business.rating!.toStringAsFixed(1)} · ${business.reviewCount ?? 0} reviews',
                            ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ),
            SliverToBoxAdapter(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    if (business.isVerified)
                      Chip(
                        avatar: Icon(
                          Icons.verified,
                          size: 16,
                          color: Theme.of(context).colorScheme.primary,
                        ),
                        label: const Text('Verified on WAMU'),
                      ),
                    if (business.address != null) Text(business.address!),
                    if (business.description != null) ...[
                      const SizedBox(height: 8),
                      Text(business.description!),
                    ],
                    const SizedBox(height: 12),
                    Row(
                      children: [
                        Expanded(
                          child: ElevatedButton.icon(
                            onPressed: _messaging ? null : _messageBusiness,
                            icon: const Icon(Icons.chat_bubble_outline),
                            label: const Text('Chat'),
                          ),
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: OutlinedButton.icon(
                            onPressed: () => context.push('/cart'),
                            icon: const Icon(Icons.shopping_cart_outlined),
                            label: const Text('Cart'),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 20),
                    Row(
                      children: [
                        Text('Products', style: Theme.of(context).textTheme.titleLarge),
                        const Spacer(),
                        Text(
                          '${_products.length}${_productsHasMore ? '+' : ''} items',
                          style: Theme.of(context).textTheme.bodySmall,
                        ),
                      ],
                    ),
                    const SizedBox(height: 4),
                    Text(
                      'Scroll for more from this shop',
                      style: Theme.of(context).textTheme.bodyMedium,
                    ),
                  ],
                ),
              ),
            ),
            if (_products.isEmpty && !_productsLoadingMore)
              const SliverToBoxAdapter(
                child: Padding(
                  padding: EdgeInsets.all(16),
                  child: Text('No products listed yet.'),
                ),
              )
            else
              ProductInfiniteSliverGrid(
                products: _products,
                hasMore: _productsHasMore,
                loadingMore: _productsLoadingMore,
                onAddToCart: _addToCart,
              ),
            SliverToBoxAdapter(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Row(
                  children: [
                    Expanded(
                      child: Text(
                        'Reviews (${reviews.length})',
                        style: Theme.of(context).textTheme.titleLarge,
                      ),
                    ),
                    TextButton.icon(
                      onPressed: _writeReview,
                      icon: const Icon(Icons.rate_review_outlined),
                      label: Text(
                        (widget.orderId ?? '').isNotEmpty ? 'Write review' : 'Write',
                      ),
                    ),
                  ],
                ),
              ),
            ),
            SliverList(
              delegate: SliverChildBuilderDelegate(
                (context, index) {
                  final review = reviews[index];
                  final reply = review.reply?.trim();
                  return ListTile(
                    leading: const Icon(Icons.star, color: Colors.amber),
                    title: Text('${review.rating}/5'),
                    subtitle: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        if ((review.comment ?? '').isNotEmpty) Text(review.comment!),
                        if (reply != null && reply.isNotEmpty) ...[
                          const SizedBox(height: 6),
                          Text(
                            'Owner: $reply',
                            style: Theme.of(context).textTheme.bodySmall?.copyWith(
                                  fontStyle: FontStyle.italic,
                                ),
                          ),
                        ],
                      ],
                    ),
                    isThreeLine: reply != null && reply.isNotEmpty,
                  );
                },
                childCount: reviews.length,
              ),
            ),
            const SliverToBoxAdapter(child: SizedBox(height: 32)),
          ],
        ),
      ),
    );
  }
}

/// Full-bleed shop cover for the merchant product page hero.
class _ShopCoverHero extends StatelessWidget {
  const _ShopCoverHero({
    required this.coverUrl,
    required this.logoUrl,
    required this.shopName,
  });

  final String? coverUrl;
  final String? logoUrl;
  final String shopName;

  @override
  Widget build(BuildContext context) {
    final cover = (coverUrl ?? '').trim().isNotEmpty
        ? coverUrl
        : ((logoUrl ?? '').trim().isNotEmpty ? logoUrl : null);

    return Stack(
      fit: StackFit.expand,
      children: [
        WamuNetworkImage(
          imageUrl: cover,
          width: double.infinity,
          height: double.infinity,
          fit: BoxFit.cover,
          alignment: Alignment.center,
        ),
        const DecoratedBox(
          decoration: BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
              colors: [
                Color(0x66000000),
                Color(0x00000000),
                Color(0xCC000000),
              ],
              stops: [0.0, 0.45, 1.0],
            ),
          ),
        ),
        Positioned(
          left: 16,
          right: 16,
          bottom: 20,
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              Container(
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(16),
                  border: Border.all(color: Colors.white24, width: 2),
                  boxShadow: const [
                    BoxShadow(
                      color: Color(0x66000000),
                      blurRadius: 12,
                      offset: Offset(0, 4),
                    ),
                  ],
                ),
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(14),
                  child: WamuNetworkImage(
                    imageUrl: logoUrl ?? coverUrl,
                    width: 64,
                    height: 64,
                  ),
                ),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      shopName,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 22,
                        fontWeight: FontWeight.w800,
                        height: 1.15,
                        shadows: [
                          Shadow(color: Color(0xAA000000), blurRadius: 8),
                        ],
                      ),
                    ),
                    const SizedBox(height: 4),
                    const Text(
                      'Tap products below to order',
                      style: TextStyle(
                        color: Colors.white70,
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}
