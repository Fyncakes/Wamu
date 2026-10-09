import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';

import '../../core/media_url.dart';
import '../../core/theme/app_theme.dart';
import '../../shared/models/chat_model.dart';
import '../../shared/widgets/wamu_network_image.dart';

/// Stable color from a name/phone seed — WhatsApp-style letter avatars.
Color contactAvatarColor(String seed) {
  const palette = <Color>[
    Color(0xFF0B6E4F), // Wamu green
    Color(0xFF1DAA61), // accent
    Color(0xFFC45C26), // terracotta
    Color(0xFF1B4F72), // lake blue
    Color(0xFF117A65), // teal
    Color(0xFF7D6608), // earth gold
    Color(0xFF6E2C00), // brown
    Color(0xFF1A5276), // deep blue
  ];
  final h = seed.trim().toLowerCase().hashCode;
  return palette[h.abs() % palette.length];
}

/// Circular contact avatar with photo or colored initial.
class ContactAvatar extends StatelessWidget {
  const ContactAvatar({
    super.key,
    required this.name,
    this.phone,
    this.avatarUrl,
    this.radius = 24,
  });

  final String name;
  final String? phone;
  final String? avatarUrl;
  final double radius;

  @override
  Widget build(BuildContext context) {
    final label = name.trim().isNotEmpty ? name.trim() : (phone ?? 'W');
    final letter = label.isNotEmpty ? label[0].toUpperCase() : 'W';
    final bg = contactAvatarColor('$name|${phone ?? ''}');
    final photo = resolveMediaUrl(avatarUrl);
    final hasPhoto = photo != null && photo.isNotEmpty;

    return CircleAvatar(
      radius: radius,
      backgroundColor: bg,
      backgroundImage: hasPhoto ? CachedNetworkImageProvider(photo) : null,
      child: hasPhoto
          ? null
          : Text(
              letter,
              style: TextStyle(
                color: Colors.white.withValues(alpha: 0.95),
                fontWeight: FontWeight.w700,
                fontSize: radius * 0.75,
              ),
            ),
    );
  }
}

/// Inbox / chat-header avatar: profile photo when set, else initial or group icon.
class ConversationAvatar extends StatelessWidget {
  const ConversationAvatar({
    super.key,
    required this.conversation,
    this.radius = 26,
  });

  final ConversationModel conversation;
  final double radius;

  @override
  Widget build(BuildContext context) {
    final urls = <String>[
      ...conversation.avatarUrls,
      if (conversation.avatarUrl != null) conversation.avatarUrl!,
    ].where((u) => u.trim().isNotEmpty).toSet().toList();

    if (urls.isEmpty) {
      if (conversation.isGroup) {
        return CircleAvatar(
          radius: radius,
          backgroundColor: const Color(0xFF2A3942),
          child: Icon(Icons.groups, size: radius, color: AppTheme.accentGreen),
        );
      }
      return ContactAvatar(
        name: conversation.displayName,
        phone: conversation.participantPhone,
        radius: radius,
      );
    }

    if (urls.length == 1) {
      return ContactAvatar(
        name: conversation.displayName,
        phone: conversation.participantPhone,
        avatarUrl: urls.first,
        radius: radius,
      );
    }

    final size = radius * 2;
    return ClipOval(
      child: SizedBox(
        width: size,
        height: size,
        child: Row(
          children: [
            Expanded(
              child: WamuNetworkImage(
                imageUrl: urls[0],
                width: size / 2,
                height: size,
              ),
            ),
            Expanded(
              child: WamuNetworkImage(
                imageUrl: urls[1],
                width: size / 2,
                height: size,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Compact “on Wamu” badge for contact rows.
class OnWamuBadge extends StatelessWidget {
  const OnWamuBadge({super.key});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: AppTheme.accentGreen.withValues(alpha: 0.18),
        borderRadius: BorderRadius.circular(8),
      ),
      child: const Text(
        'on Wamu',
        style: TextStyle(
          color: AppTheme.accentGreen,
          fontSize: 10,
          fontWeight: FontWeight.w700,
        ),
      ),
    );
  }
}
