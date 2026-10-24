import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/media_url.dart';
import '../../core/storage/secure_storage.dart';
import '../../core/theme/network_type_provider.dart';
import '../../core/theme/storage_settings_provider.dart';

/// Voice note bubble — play control, waveform, duration, and the sender avatar.
class ChatVoiceNote extends ConsumerStatefulWidget {
  const ChatVoiceNote({
    super.key,
    required this.playing,
    required this.onPlay,
    required this.foreground,
    required this.position,
    required this.duration,
    required this.sentLabel,
    this.onSeek,
    this.avatarUrl,
    this.ticks,
  });

  final bool playing;
  final VoidCallback onPlay;
  final Color foreground;
  final Duration position;
  final Duration duration;
  final String sentLabel;
  final ValueChanged<double>? onSeek;
  final String? avatarUrl;
  final Widget? ticks;

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

  String _clock(Duration value) {
    final total = value.inSeconds;
    final minutes = total ~/ 60;
    final seconds = total % 60;
    return '$minutes:${seconds.toString().padLeft(2, '0')}';
  }

  @override
  Widget build(BuildContext context) {
    final kind = ref.watch(networkKindProvider);
    ref.watch(storageSettingsProvider);

    return FutureBuilder<bool>(
      future: _shouldAutoLoad(kind),
      builder: (context, snap) {
        final auto = snap.data ?? false;
        if (_forced || auto) return _player();
        final hint = kind == WamuNetworkKind.mobile || kind == WamuNetworkKind.none
            ? 'Tap to download (mobile data)'
            : 'Tap to download';
        return InkWell(
          onTap: () {
            setState(() => _forced = true);
            WidgetsBinding.instance.addPostFrameCallback((_) {
              if (mounted) widget.onPlay();
            });
          },
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.download_for_offline_outlined, color: widget.foreground, size: 36),
              const SizedBox(width: 8),
              Text(hint, style: TextStyle(color: widget.foreground, fontSize: 13)),
            ],
          ),
        );
      },
    );
  }

  Widget _player() {
    final totalMs = widget.duration.inMilliseconds;
    final progress = totalMs <= 0
        ? 0.0
        : (widget.position.inMilliseconds / totalMs).clamp(0.0, 1.0);
    final shown = widget.playing || widget.position > Duration.zero
        ? widget.position
        : Duration.zero;
    return SizedBox(
      width: 248,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              IconButton(
                visualDensity: VisualDensity.compact,
                padding: EdgeInsets.zero,
                constraints: const BoxConstraints(minWidth: 40, minHeight: 40),
                onPressed: widget.onPlay,
                icon: Icon(
                  widget.playing ? Icons.pause_circle_filled : Icons.play_circle_fill,
                  color: widget.foreground,
                  size: 38,
                ),
              ),
              Expanded(
                child: LayoutBuilder(
                  builder: (context, constraints) {
                    return GestureDetector(
                      behavior: HitTestBehavior.opaque,
                      onTapDown: widget.onSeek == null
                          ? null
                          : (details) {
                              final width = constraints.maxWidth;
                              if (width <= 0) return;
                              widget.onSeek!(
                                (details.localPosition.dx / width).clamp(0.0, 1.0),
                              );
                            },
                      child: _Waveform(progress: progress, color: widget.foreground),
                    );
                  },
                ),
              ),
              const SizedBox(width: 8),
              _Avatar(url: widget.avatarUrl, color: widget.foreground),
            ],
          ),
          Padding(
            padding: const EdgeInsets.only(left: 4, right: 2),
            child: Row(
              children: [
                Text(
                  '${_clock(shown)} / ${_clock(widget.duration)}',
                  style: TextStyle(
                    color: widget.foreground.withValues(alpha: 0.75),
                    fontSize: 11,
                  ),
                ),
                const Spacer(),
                Text(
                  widget.sentLabel,
                  style: TextStyle(
                    color: widget.foreground.withValues(alpha: 0.75),
                    fontSize: 11,
                  ),
                ),
                if (widget.ticks != null) ...[
                  const SizedBox(width: 3),
                  widget.ticks!,
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _Waveform extends StatelessWidget {
  const _Waveform({required this.progress, required this.color});

  final double progress;
  final Color color;

  @override
  Widget build(BuildContext context) {
    const bars = 28;
    return SizedBox(
      height: 28,
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          for (var i = 0; i < bars; i++)
            Expanded(
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 0.7),
                child: Align(
                  alignment: Alignment.center,
                  child: Container(
                    height: 6 + ((i * 17) % 18).toDouble(),
                    decoration: BoxDecoration(
                      color: i / bars <= progress
                          ? color
                          : color.withValues(alpha: 0.35),
                      borderRadius: BorderRadius.circular(2),
                    ),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

class _Avatar extends StatelessWidget {
  const _Avatar({required this.url, required this.color});

  final String? url;
  final Color color;

  @override
  Widget build(BuildContext context) {
    final resolved = resolveMediaUrl(url);
    return CircleAvatar(
      radius: 16,
      backgroundColor: color.withValues(alpha: 0.15),
      backgroundImage: resolved == null ? null : NetworkImage(resolved),
      child: resolved == null ? Icon(Icons.person, size: 18, color: color) : null,
    );
  }
}
