import 'package:cached_network_image/cached_network_image.dart';
import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';

import '../../core/media_url.dart';
import '../../core/theme/app_theme.dart';

/// Chat photo — inline when auto-download allows it, tap opens a viewer.
class ChatMediaImage extends ConsumerStatefulWidget {
  const ChatMediaImage({
    super.key,
    required this.imageUrl,
    this.width = 240,
    this.height,
    this.radius = 12,
    this.crop = false,
  });

  final String? imageUrl;
  final double width;
  final double? height;
  final double radius;

  /// Grid tiles crop to a fixed box. A single photo keeps its aspect ratio.
  final bool crop;

  @override
  ConsumerState<ChatMediaImage> createState() => _ChatMediaImageState();
}

class _ChatMediaImageState extends ConsumerState<ChatMediaImage> {
  int _attempt = 0;

  void _open(String url) {
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => ChatImageViewer(imageUrl: url),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final url = resolveMediaUrl(widget.imageUrl);
    if (url == null || url.isEmpty) {
      return _tile(icon: Icons.broken_image_outlined, label: 'Photo unavailable');
    }

    return _loaded(url);
  }

  Widget _loaded(String url) {
    final image = Image(
      key: ValueKey('$url#$_attempt'),
      image: CachedNetworkImageProvider(url),
      width: widget.crop ? widget.width : widget.width,
      height: widget.crop ? widget.height : null,
      fit: widget.crop ? BoxFit.cover : BoxFit.contain,
      loadingBuilder: (context, child, progress) {
        if (progress == null) return child;
        return _tile(icon: Icons.image_outlined, label: 'Loading…');
      },
      errorBuilder: (context, error, stackTrace) {
        return InkWell(
          onTap: () => setState(() => _attempt += 1),
          child: _tile(icon: Icons.refresh, label: 'Could not load\nTap to retry'),
        );
      },
    );
    return GestureDetector(
      onTap: () => _open(url),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(widget.radius),
        child: widget.crop
            ? SizedBox(width: widget.width, height: widget.height, child: image)
            : ConstrainedBox(
                constraints: BoxConstraints(
                  maxWidth: widget.width,
                  maxHeight: widget.width * 1.35,
                ),
                child: image,
              ),
      ),
    );
  }

  Widget _tile({required IconData icon, required String label}) {
    return Container(
      width: widget.width,
      height: widget.height ?? widget.width * 0.72,
      decoration: BoxDecoration(
        color: AppTheme.messengerElevated.withValues(alpha: 0.65),
        borderRadius: BorderRadius.circular(widget.radius),
      ),
      alignment: Alignment.center,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, color: AppTheme.accentGreen, size: 32),
          const SizedBox(height: 8),
          Text(
            label,
            textAlign: TextAlign.center,
            style: TextStyle(color: AppTheme.muted(context), fontSize: 12),
          ),
        ],
      ),
    );
  }
}

/// Full-screen photo with pinch zoom and an explicit save action.
class ChatImageViewer extends StatefulWidget {
  const ChatImageViewer({super.key, required this.imageUrl});

  final String imageUrl;

  @override
  State<ChatImageViewer> createState() => _ChatImageViewerState();
}

class _ChatImageViewerState extends State<ChatImageViewer> {
  bool _saving = false;

  Future<void> _save() async {
    if (_saving) return;
    setState(() => _saving = true);
    try {
      if (kIsWeb) {
        await SharePlus.instance.share(ShareParams(text: widget.imageUrl));
        return;
      }
      final dir = await getTemporaryDirectory();
      final path = '${dir.path}/wamu-photo-${DateTime.now().millisecondsSinceEpoch}.jpg';
      await Dio().download(widget.imageUrl, path);
      await SharePlus.instance.share(ShareParams(files: [XFile(path)]));
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Could not save this photo. Try again.')),
        );
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        foregroundColor: Colors.white,
        title: const Text('Photo'),
        actions: [
          IconButton(
            tooltip: 'Save',
            onPressed: _saving ? null : _save,
            icon: _saving
                ? const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
                  )
                : const Icon(Icons.download_outlined),
          ),
        ],
      ),
      body: Center(
        child: InteractiveViewer(
          minScale: 1,
          maxScale: 4,
          child: Image(
            image: CachedNetworkImageProvider(widget.imageUrl),
            fit: BoxFit.contain,
            errorBuilder: (context, error, stackTrace) => const Padding(
              padding: EdgeInsets.all(24),
              child: Text(
                'This photo is unavailable.',
                style: TextStyle(color: Colors.white70),
                textAlign: TextAlign.center,
              ),
            ),
          ),
        ),
      ),
    );
  }
}
