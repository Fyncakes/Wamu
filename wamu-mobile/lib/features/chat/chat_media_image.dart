import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/theme/app_theme.dart';
import '../../core/theme/network_type_provider.dart';
import '../../core/theme/storage_settings_provider.dart';
import '../../core/storage/secure_storage.dart';
import '../../core/media_url.dart';

/// Chat photo bubble — respects Storage & data + live Wi‑Fi / mobile.
class ChatMediaImage extends ConsumerStatefulWidget {
  const ChatMediaImage({
    super.key,
    required this.imageUrl,
    this.width = 240,
    this.height = 200,
  });

  final String? imageUrl;
  final double width;
  final double height;

  @override
  ConsumerState<ChatMediaImage> createState() => _ChatMediaImageState();
}

class _ChatMediaImageState extends ConsumerState<ChatMediaImage> {
  bool _forced = false;

  Future<bool> _shouldAutoLoad(WamuNetworkKind kind) async {
    final storage = ref.read(storageSettingsProvider);
    final saverRaw = await ref.read(secureStorageProvider).read('wamu_data_saver');
    final dataSaver = saverRaw != '0';

    if (kind == WamuNetworkKind.none) return false;

    final onMobile = kind == WamuNetworkKind.mobile || dataSaver;
    if (onMobile) return storage.autoPhotosMobile;
    return storage.autoPhotosWifi;
  }

  @override
  Widget build(BuildContext context) {
    final url = resolveMediaUrl(widget.imageUrl);
    if (url == null || url.isEmpty) {
      return _tile(icon: Icons.broken_image_outlined, label: 'No photo');
    }

    final kind = ref.watch(networkKindProvider);
    // Rebuild when Storage toggles change without leaving the thread.
    ref.watch(storageSettingsProvider);

    return FutureBuilder<bool>(
      future: _shouldAutoLoad(kind),
      builder: (context, snap) {
        final auto = snap.data ?? false;
        if (_forced || auto) {
          return ClipRRect(
            borderRadius: BorderRadius.circular(10),
            child: CachedNetworkImage(
              imageUrl: url,
              width: widget.width,
              height: widget.height,
              fit: BoxFit.cover,
              placeholder: (context, _) => _tile(icon: Icons.image_outlined, label: 'Loading…'),
              errorWidget: (context, error, stackTrace) =>
                  _tile(icon: Icons.broken_image_outlined, label: 'Failed'),
            ),
          );
        }
        final hint = kind == WamuNetworkKind.mobile || kind == WamuNetworkKind.none
            ? 'Tap to download photo\n(mobile data)'
            : 'Tap to download photo';
        return InkWell(
          onTap: () => setState(() => _forced = true),
          borderRadius: BorderRadius.circular(10),
          child: _tile(
            icon: Icons.download_outlined,
            label: hint,
          ),
        );
      },
    );
  }

  Widget _tile({required IconData icon, required String label}) {
    return Container(
      width: widget.width,
      height: widget.height,
      decoration: BoxDecoration(
        color: AppTheme.messengerElevated.withValues(alpha: 0.65),
        borderRadius: BorderRadius.circular(10),
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
            style: const TextStyle(color: AppTheme.messengerMuted, fontSize: 12),
          ),
        ],
      ),
    );
  }
}
