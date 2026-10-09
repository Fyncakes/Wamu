import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/theme/app_theme.dart';
import '../../shared/models/business_model.dart';
import '../../shared/models/category_model.dart';
import '../../shared/models/product_model.dart';
import '../../shared/widgets/error_view.dart';
import '../../shared/widgets/loading_view.dart';
import '../../shared/widgets/product_card.dart';
import '../../shared/widgets/wamu_network_image.dart';
import '../chat/chat_repository.dart';
import '../home/catalog_repository.dart';
import '../home/nearby_location.dart';

/// Shops home — nearby merchants, categories, products (Master Plan v3 MVP).
class HomeScreen extends ConsumerStatefulWidget {
  const HomeScreen({super.key});

  @override
  ConsumerState<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends ConsumerState<HomeScreen> {
  ({List<CategoryModel> categories, List<BusinessModel> nearby})? _lastData;
  Object? _loadError;
  String? _selectedCategoryId;
  /// null = use GPS / auto; otherwise a Kampala area id.
  String? _areaId;
  NearbyOrigin _origin = const NearbyOrigin(
    label: 'Greater Kampala',
    lat: kampalaFallbackLat,
    lng: kampalaFallbackLng,
    radiusKm: kampalaFallbackRadiusKm,
    fromGps: false,
  );
  bool _locating = true;
  final _pageController = PageController(viewportFraction: 0.88);
  int _showcaseIndex = 0;
  Timer? _liveTimer;
  Timer? _carouselTimer;
  String? _messagingId;

  final _scrollController = ScrollController();
  final List<ProductModel> _products = [];
  int _productPage = 0;
  bool _productsHasMore = true;
  bool _productsLoadingMore = false;
  static const _productPageSize = 12;

  @override
  void initState() {
    super.initState();
    _scrollController.addListener(_onScroll);
    _load(resolveLocation: true);
    // Soft live refresh so new shops / ratings appear while browsing
    _liveTimer = Timer.periodic(const Duration(seconds: 25), (_) {
      if (!mounted) return;
      _load(resolveLocation: false);
    });
  }

  @override
  void dispose() {
    _liveTimer?.cancel();
    _carouselTimer?.cancel();
    _scrollController.removeListener(_onScroll);
    _scrollController.dispose();
    _pageController.dispose();
    super.dispose();
  }

  void _onScroll() {
    if (!_productsHasMore || _productsLoadingMore) return;
    if (!_scrollController.hasClients) return;
    final pos = _scrollController.position;
    if (pos.pixels >= pos.maxScrollExtent - 560) {
      _loadMoreProducts();
    }
  }

  Future<void> _load({bool resolveLocation = false}) async {
    if (resolveLocation) {
      setState(() => _locating = true);
      final origin = await resolveNearbyOrigin(
        preferGps: _areaId == null,
        areaId: _areaId,
      );
      if (!mounted) return;
      setState(() {
        _origin = origin;
        _locating = false;
      });
    }

    final repo = ref.read(catalogRepositoryProvider);
    final origin = _origin;
    final isFirst = _lastData == null;
    if (isFirst) {
      setState(() {
        _loadError = null;
      });
    }
    try {
      final categories = await repo.getCategories();
      final nearbyRaw = await repo.getBusinesses(
        categoryId: _selectedCategoryId,
        lat: origin.lat,
        lng: origin.lng,
        radiusKm: origin.radiusKm,
      );
      // Hide listings with no imagery (broken / unregistered media).
      final nearby = nearbyRaw
          .where(
            (b) =>
                (b.imageUrl ?? '').trim().isNotEmpty ||
                (b.coverUrl ?? '').trim().isNotEmpty,
          )
          .toList();
      final data = (categories: categories, nearby: nearby);
      if (!mounted) return;
      // Soft update in place — no FutureBuilder swap, so images stay warm.
      setState(() {
        _lastData = data;
        _loadError = null;
      });
      // First paint (or pull-to-refresh with location): reset product pages.
      if (isFirst || resolveLocation) {
        _products.clear();
        _productPage = 0;
        _productsHasMore = true;
        await _loadMoreProducts();
      }
    } catch (e) {
      if (!mounted) return;
      if (_lastData != null) {
        // Soft failure: keep showing previous shops/products.
        return;
      }
      setState(() {
        _loadError = e;
      });
    }
  }

  Future<void> _loadMoreProducts() async {
    if (_productsLoadingMore || !_productsHasMore) return;
    setState(() => _productsLoadingMore = true);
    final nextPage = _productPage + 1;
    try {
      final page = await ref.read(catalogRepositoryProvider).getProducts(
            page: nextPage,
            pageSize: _productPageSize,
          );
      if (!mounted) return;
      // Deduplicate if soft refresh races with pagination.
      final seen = _products.map((p) => p.id).toSet();
      final fresh = page.items.where((p) => !seen.contains(p.id)).toList();
      setState(() {
        _productPage = nextPage;
        _products.addAll(fresh);
        _productsHasMore = page.hasMore;
        _productsLoadingMore = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() => _productsLoadingMore = false);
    }
  }

  int _carouselArmedFor = -1;

  void _armCarousel(int count) {
    if (count == _carouselArmedFor) return;
    _carouselArmedFor = count;
    _carouselTimer?.cancel();
    if (count < 2) return;
    _carouselTimer = Timer.periodic(const Duration(seconds: 4), (_) {
      if (!mounted || !_pageController.hasClients) return;
      final next = (_showcaseIndex + 1) % count;
      _pageController.animateToPage(
        next,
        duration: const Duration(milliseconds: 450),
        curve: Curves.easeOutCubic,
      );
    });
  }

  Future<void> _chatWith(BusinessModel business) async {
    setState(() => _messagingId = business.id);
    try {
      final convo = await ref.read(chatRepositoryProvider).startConversation(
            business.id,
            message: 'Hi ${business.name}! I saw you on Wamu Discover.',
          );
      if (mounted) context.go('/chats');
      if (mounted) context.push('/chat/${convo.id}');
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('$e')));
      }
    } finally {
      if (mounted) setState(() => _messagingId = null);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Scaffold(
      appBar: AppBar(
        title: Text(
          'Shops',
          style: (theme.textTheme.headlineSmall ?? theme.textTheme.titleLarge)?.copyWith(
            fontWeight: FontWeight.w700,
            color: theme.colorScheme.onSurface,
          ),
        ),
        actions: [
          if (_locating)
            const Padding(
              padding: EdgeInsets.only(right: 8),
              child: Center(
                child: SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
              ),
            ),
          IconButton(
            tooltip: 'Use my location',
            icon: Icon(
              Icons.my_location,
              color: _origin.fromGps ? AppTheme.accentGreen : null,
            ),
            onPressed: _locating
                ? null
                : () {
                    setState(() => _areaId = null);
                    _load(resolveLocation: true);
                  },
          ),
          IconButton(
            tooltip: 'Search',
            icon: const Icon(Icons.search),
            onPressed: () => context.push('/search'),
          ),
          IconButton(
            icon: const Icon(Icons.shopping_cart_outlined),
            onPressed: () => context.push('/cart'),
          ),
        ],
      ),
      body: _lastData == null
          ? (_loadError != null
              ? ErrorView(
                  message: '$_loadError',
                  onRetry: () => _load(resolveLocation: true),
                )
              : LoadingView(
                  message: _locating ? 'Finding shops near you…' : 'Loading nearby shops…',
                ))
          : Builder(
              builder: (context) {
          final data = _lastData!;
          _armCarousel(data.nearby.length);
          final empty = data.nearby.isEmpty;

          return RefreshIndicator(
            color: AppTheme.accentGreen,
            onRefresh: () => _load(resolveLocation: true),
            child: ListView(
              controller: _scrollController,
              cacheExtent: 1200,
              padding: const EdgeInsets.fromLTRB(0, 8, 0, 32),
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
                  child: SizedBox(
                    height: 40,
                    child: ListView.separated(
                      scrollDirection: Axis.horizontal,
                      itemCount: kampalaAreas.length + 1,
                      separatorBuilder: (_, __) => const SizedBox(width: 8),
                      itemBuilder: (context, index) {
                        if (index == 0) {
                          final selected = _areaId == null;
                          return ChoiceChip(
                            avatar: Icon(
                              Icons.my_location,
                              size: 16,
                              color: selected
                                  ? (theme.brightness == Brightness.dark
                                      ? AppTheme.accentGreen
                                      : Colors.black)
                                  : theme.colorScheme.onSurfaceVariant,
                            ),
                            label: Text(
                              _origin.fromGps && selected ? 'Near you' : 'Near me',
                              style: TextStyle(
                                color: theme.colorScheme.onSurface,
                                fontWeight: selected ? FontWeight.w600 : FontWeight.w500,
                              ),
                            ),
                            selected: selected,
                            onSelected: (_) {
                              setState(() => _areaId = null);
                              _load(resolveLocation: true);
                            },
                          );
                        }
                        final area = kampalaAreas[index - 1];
                        final selected = area.id == _areaId;
                        return ChoiceChip(
                          label: Text(
                            area.label,
                            style: TextStyle(
                              color: theme.colorScheme.onSurface,
                              fontWeight: selected ? FontWeight.w600 : FontWeight.w500,
                            ),
                          ),
                          selected: selected,
                          onSelected: (_) {
                            setState(() => _areaId = area.id);
                            _load(resolveLocation: true);
                          },
                        );
                      },
                    ),
                  ),
                ),
                if (empty)
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
                    child: _EmptyShopsCard(
                      onSell: () => context.push('/business-owner/create'),
                      onBrowseRoles: () => context.go('/settings'),
                    ),
                  ),
                const SizedBox(height: 20),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  child: Row(
                    children: [
                      Expanded(
                        child: Text(
                          empty
                              ? 'Nearby in ${_origin.label}'
                              : 'Live near ${_origin.label}',
                          style: theme.textTheme.titleLarge?.copyWith(
                            color: theme.colorScheme.onSurface,
                          ),
                        ),
                      ),
                      if (!empty) ...[
                        const SizedBox(width: 8),
                        Container(
                          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                          decoration: BoxDecoration(
                            color: AppTheme.accentGreen.withValues(alpha: 0.18),
                            borderRadius: BorderRadius.circular(8),
                          ),
                          child: Text(
                            '${data.nearby.length} shops',
                            style: TextStyle(
                              fontSize: 12,
                              fontWeight: FontWeight.w700,
                              color: theme.brightness == Brightness.dark
                                  ? AppTheme.accentGreen
                                  : AppTheme.primaryDark,
                            ),
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 4, 16, 12),
                  child: Text(
                    empty
                        ? 'Be the first merchant in ${_origin.label} — or pull to refresh'
                        : _origin.fromGps
                            ? 'Shops within ${_origin.radiusKm.toStringAsFixed(0)} km of you'
                            : 'Kampala businesses you can message and order from',
                    style: theme.textTheme.bodyMedium?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                ),
                const SizedBox(height: 12),
                if (!empty)
                  SizedBox(
                    height: 236,
                    child: PageView.builder(
                      controller: _pageController,
                      itemCount: data.nearby.length,
                      onPageChanged: (i) => setState(() => _showcaseIndex = i),
                      itemBuilder: (context, index) {
                        final b = data.nearby[index];
                        final selected = index == _showcaseIndex;
                        return Padding(
                          padding: const EdgeInsets.only(right: 10),
                          child: AnimatedScale(
                            scale: selected ? 1.0 : 0.94,
                            duration: const Duration(milliseconds: 280),
                            curve: Curves.easeOutCubic,
                            child: AnimatedOpacity(
                              opacity: selected ? 1 : 0.78,
                              duration: const Duration(milliseconds: 280),
                              child: _ShowcaseCard(
                                key: ValueKey(b.id),
                                business: b,
                                messaging: _messagingId == b.id,
                                onOpen: () => context.push('/business/${b.id}'),
                                onChat: () => _chatWith(b),
                              ),
                            ),
                          ),
                        );
                      },
                    ),
                  ),
                const SizedBox(height: 20),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  child: Text(
                    'Categories',
                    style: theme.textTheme.titleLarge?.copyWith(
                      color: theme.colorScheme.onSurface,
                    ),
                  ),
                ),
                const SizedBox(height: 12),
                SizedBox(
                  height: 44,
                  child: ListView.separated(
                    padding: const EdgeInsets.symmetric(horizontal: 16),
                    scrollDirection: Axis.horizontal,
                    itemCount: data.categories.length + 1,
                    separatorBuilder: (_, __) => const SizedBox(width: 8),
                    itemBuilder: (context, index) {
                      if (index == 0) {
                        final selected = _selectedCategoryId == null;
                        return ChoiceChip(
                          label: Text(
                            'All',
                            style: TextStyle(
                              color: theme.colorScheme.onSurface,
                              fontWeight: selected ? FontWeight.w600 : FontWeight.w500,
                            ),
                          ),
                          selected: selected,
                          onSelected: (_) {
                            setState(() {
                              _selectedCategoryId = null;
                              _load();
                            });
                          },
                        );
                      }
                      final cat = data.categories[index - 1];
                      final selected = _selectedCategoryId == cat.id;
                      return ChoiceChip(
                        label: Text(
                          cat.name,
                          style: TextStyle(
                            color: theme.colorScheme.onSurface,
                            fontWeight: selected ? FontWeight.w600 : FontWeight.w500,
                          ),
                        ),
                        selected: selected,
                        onSelected: (_) {
                          setState(() {
                            _selectedCategoryId = cat.id;
                            _load();
                          });
                        },
                      );
                    },
                  ),
                ),
                const SizedBox(height: 20),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  child: Text(
                    'All businesses',
                    style: theme.textTheme.titleLarge?.copyWith(
                      color: theme.colorScheme.onSurface,
                    ),
                  ),
                ),
                const SizedBox(height: 12),
                ...data.nearby.map(
                  (b) => Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 16),
                    child: _BusinessTile(
                      business: b,
                      messaging: _messagingId == b.id,
                      onChat: () => _chatWith(b),
                    ),
                  ),
                ),
                const SizedBox(height: 28),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  child: Row(
                    children: [
                      Text(
                        'Popular products',
                        style: theme.textTheme.titleLarge?.copyWith(
                          color: theme.colorScheme.onSurface,
                        ),
                      ),
                      const Spacer(),
                      Text(
                        '${_products.length}${_productsHasMore ? '+' : ''} items',
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 4),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  child: Text(
                    'Scroll down to load more',
                    style: theme.textTheme.bodyMedium?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                ),
                const SizedBox(height: 12),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  child: GridView.builder(
                    shrinkWrap: true,
                    physics: const NeverScrollableScrollPhysics(),
                    gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                      crossAxisCount: 2,
                      childAspectRatio: 0.68,
                      crossAxisSpacing: 12,
                      mainAxisSpacing: 14,
                    ),
                    itemCount: _products.length +
                        ((_productsHasMore || _productsLoadingMore) ? 1 : 0),
                    itemBuilder: (context, index) {
                      if (index >= _products.length) {
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
                      return ProductCard(
                        key: ValueKey('product_${_products[index].id}'),
                        product: _products[index],
                      );
                    },
                  ),
                ),
              ],
            ),
          );
        },
      ),
    );
  }
}

