import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:pointer_interceptor/pointer_interceptor.dart';
import 'package:share_plus/share_plus.dart';
import 'package:video_player/video_player.dart';

import '../../core/media_url.dart';
import '../../core/network/api_error.dart';
import '../../core/server_config.dart';
import '../../core/theme/app_theme.dart';
import '../../shared/models/discover_video_model.dart';
import '../../shared/utils/ugx_formatter.dart';
import '../../shared/widgets/error_view.dart';
import '../../shared/widgets/loading_view.dart';
import '../../shared/widgets/wamu_network_image.dart';
import '../chat/chat_repository.dart';
import 'discover_repository.dart';
import 'html_video_pointer_stub.dart'
    if (dart.library.js_interop) 'html_video_pointer_web.dart';
import 'videos_feed_visibility.dart';

/// Vertical business-video feed — home tab; Chat-to-Order keeps the commerce loop.
class DiscoverFeedScreen extends ConsumerStatefulWidget {
  const DiscoverFeedScreen({super.key});

  @override
  ConsumerState<DiscoverFeedScreen> createState() => _DiscoverFeedScreenState();
}

class _DiscoverFeedScreenState extends ConsumerState<DiscoverFeedScreen>
    with WidgetsBindingObserver {
  late Future<List<DiscoverVideoModel>> _future;
  List<DiscoverVideoModel> _videos = [];
  List<DiscoverVideoModel> _filtered = [];
  final _pageController = PageController();
  String? _chattingId;
  int _page = 0;
  bool _appInForeground = true;
  GoRouterDelegate? _routerDelegate;
  String _categoryFilter = 'All';

  List<String> get _categories {
    final cats = <String>{};
    for (final v in _videos) {
      final c = v.categoryLabel;
      if (c.isNotEmpty) cats.add(c);
    }
    final sorted = cats.toList()..sort();
    return ['All', ...sorted];
  }

  void _applyFilter({bool resetPage = true}) {
    if (_categoryFilter == 'All') {
      _filtered = List.of(_videos);
    } else {
      _filtered =
          _videos.where((v) => v.categoryLabel == _categoryFilter).toList();
    }
    if (resetPage) {
      _page = 0;
      if (_pageController.hasClients) {
        _pageController.jumpToPage(0);
      }
    } else if (_page >= _filtered.length) {
      _page = _filtered.isEmpty ? 0 : _filtered.length - 1;
    }
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _load();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final delegate = GoRouter.of(context).routerDelegate;
    if (!identical(_routerDelegate, delegate)) {
      _routerDelegate?.removeListener(_onRouteChanged);
      _routerDelegate = delegate;
      _routerDelegate?.addListener(_onRouteChanged);
    }
  }

  @override
  void dispose() {
    _routerDelegate?.removeListener(_onRouteChanged);
    WidgetsBinding.instance.removeObserver(this);
    _pageController.dispose();
    super.dispose();
  }

  void _onRouteChanged() {
    if (mounted) setState(() {});
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    final live = state == AppLifecycleState.resumed;
    if (live == _appInForeground) return;
    setState(() => _appInForeground = live);
  }

  /// Play only when Videos tab is visible and nothing covers it (/shops, chat, etc.).
  bool _feedShouldPlay(BuildContext context) {
    if (!_appInForeground) return false;
    if (ref.watch(shellTabIndexProvider) != 0) return false;
    // Shell stays mounted under pushed routes — stop as soon as this route is covered.
    final route = ModalRoute.of(context);
    if (route != null && !route.isCurrent) return false;
    final config = GoRouter.of(context).routerDelegate.currentConfiguration;
    final matches = config.matches;
    if (matches.isNotEmpty) {
      final top = matches.last.matchedLocation;
      if (top != '/home' && top != '/' && top.isNotEmpty) return false;
    } else {
      final path = config.uri.path;
      if (path != '/home' && path.isNotEmpty && path != '/') return false;
    }
    return true;
  }

  void _precachePosters(List<DiscoverVideoModel> feed, int page) {
    for (final i in {page, page + 1}) {
      if (i < 0 || i >= feed.length) continue;
      final poster = feed[i].displayImage;
      if (poster == null || poster.isEmpty) continue;
      final url = resolveMediaUrl(poster);
      if (url == null || url.isEmpty) continue;
      precacheImage(NetworkImage(url), context).ignore();
    }
  }

  void _load() {
    // Keep first fetch small — phone tunnels choke on large payloads + videos.
    _future = ref.read(discoverRepositoryProvider).getVideos(limit: 6).then((v) {
      // Keep spreadsheet category grouping order from API sort_order.
      _videos = List.of(v);
      _applyFilter(resetPage: true);
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _precachePosters(_filtered, _page);
      });
      return _videos;
    });
  }

  void _reload() {
    _load();
    setState(() {});
  }

  Future<void> _showCategoryFilter() async {
    final selected = await showModalBottomSheet<String>(
      context: context,
      backgroundColor: const Color(0xFF1A1A1A),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (ctx) {
        return SafeArea(
          child: ListView(
            shrinkWrap: true,
            children: [
              const Padding(
                padding: EdgeInsets.fromLTRB(20, 16, 20, 8),
                child: Text(
                  'Category',
                  style: TextStyle(
                    color: Colors.white,
                    fontWeight: FontWeight.w800,
                    fontSize: 17,
                  ),
                ),
              ),
              for (final cat in _categories)
                ListTile(
                  title: Text(
                    cat,
                    style: TextStyle(
                      color: cat == _categoryFilter
                          ? AppTheme.accentGreen
                          : Colors.white,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  trailing: cat == _categoryFilter
                      ? const Icon(Icons.check, color: AppTheme.accentGreen)
                      : null,
                  onTap: () => Navigator.pop(ctx, cat),
                ),
            ],
          ),
        );
      },
    );
    if (selected == null || !mounted) return;
    setState(() {
      _categoryFilter = selected;
      _applyFilter(resetPage: true);
    });
  }

  Future<void> _chatToOrder(DiscoverVideoModel video) async {
    setState(() => _chattingId = video.id);
    try {
      final opener = video.productName != null
          ? 'Hi ${video.businessName}! I saw your ${video.productName} on Discover — can I order?'
          : 'Hi ${video.businessName}! I saw you on Wamu Discover — I want to order.';
      final convo = await ref.read(chatRepositoryProvider).startConversation(
            video.businessId,
            message: opener,
          );
      if (!mounted) return;
      context.go('/chats');
      context.push('/chat/${convo.id}');
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('$e')));
      }
    } finally {
      if (mounted) setState(() => _chattingId = null);
    }
  }

  Future<void> _toggleLike(DiscoverVideoModel video, void Function(DiscoverVideoModel) patch) async {
    final repo = ref.read(discoverRepositoryProvider);
    try {
      final next = video.likedByMe ? await repo.unlike(video.id) : await repo.like(video.id);
      patch(next);
    } catch (_) {}
  }

  Future<void> _toggleFollow(
    DiscoverVideoModel video,
    void Function(DiscoverVideoModel) patch,
  ) async {
    final repo = ref.read(discoverRepositoryProvider);
    try {
      if (video.following) {
        await repo.unfollowBusiness(video.businessId);
        patch(
          DiscoverVideoModel(
            id: video.id,
            businessId: video.businessId,
            businessName: video.businessName,
            businessLogoUrl: video.businessLogoUrl,
            authorId: video.authorId,
            caption: video.caption,
            videoUrl: video.videoUrl,
            posterUrl: video.posterUrl,
            tags: video.tags,
            likeCount: video.likeCount,
            commentCount: video.commentCount,
            viewCount: video.viewCount,
            likedByMe: video.likedByMe,
            following: false,
            productId: video.productId,
            productName: video.productName,
            productPrice: video.productPrice,
            currency: video.currency,
          ),
        );
      } else {
        await repo.followBusiness(video.businessId);
        patch(
          DiscoverVideoModel(
            id: video.id,
            businessId: video.businessId,
            businessName: video.businessName,
            businessLogoUrl: video.businessLogoUrl,
            authorId: video.authorId,
            caption: video.caption,
            videoUrl: video.videoUrl,
            posterUrl: video.posterUrl,
            tags: video.tags,
            likeCount: video.likeCount,
            commentCount: video.commentCount,
            viewCount: video.viewCount,
            likedByMe: video.likedByMe,
            following: true,
            productId: video.productId,
            productName: video.productName,
            productPrice: video.productPrice,
            currency: video.currency,
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('$e')));
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final feedLive = _feedShouldPlay(context);
    return Scaffold(
      backgroundColor: Colors.black,
      body: FutureBuilder<List<DiscoverVideoModel>>(
        future: _future,
        builder: (context, snap) {
          if (snap.connectionState != ConnectionState.done) {
            return const LoadingView();
          }
          if (snap.hasError) {
            return ErrorView(
              message: apiErrorMessage(snap.error!),
              onRetry: _reload,
            );
          }
          if (_videos.isEmpty) {
            return Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Text(
                    'No videos yet',
                    style: TextStyle(color: Colors.white70, fontSize: 16),
                  ),
                  const SizedBox(height: 12),
                  TextButton(
                    onPressed: () => context.go('/shops'),
                    child: const Text('Browse shops'),
                  ),
                ],
              ),
            );
          }
          final feed = _filtered;
          return Stack(
            children: [
              if (feed.isEmpty)
                const Center(
                  child: Text(
                    'No videos in this category',
                    style: TextStyle(color: Colors.white70, fontSize: 15),
                  ),
                )
              else
                PageView.builder(
                  controller: _pageController,
                  scrollDirection: Axis.vertical,
                  itemCount: feed.length,
                  onPageChanged: (i) {
                    setState(() => _page = i);
                    _precachePosters(feed, i);
                    ref.read(discoverRepositoryProvider).recordView(feed[i].id);
                  },
                  itemBuilder: (context, index) {
                    final video = feed[index];
                    final rawIndex = _videos.indexWhere((v) => v.id == video.id);
                    return _VideoPage(
                      key: ValueKey('${video.id}_$_categoryFilter'),
                      video: video,
                      active: feedLive && index == _page,
                      // Preload exactly one ahead — never download the whole stack.
                      preload: feedLive && index == _page + 1,
                      chatting: _chattingId == video.id,
                      onChat: () => _chatToOrder(video),
                      onLike: () => _toggleLike(video, (v) {
                        setState(() {
                          if (rawIndex >= 0) _videos[rawIndex] = v;
                          _applyFilter(resetPage: false);
                        });
                      }),
                      onFollow: () => _toggleFollow(video, (v) {
                        setState(() {
                          if (rawIndex >= 0) _videos[rawIndex] = v;
                          _applyFilter(resetPage: false);
                        });
                      }),
                      onShop: () {
                        if (video.businessId.isEmpty) return;
                        context.push('/business/${video.businessId}');
                      },
                    );
                  },
                ),
              SafeArea(
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(12, 4, 4, 0),
                  child: Row(
                    children: [
                      const Text(
                        'Wamu',
                        style: TextStyle(
                          color: Colors.white,
                          fontSize: 22,
                          fontWeight: FontWeight.w800,
                          letterSpacing: -0.5,
                        ),
                      ),
                      const Spacer(),
                      IconButton(
                        tooltip: 'Filter',
                        onPressed: _showCategoryFilter,
                        icon: Icon(
                          _categoryFilter == 'All'
                              ? Icons.filter_list_rounded
                              : Icons.filter_alt,
                          color: _categoryFilter == 'All'
                              ? Colors.white
                              : AppTheme.accentGreen,
                        ),
                      ),
                      IconButton(
                        tooltip: 'Search',
                        onPressed: () => context.push('/search'),
                        icon: const Icon(Icons.search, color: Colors.white),
                      ),
                      IconButton(
                        tooltip: 'Shops',
                        onPressed: () => context.go('/shops'),
                        icon: const Icon(Icons.storefront_outlined, color: Colors.white),
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

class _VideoPage extends StatefulWidget {
  const _VideoPage({
    super.key,
    required this.video,
    required this.active,
    this.preload = false,
    required this.chatting,
    required this.onChat,
    required this.onLike,
    required this.onFollow,
    required this.onShop,
  });

  final DiscoverVideoModel video;
  final bool active;
  /// Initialize next clip in background (muted); never play until active.
  final bool preload;
  final bool chatting;
  final VoidCallback onChat;
  final VoidCallback onLike;
  final VoidCallback onFollow;
  /// Opens this merchant's shop page (products).
  final VoidCallback onShop;

  @override
  State<_VideoPage> createState() => _VideoPageState();
}

class _VideoPageState extends State<_VideoPage>
    with AutomaticKeepAliveClientMixin {
  VideoPlayerController? _controller;
  bool _ready = false;
  bool _muted = false;
  bool _loadFailed = false;
  String? _loadError;
  /// User tapped to pause while this page is active.
  bool _userPaused = false;
  /// Last known position — used so resume never jumps to 0.
  Duration _resumeAt = Duration.zero;
  Timer? _initDelay;

  @override
  bool get wantKeepAlive => widget.active || widget.preload;

  bool get _isMp4 {
    final u = (widget.video.videoUrl).toLowerCase();
    return u.endsWith('.mp4') || u.contains('.mp4?');
  }

  bool get _shouldLoad => widget.active || widget.preload;

  void _scheduleInitPlayer({bool immediate = false}) {
    _initDelay?.cancel();
    // Active clip starts immediately; preload waits briefly so the visible clip wins bandwidth.
    final delay = (immediate || widget.active)
        ? Duration.zero
        : const Duration(milliseconds: 280);
    _initDelay = Timer(delay, () {
      if (!mounted || !_shouldLoad) return;
      if (_controller != null) return;
      _initPlayer();
    });
  }

  @override
  void initState() {
    super.initState();
    if (_shouldLoad) {
      _scheduleInitPlayer(immediate: widget.active);
    }
  }

  @override
  void didUpdateWidget(covariant _VideoPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.video.id != widget.video.id) {
      _userPaused = false;
      _resumeAt = Duration.zero;
      _initDelay?.cancel();
      _disposePlayer();
      if (_shouldLoad) {
        _scheduleInitPlayer(immediate: widget.active);
      }
      return;
    }

    if (oldWidget.active != widget.active || oldWidget.preload != widget.preload) {
      updateKeepAlive();
      if (_shouldLoad) {
        if (_controller == null) {
          _scheduleInitPlayer(immediate: widget.active);
        } else if (widget.active) {
          _syncPlayback();
        } else {
          _rememberPosition();
          _syncPlayback();
        }
      } else {
        // More than one away — free decoder + stop download.
        _initDelay?.cancel();
        _rememberPosition();
        _disposePlayer();
        if (mounted) setState(() {});
      }
    }
  }

  @override
  void deactivate() {
    _rememberPosition();
    final c = _controller;
    if (c != null) {
      c.pause();
      c.setVolume(0);
    }
    super.deactivate();
  }

  void _rememberPosition() {
    final c = _controller;
    if (c == null || !c.value.isInitialized) return;
    final pos = c.value.position;
    if (pos > Duration.zero) {
      _resumeAt = pos;
    }
  }

  Future<void> _initPlayer() async {
    if (!_isMp4) return;
    // Re-pin API origin on each play (tunnel hostname rotates often).
    ServerConfig.correctWebDevServerUrl();
    var url = resolveMediaUrl(widget.video.videoUrl);
    // Same-origin absolute path when the API still returns /media-files/...
    if (url != null && url.startsWith('/')) {
      final origin = Uri.base.origin;
      url = '$origin$url';
    }
    if (url == null || url.isEmpty) {
      if (mounted) {
        setState(() {
          _loadFailed = true;
          _loadError = 'Missing video URL';
        });
      }
      return;
    }
    if (mounted) {
      setState(() {
        _loadFailed = false;
        _loadError = null;
      });
    }
    final uri = Uri.tryParse(url);
    if (uri == null) {
      if (mounted) {
        setState(() {
          _loadFailed = true;
          _loadError = 'Bad video URL — tap to retry';
        });
      }
      return;
    }
    final c = VideoPlayerController.networkUrl(
      uri,
      videoPlayerOptions: VideoPlayerOptions(mixWithOthers: true),
      httpHeaders: const {
        // Help mobile Chrome fetch ranged MP4s through the tunnel.
        'Accept': '*/*',
      },
    );
    _controller = c;
    try {
      await c.initialize().timeout(const Duration(seconds: 60));
      await c.setLooping(true);
      await c.setVolume(_muted ? 0 : 1);
      if (!mounted) return;
      setState(() {
        _ready = true;
        _loadFailed = false;
        _loadError = null;
      });
      // Mobile Chrome paints <video> above Flutter; disable its pointer events.
      WidgetsBinding.instance.addPostFrameCallback((_) {
        disableHtmlVideoPointerEvents();
        if (mounted) _syncPlayback();
      });
    } catch (e) {
      await c.dispose();
      if (_controller == c) _controller = null;
      if (mounted) {
        setState(() {
          _ready = false;
          _loadFailed = true;
          _loadError = 'Video failed to load — tap to retry';
        });
      }
    }
  }

  void _retryPlayer() {
    _disposePlayer();
    setState(() {
      _loadFailed = false;
      _loadError = null;
    });
    _scheduleInitPlayer();
  }

  Future<void> _ensureResumePosition() async {
    final c = _controller;
    if (c == null || !c.value.isInitialized) return;
    final target = _resumeAt;
    if (target <= Duration.zero) return;
    final current = c.value.position;
    // Only seek when the player jumped backwards (typical restart glitch).
    if (current < target - const Duration(milliseconds: 400)) {
      await c.seekTo(target);
    }
  }

  void _syncPlayback() {
    final c = _controller;
    if (c == null || !_ready) return;
    if (widget.active && !_userPaused) {
      c.setVolume(_muted ? 0 : 1);
      unawaited(() async {
        await _ensureResumePosition();
        if (!mounted || _controller != c) return;
        if (widget.active && !_userPaused) {
          await c.play();
        }
      }());
    } else {
      _rememberPosition();
      unawaited(c.pause());
      unawaited(c.setVolume(0));
    }
  }

  Future<void> _toggleMute() async {
    final c = _controller;
    if (c == null || !_ready) return;
    final next = !_muted;
    await c.setVolume(next ? 0 : 1);
    if (!mounted) return;
    setState(() => _muted = next);
  }

  void _togglePause() {
    final c = _controller;
    if (c == null || !_ready) return;
    // Allow pause even if PageView briefly reports inactive during rebuild.
    if (!_userPaused) {
      _rememberPosition();
      setState(() => _userPaused = true);
      unawaited(c.pause());
      unawaited(c.setVolume(0));
      return;
    }
    setState(() => _userPaused = false);
    _syncPlayback();
  }

  void _disposePlayer() {
    _initDelay?.cancel();
    _initDelay = null;
    _controller?.dispose();
    _controller = null;
    _ready = false;
  }

  @override
  void dispose() {
    _initDelay?.cancel();
    _disposePlayer();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    final video = widget.video;
    final chatting = widget.chatting;
    final price = video.productPrice;
    final posterUrl = video.displayImage;
    final poster = posterUrl != null ? resolveMediaUrl(posterUrl) : null;
    final logo = resolveMediaUrl(video.businessLogoUrl);
    return Stack(
      fit: StackFit.expand,
      children: [
        // Video ignores pointers — Flutter overlay owns all taps (critical on web).
        IgnorePointer(
          child: (_ready && _controller != null)
              ? FittedBox(
                  fit: BoxFit.cover,
                  child: SizedBox(
                    width: _controller!.value.size.width,
                    height: _controller!.value.size.height,
                    child: VideoPlayer(_controller!),
                  ),
                )
              : (poster != null && poster.isNotEmpty)
                  ? WamuNetworkImage(
                      imageUrl: poster,
                      fit: BoxFit.cover,
                    )
                  : const ColoredBox(color: Color(0xFF111111)),
        ),
        const IgnorePointer(
          child: DecoratedBox(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: [
                  Color(0x66000000),
                  Color(0x00000000),
                  Color(0xCC000000),
                ],
                stops: [0, 0.35, 1],
              ),
            ),
          ),
        ),
        // Full-screen tap target above the HTML video (PointerInterceptor + CSS).
        Positioned.fill(
          child: PointerInterceptor(
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: () {
                disableHtmlVideoPointerEvents();
                if (_loadFailed) {
                  _retryPlayer();
                  return;
                }
                _togglePause();
              },
              child: ColoredBox(
                // Slight alpha so the layer paints and participates in hit tests.
                color: const Color(0x01000000),
                child: _loadFailed
                    ? Center(
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            const Icon(
                              Icons.replay_circle_filled,
                              color: Colors.white,
                              size: 64,
                            ),
                            const SizedBox(height: 10),
                            Text(
                              _loadError ?? 'Tap to retry video',
                              textAlign: TextAlign.center,
                              style: const TextStyle(
                                color: Colors.white,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          ],
                        ),
                      )
                    : (_ready && _userPaused)
                        ? const Center(
                            child: Icon(
                              Icons.play_arrow_rounded,
                              color: Colors.white70,
                              size: 84,
                            ),
                          )
                        : null,
              ),
            ),
          ),
        ),
        Positioned(
          right: 10,
          bottom: 88,
          child: PointerInterceptor(
            child: Column(
              children: [
                if (_ready) ...[
                  _SideAction(
                    icon: _muted ? Icons.volume_off : Icons.volume_up,
                    label: _muted ? 'Muted' : 'Sound',
                    onTap: _toggleMute,
                  ),
                  const SizedBox(height: 14),
                ],
                _SideAction(
                  icon: video.likedByMe ? Icons.favorite : Icons.favorite_border,
                  label: '${video.likeCount}',
                  color: video.likedByMe ? const Color(0xFFFF4D6D) : Colors.white,
                  onTap: widget.onLike,
                ),
                const SizedBox(height: 14),
                _SideAction(
                  icon: video.following ? Icons.person : Icons.person_add_alt_1,
                  label: video.following ? 'Following' : 'Follow',
                  color: video.following ? AppTheme.accentGreen : Colors.white,
                  onTap: widget.onFollow,
                ),
                const SizedBox(height: 14),
                _SideAction(
                  icon: Icons.share_outlined,
                  label: 'Share',
                  onTap: () {
                    final product = video.productName;
                    final text = product != null && product.isNotEmpty
                        ? 'Check out $product from ${video.businessName} on Wamu'
                        : 'Check out ${video.businessName} on Wamu';
                    SharePlus.instance.share(ShareParams(text: text));
                  },
                ),
              ],
            ),
          ),
        ),
        Positioned(
          left: 16,
          right: 78,
          bottom: 28,
          child: PointerInterceptor(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Material(
                  color: Colors.transparent,
                  child: InkWell(
                    onTap: widget.onShop,
                    borderRadius: BorderRadius.circular(24),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(vertical: 2, horizontal: 2),
                      child: Row(
                        children: [
                          CircleAvatar(
                            radius: 16,
                            backgroundColor: AppTheme.accentGreen.withValues(alpha: 0.3),
                            backgroundImage: logo != null ? NetworkImage(logo) : null,
                            child: logo == null
                                ? Text(
                                    video.businessName.isNotEmpty
                                        ? video.businessName[0].toUpperCase()
                                        : 'W',
                                    style: const TextStyle(color: Colors.white),
                                  )
                                : null,
                          ),
                          const SizedBox(width: 8),
                          Expanded(
                            child: Text(
                              video.businessName,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                color: Colors.white,
                                fontWeight: FontWeight.w700,
                                fontSize: 15,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
                const SizedBox(height: 8),
                Text(
                  video.title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    color: Colors.white,
                    fontWeight: FontWeight.w800,
                    fontSize: 16,
                    height: 1.2,
                  ),
                ),
                if (video.productName != null) ...[
                  const SizedBox(height: 6),
                  Text(
                    price != null
                        ? '${video.productName} · ${formatUgx(price)}'
                        : video.productName!,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      color: AppTheme.accentGreen,
                      fontWeight: FontWeight.w600,
                      fontSize: 13,
                    ),
                  ),
                ],
                const SizedBox(height: 10),
                SizedBox(
                  width: double.infinity,
                  child: FilledButton(
                    onPressed: chatting ? null : widget.onChat,
                    style: FilledButton.styleFrom(
                      backgroundColor: AppTheme.accentGreen,
                      foregroundColor: Colors.black,
                      padding: const EdgeInsets.symmetric(vertical: 11),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(12),
                      ),
                    ),
                    child: chatting
                        ? const SizedBox(
                            height: 18,
                            width: 18,
                            child: CircularProgressIndicator(
                              strokeWidth: 2,
                              color: Colors.black,
                            ),
                          )
                        : const Text(
                            'Chat to Order',
                            style: TextStyle(
                              fontWeight: FontWeight.w800,
                              fontSize: 14,
                            ),
                          ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }
}

class _SideAction extends StatelessWidget {
  const _SideAction({
    required this.icon,
    required this.label,
    required this.onTap,
    this.color = Colors.white,
  });

  final IconData icon;
  final String label;
  final VoidCallback? onTap;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        IconButton(
          onPressed: onTap,
          icon: Icon(icon, color: color, size: 30),
        ),
        Text(label, style: const TextStyle(color: Colors.white, fontSize: 12)),
      ],
    );
  }
}
