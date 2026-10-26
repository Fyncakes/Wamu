import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/media_url.dart';

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
    this.speedLabel = '1×',
    this.onSpeed,
    this.seed = '',
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
  final String speedLabel;
  final VoidCallback? onSpeed;

  /// Stable per message so the bars do not jump between rebuilds.
  final String seed;

  @override
  ConsumerState<ChatVoiceNote> createState() => _ChatVoiceNoteState();
}

class _ChatVoiceNoteState extends ConsumerState<ChatVoiceNote> {
  String _clock(Duration value) {
    final total = value.inSeconds;
    final minutes = total ~/ 60;
    final seconds = total % 60;
    return '$minutes:${seconds.toString().padLeft(2, '0')}';
  }

  @override
  Widget build(BuildContext context) => _player();

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
              _SpeedChip(
                label: widget.speedLabel,
                color: widget.foreground,
                onTap: widget.onSpeed,
              ),
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
                      child: _Waveform(
                        progress: progress,
                        color: widget.foreground,
                        seed: widget.seed,
                      ),
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
                  _clock(shown == Duration.zero ? widget.duration : shown),
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

class _SpeedChip extends StatelessWidget {
  const _SpeedChip({required this.label, required this.color, this.onTap});

  final String label;
  final Color color;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(right: 2),
      child: Material(
        color: color.withValues(alpha: 0.16),
        shape: const CircleBorder(),
        child: InkWell(
          customBorder: const CircleBorder(),
          onTap: onTap,
          child: SizedBox(
            width: 32,
            height: 32,
            child: Center(
              child: Text(
                label,
                style: TextStyle(color: color, fontSize: 11, fontWeight: FontWeight.w700),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _Waveform extends StatelessWidget {
  const _Waveform({required this.progress, required this.color, required this.seed});

  final double progress;
  final Color color;
  final String seed;

  int _height(int i) {
    var hash = seed.hashCode;
    hash = (hash + i * 1103515245) & 0x7fffffff;
    return 6 + (hash % 18);
  }

  @override
  Widget build(BuildContext context) {
    const bars = 28;
    return SizedBox(
      height: 28,
      child: Stack(
        alignment: Alignment.centerLeft,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              for (var i = 0; i < bars; i++)
                Expanded(
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 0.7),
                    child: Align(
                      alignment: Alignment.center,
                      child: Container(
                        height: _height(i).toDouble(),
                        decoration: BoxDecoration(
                          color: i / bars <= progress ? color : color.withValues(alpha: 0.35),
                          borderRadius: BorderRadius.circular(2),
                        ),
                      ),
                    ),
                  ),
                ),
            ],
          ),
          Align(
            alignment: Alignment(progress.clamp(0.0, 1.0) * 2 - 1, 0),
            child: Container(
              width: 10,
              height: 10,
              decoration: BoxDecoration(color: color, shape: BoxShape.circle),
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
