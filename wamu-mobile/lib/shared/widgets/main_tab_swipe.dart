import 'package:flutter/material.dart';

/// Horizontal pager for the main tabs. Keeps each branch alive (like
/// IndexedStack) so Videos/Chats state survives swipes.
class MainTabSwipe extends StatefulWidget {
  const MainTabSwipe({
    super.key,
    required this.currentIndex,
    required this.onIndexChanged,
    required this.children,
  });

  final int currentIndex;
  final ValueChanged<int> onIndexChanged;
  final List<Widget> children;

  @override
  State<MainTabSwipe> createState() => _MainTabSwipeState();
}

class _MainTabSwipeState extends State<MainTabSwipe> {
  late final PageController _controller;
  bool _syncingFromNav = false;

  @override
  void initState() {
    super.initState();
    _controller = PageController(initialPage: widget.currentIndex);
  }

  @override
  void didUpdateWidget(MainTabSwipe oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.currentIndex == oldWidget.currentIndex) return;
    final page = _controller.hasClients
        ? (_controller.page?.round() ?? widget.currentIndex)
        : widget.currentIndex;
    if (page == widget.currentIndex) return;
    _syncingFromNav = true;
    _controller
        .animateToPage(
          widget.currentIndex,
          duration: const Duration(milliseconds: 280),
          curve: Curves.easeOutCubic,
        )
        .whenComplete(() {
      if (mounted) _syncingFromNav = false;
    });
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return PageView(
      controller: _controller,
      // Vertical video feed / chip rows keep their own recognizers; this
      // PageView only wins on a clear horizontal drag.
      physics: const PageScrollPhysics(parent: ClampingScrollPhysics()),
      onPageChanged: (index) {
        if (_syncingFromNav) return;
        if (index == widget.currentIndex) return;
        widget.onIndexChanged(index);
      },
      children: [
        for (final child in widget.children) _KeepAlivePage(child: child),
      ],
    );
  }
}

class _KeepAlivePage extends StatefulWidget {
  const _KeepAlivePage({required this.child});

  final Widget child;

  @override
  State<_KeepAlivePage> createState() => _KeepAlivePageState();
}

class _KeepAlivePageState extends State<_KeepAlivePage>
    with AutomaticKeepAliveClientMixin {
  @override
  bool get wantKeepAlive => true;

  @override
  Widget build(BuildContext context) {
    super.build(context);
    return widget.child;
  }
}
