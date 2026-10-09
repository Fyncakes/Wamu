import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';

import '../../core/media_url.dart';

/// Network image that keeps the last good frame so soft reloads never flash blank.
class WamuNetworkImage extends StatefulWidget {
  const WamuNetworkImage({
    super.key,
    required this.imageUrl,
    this.width,
    this.height,
    this.fit = BoxFit.cover,
    this.alignment = Alignment.center,
    this.borderRadius,
  });

  final String? imageUrl;
  final double? width;
  final double? height;
  final BoxFit fit;
  final Alignment alignment;
  final BorderRadius? borderRadius;

  @override
  State<WamuNetworkImage> createState() => _WamuNetworkImageState();
}

class _WamuNetworkImageState extends State<WamuNetworkImage> {
  String? _stableUrl;

  @override
  void initState() {
    super.initState();
    _stableUrl = resolveMediaUrl(widget.imageUrl);
  }

  @override
  void didUpdateWidget(covariant WamuNetworkImage oldWidget) {
    super.didUpdateWidget(oldWidget);
    final next = resolveMediaUrl(widget.imageUrl);
    // Only swap when the URL actually changes — soft reloads keep the same URL.
    if (next != null && next.isNotEmpty && next != _stableUrl) {
      _stableUrl = next;
    } else if ((next == null || next.isEmpty) &&
        (widget.imageUrl != oldWidget.imageUrl)) {
      _stableUrl = next;
    }
  }

  @override
  Widget build(BuildContext context) {
    final resolved = _stableUrl ?? resolveMediaUrl(widget.imageUrl);
    final dark = Theme.of(context).brightness == Brightness.dark;

    Widget child;
    if (resolved == null || resolved.isEmpty) {
      child = _placeholder(dark);
    } else {
      final dpr = MediaQuery.devicePixelRatioOf(context);
      final screenW = MediaQuery.sizeOf(context).width;
      final layoutW = widget.width != null && widget.width!.isFinite
          ? widget.width!
          : screenW;
      final memW = (layoutW * dpr).round().clamp(160, 1600);
      child = CachedNetworkImage(
        key: ValueKey(resolved),
        imageUrl: resolved,
        width: widget.width,
        height: widget.height,
        fit: widget.fit,
        alignment: widget.alignment,
        filterQuality: FilterQuality.medium,
        fadeInDuration: Duration.zero,
        fadeOutDuration: Duration.zero,
        placeholderFadeInDuration: Duration.zero,
        memCacheWidth: memW,
        maxWidthDiskCache: 1800,
        useOldImageOnUrlChange: true,
        cacheKey: resolved,
        placeholder: (_, __) {
          // Prefer blank dark surface over a flashy icon while disk cache resolves.
          return Container(
            width: widget.width,
            height: widget.height,
            color: dark ? const Color(0xFF141A17) : Colors.grey.shade100,
          );
        },
        errorWidget: (_, __, ___) => _placeholder(dark, failed: true),
      );
    }

    if (widget.borderRadius != null) {
      return ClipRRect(borderRadius: widget.borderRadius!, child: child);
    }
    return child;
  }

  Widget _placeholder(bool dark, {bool failed = false}) {
    return Container(
      width: widget.width,
      height: widget.height,
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: dark
              ? const [Color(0xFF1C2420), Color(0xFF141A17), Color(0xFF0F1412)]
              : [Colors.grey.shade200, Colors.grey.shade100, const Color(0xFFE8F0EA)],
        ),
      ),
      child: Icon(
        failed ? Icons.broken_image_outlined : Icons.image_outlined,
        color: dark ? const Color(0xFF5A6B60) : Colors.grey.shade400,
        size: 36,
      ),
    );
  }
}