class _EmptyShopsCard extends StatelessWidget {
  const _EmptyShopsCard({
    required this.onSell,
    required this.onBrowseRoles,
  });

  final VoidCallback onSell;
  final VoidCallback onBrowseRoles;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: AppTheme.accentGreen.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: AppTheme.accentGreen.withValues(alpha: 0.35)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'No shops nearby yet',
            style: theme.textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w800),
          ),
          const SizedBox(height: 8),
          Text(
            'Wamu starts with local merchants. List your food or grocery business, or invite a shop you trust.',
            style: theme.textTheme.bodyMedium,
          ),
          const SizedBox(height: 16),
          FilledButton.icon(
            onPressed: onSell,
            icon: const Icon(Icons.storefront),
            label: const Text('Sell on Wamu'),
            style: FilledButton.styleFrom(
              backgroundColor: AppTheme.accentGreen,
              foregroundColor: Colors.black,
            ),
          ),
          TextButton(
            onPressed: onBrowseRoles,
            child: const Text('Enable Business role in You'),
          ),
        ],
      ),
    );
  }
}

class _ShowcaseCard extends StatefulWidget {
  const _ShowcaseCard({
    super.key,
    required this.business,
    required this.messaging,
    required this.onOpen,
    required this.onChat,
  });

  final BusinessModel business;
  final bool messaging;
  final VoidCallback onOpen;
  final VoidCallback onChat;

