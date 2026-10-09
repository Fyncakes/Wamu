import 'package:flutter/material.dart';

import '../../core/theme/app_theme.dart';
import '../../shared/models/chat_model.dart';
import 'chat_media_image.dart';

/// Compact 2×2 / strip album for consecutive IMAGE messages from the same sender.
class ChatMediaGrid extends StatelessWidget {
  const ChatMediaGrid({
    super.key,
    required this.messages,
    this.onLongPress,
    this.width = 248,
  });

  final List<ChatMessageModel> messages;
  final void Function(ChatMessageModel msg)? onLongPress;
  final double width;

  @override
  Widget build(BuildContext context) {
    final imgs = messages.where((m) => m.isImage && m.mediaUrl != null).toList();
    if (imgs.isEmpty) return const SizedBox.shrink();
    if (imgs.length == 1) {
      return GestureDetector(
        onLongPress: onLongPress == null ? null : () => onLongPress!(imgs.first),
        child: _tile(imgs.first, width: width, height: 200),
      );
    }

    final shown = imgs.take(4).toList();
    final extra = imgs.length - shown.length;
    final gap = 3.0;
    final cell = (width - gap) / 2;

    return SizedBox(
      width: width,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (imgs.any((m) => m.isForwarded))
            const Padding(
              padding: EdgeInsets.only(bottom: 4),
              child: Text(
                'Forwarded',
                style: TextStyle(
                  fontSize: 11,
                  fontStyle: FontStyle.italic,
                  color: AppTheme.messengerMuted,
                ),
              ),
            ),
          Wrap(
            spacing: gap,
            runSpacing: gap,
            children: [
              for (var i = 0; i < shown.length; i++)
                GestureDetector(
                  onLongPress:
                      onLongPress == null ? null : () => onLongPress!(shown[i]),
                  child: Stack(
                    children: [
                      _tile(shown[i], width: cell, height: cell),
                      if (i == shown.length - 1 && extra > 0)
                        Positioned.fill(
                          child: Container(
                            alignment: Alignment.center,
                            color: Colors.black54,
                            child: Text(
                              '+$extra',
                              style: const TextStyle(
                                color: Colors.white,
                                fontSize: 22,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          ),
                        ),
                    ],
                  ),
                ),
            ],
          ),
          if (_sharedCaption(imgs) != null) ...[
            const SizedBox(height: 6),
            Text(
              _sharedCaption(imgs)!,
              style: const TextStyle(color: AppTheme.messengerText, height: 1.3),
            ),
          ],
        ],
      ),
    );
  }

  Widget _tile(ChatMessageModel msg, {required double width, required double height}) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(6),
      child: ChatMediaImage(
        imageUrl: msg.mediaUrl,
        width: width,
        height: height,
      ),
    );
  }

  String? _sharedCaption(List<ChatMessageModel> imgs) {
    for (final m in imgs) {
      final c = m.content.trim();
      if (c.isEmpty) continue;
      if (c.startsWith('📷')) continue;
      if (c.toLowerCase() == 'photo') continue;
      if (c.startsWith('↪ ')) {
        final rest = c.substring(2).trim();
        if (rest.startsWith('📷') || rest.toLowerCase() == 'photo') continue;
        return rest;
      }
      return c;
    }
    return null;
  }
}

/// Group consecutive same-sender IMAGE messages for album rendering.
List<List<ChatMessageModel>> groupMessageRuns(List<ChatMessageModel> messages) {
  final runs = <List<ChatMessageModel>>[];
  for (final msg in messages) {
    if (runs.isEmpty) {
      runs.add([msg]);
      continue;
    }
    final last = runs.last;
    final head = last.first;
    final canAlbum = msg.isImage &&
        head.isImage &&
        msg.isMine == head.isMine &&
        msg.messageType != 'SYSTEM' &&
        last.length < 8;
    if (canAlbum) {
      last.add(msg);
    } else {
      runs.add([msg]);
    }
  }
  return runs;
}
