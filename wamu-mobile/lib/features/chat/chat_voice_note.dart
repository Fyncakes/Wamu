import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/storage/secure_storage.dart';
import '../../core/theme/network_type_provider.dart';
import '../../core/theme/storage_settings_provider.dart';

/// Voice note bubble — respects Storage & data auto-download (Wi‑Fi / mobile).
class ChatVoiceNote extends ConsumerStatefulWidget {
  const ChatVoiceNote({
    super.key,
    required this.playing,
    required this.onPlay,
    required this.foreground,
  });

  final bool playing;
  final VoidCallback onPlay;
  final Color foreground;

  @override
  ConsumerState<ChatVoiceNote> createState() => _ChatVoiceNoteState();
}

class _ChatVoiceNoteState extends ConsumerState<ChatVoiceNote> {
  bool _forced = false;

  Future<bool> _shouldAutoLoad(WamuNetworkKind kind) async {
    final storage = ref.read(storageSettingsProvider);
    final saverRaw = await ref.read(secureStorageProvider).read('wamu_data_saver');
    final dataSaver = saverRaw != '0';

    if (kind == WamuNetworkKind.none) return false;

    final onMobile = kind == WamuNetworkKind.mobile || dataSaver;
    if (onMobile) return storage.autoVoiceMobile;
    return storage.autoVoiceWifi;
  }

  @override
  Widget build(BuildContext context) {
    final kind = ref.watch(networkKindProvider);
    // Rebuild when storage toggles change
    ref.watch(storageSettingsProvider);

    return FutureBuilder<bool>(
      future: _shouldAutoLoad(kind),
      builder: (context, snap) {
        final auto = snap.data ?? false;
        if (_forced || auto) {
          return InkWell(
            onTap: widget.onPlay,
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  widget.playing
                      ? Icons.pause_circle_filled
                      : Icons.play_circle_filled,
                  color: widget.foreground,
                  size: 34,
                ),
                const SizedBox(width: 8),
                Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      widget.playing ? 'Playing…' : 'Voice note',
                      style: TextStyle(
                        color: widget.foreground,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    Container(
                      margin: const EdgeInsets.only(top: 4),
                      width: 100,
                      height: 3,
                      decoration: BoxDecoration(
                        color: widget.foreground.withValues(alpha: 0.35),
                        borderRadius: BorderRadius.circular(2),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          );
        }

        final hint = kind == WamuNetworkKind.mobile || kind == WamuNetworkKind.none
            ? 'Tap to download\n(mobile data)'
            : 'Tap to download';
        return InkWell(
          onTap: () {
            setState(() => _forced = true);
            // Play after unlock so one tap both downloads and starts.
            WidgetsBinding.instance.addPostFrameCallback((_) {
              if (mounted) widget.onPlay();
            });
          },
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                Icons.download_for_offline_outlined,
                color: widget.foreground,
                size: 34,
              ),
              const SizedBox(width: 8),
              Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Voice note',
                    style: TextStyle(
                      color: widget.foreground,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  Text(
                    hint,
                    style: TextStyle(
                      fontSize: 11,
                      color: widget.foreground.withValues(alpha: 0.65),
                    ),
                  ),
                ],
              ),
            ],
          ),
        );
      },
    );
  }
}