  @override
  State<_ShowcaseCard> createState() => _ShowcaseCardState();
}

class _ShowcaseCardState extends State<_ShowcaseCard>
    with SingleTickerProviderStateMixin {
  late final AnimationController _pulse;

  @override
  void initState() {
    super.initState();
    _pulse = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1600),
    )..repeat(reverse: true);
  }

  @override
  void dispose() {
    _pulse.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final business = widget.business;
    final cover = business.coverUrl ?? business.imageUrl;
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: widget.onOpen,
        borderRadius: BorderRadius.circular(22),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(22),
          child: Stack(
            fit: StackFit.expand,
            children: [
              AnimatedBuilder(
                animation: _pulse,
                builder: (context, child) {
                  final t = Curves.easeInOut.transform(_pulse.value);
                  return Transform.scale(
                    scale: 1.0 + (t * 0.015),
                    child: child,
                  );
                },
                child: WamuNetworkImage(
                  imageUrl: cover,
                  width: double.infinity,
                  height: double.infinity,
                  fit: BoxFit.cover,
                  alignment: Alignment.center,
                ),
              ),
              DecoratedBox(
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topCenter,
                    end: Alignment.bottomCenter,
                    colors: [
                      Colors.black.withValues(alpha: 0.05),
                      Colors.black.withValues(alpha: 0.2),
                      Colors.black.withValues(alpha: 0.88),
                    ],
                    stops: const [0, 0.4, 1],
                  ),
                ),
              ),
              Positioned(
                top: 12,
                left: 12,
                child: AnimatedBuilder(
                  animation: _pulse,
                  builder: (context, _) {
                    final glow = 0.35 + (_pulse.value * 0.35);
                    return Container(
                      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
                      decoration: BoxDecoration(
                        color: Colors.black.withValues(alpha: 0.5),
                        borderRadius: BorderRadius.circular(20),
                        border: Border.all(
                          color: AppTheme.accentGreen.withValues(alpha: glow),
                        ),
                        boxShadow: [
                          BoxShadow(
                            color: AppTheme.accentGreen.withValues(alpha: glow * 0.35),
                            blurRadius: 10,
                          ),
                        ],
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Container(
                            width: 7,
                            height: 7,
                            decoration: BoxDecoration(
                              color: AppTheme.accentGreen,
                              shape: BoxShape.circle,
                              boxShadow: [
                                BoxShadow(
                                  color: AppTheme.accentGreen.withValues(alpha: glow),
                                  blurRadius: 6,
                                ),
                              ],
                            ),
                          ),
                          const SizedBox(width: 6),
                          const Text(
                            'LIVE',
                            style: TextStyle(
                              color: Colors.white,
                              fontSize: 10,
                              fontWeight: FontWeight.w800,
                              letterSpacing: 0.8,
                            ),
                          ),
                        ],
                      ),
                    );
                  },
                ),
              ),
              Positioned(
                left: 14,
                right: 14,
                bottom: 14,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        if ((business.imageUrl ?? '').isNotEmpty) ...[
                          ClipRRect(
                            borderRadius: BorderRadius.circular(12),
                            child: WamuNetworkImage(
                              imageUrl: business.imageUrl,
                              width: 40,
                              height: 40,
                            ),
                          ),
                          const SizedBox(width: 10),
                        ],
                        Expanded(
                          child: Text(
                            business.name,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              color: Colors.white,
                              fontWeight: FontWeight.w800,
                              fontSize: 18,
                            ),
                          ),
                        ),
                        if (business.isVerified)
                          const Icon(Icons.verified, color: AppTheme.accentGreen, size: 18),
                      ],
                    ),
                    const SizedBox(height: 4),
                    Text(
                      [
                        if (business.rating != null) '★ ${business.rating!.toStringAsFixed(1)}',
                        business.address ?? business.city ?? 'Kampala',
                      ].join(' · '),
                      style: TextStyle(color: Colors.white.withValues(alpha: 0.85), fontSize: 13),
                    ),
                    const SizedBox(height: 10),
                    Row(
                      children: [
                        FilledButton(
                          onPressed: widget.messaging ? null : widget.onChat,
                          style: FilledButton.styleFrom(
                            backgroundColor: AppTheme.accentGreen,
                            foregroundColor: Colors.black,
                            visualDensity: VisualDensity.compact,
                          ),
                          child: widget.messaging
                              ? const SizedBox(
                                  width: 16,
                                  height: 16,
                                  child: CircularProgressIndicator(strokeWidth: 2),
                                )
                              : const Text('Chat to Order'),
                        ),
                        const SizedBox(width: 8),
                        TextButton(
                          onPressed: widget.onOpen,
                          style: TextButton.styleFrom(foregroundColor: Colors.white),
                          child: const Text('View shop'),
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

class _BusinessTile extends StatelessWidget {
  const _BusinessTile({
    required this.business,
    required this.messaging,
    required this.onChat,
  });

  final BusinessModel business;
  final bool messaging;
  final VoidCallback onChat;

  @override
  Widget build(BuildContext context) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    return Container(
      margin: const EdgeInsets.only(bottom: 14),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(18),
        color: dark ? const Color(0xFF1A1F1C) : Colors.white,
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: dark ? 0.35 : 0.08),
            blurRadius: 16,
            offset: const Offset(0, 6),
          ),
        ],
      ),
      clipBehavior: Clip.antiAlias,
      child: Column(
        children: [
          if ((business.coverUrl ?? business.imageUrl)?.isNotEmpty == true)
            AspectRatio(
              aspectRatio: 16 / 9,
              child: Stack(
                fit: StackFit.expand,
                children: [
                  ColoredBox(
                    color: dark ? const Color(0xFF121614) : const Color(0xFFEEF2EF),
                  ),
                  WamuNetworkImage(
                    imageUrl: business.coverUrl ?? business.imageUrl,
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
                          Color(0x14000000),
                          Color(0x00000000),
                          Color(0x66000000),
                        ],
                        stops: [0, 0.55, 1],
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ListTile(
            contentPadding: const EdgeInsets.fromLTRB(12, 6, 8, 6),
            leading: WamuNetworkImage(
              imageUrl: business.imageUrl,
              width: 52,
              height: 52,
              borderRadius: BorderRadius.circular(14),
            ),
            title: Row(
              children: [
                Expanded(
                  child: Text(
                    business.name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontWeight: FontWeight.w700,
                      color: Theme.of(context).colorScheme.onSurface,
                    ),
                  ),
                ),
                if (business.isVerified)
                  const Icon(Icons.verified, size: 16, color: AppTheme.accentGreen),
              ],
            ),
            subtitle: Text(
              [
                if (business.rating != null) '★ ${business.rating!.toStringAsFixed(1)}',
                business.address ?? business.city ?? 'Kampala',
              ].join(' · '),
              style: TextStyle(color: Theme.of(context).colorScheme.onSurfaceVariant),
            ),
            trailing: IconButton(
              tooltip: 'Message',
              onPressed: messaging ? null : onChat,
              icon: messaging
                  ? const SizedBox(
                      width: 20,
                      height: 20,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.chat_bubble_outline, color: AppTheme.accentGreen),
            ),
            onTap: () => context.push('/business/${business.id}'),
          ),
        ],
      ),
    );
  }
}

