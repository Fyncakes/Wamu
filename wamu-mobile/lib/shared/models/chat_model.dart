import '../utils/json_numbers.dart';

List<String> _stringList(dynamic raw) {
  if (raw is! List) return const [];
  return [
    for (final e in raw)
      if (e != null && e.toString().trim().isNotEmpty) e.toString(),
  ];
}

class ConversationModel {
  const ConversationModel({
    required this.id,
    this.type = 'DIRECT',
    this.businessId,
    this.participantName,
    this.participantPhone,
    this.peerUserId,
    this.avatarUrl,
    this.avatarUrls = const [],
    this.lastMessageAt,
    this.lastMessagePreview,
    this.lastMessageFromMe = false,
    this.lastMessageStatus,
    this.unreadCount = 0,
    this.title,
    this.communitySlug,
    this.memberCount = 0,
    this.muted = false,
    this.pinned = false,
    this.archived = false,
    this.favourite = false,
    this.peerOnline = false,
    this.peerLastSeenAt,
  });

  factory ConversationModel.fromJson(Map<String, dynamic> json) {
    final type = json['type']?.toString() ?? 'DIRECT';
    final title = json['title']?.toString();
    final participant = json['participant_name']?.toString();
    final avatars = _stringList(json['participant_avatar_urls']);
    final primary = json['participant_avatar_url']?.toString();
    return ConversationModel(
      id: json['id']?.toString() ?? '',
      type: type,
      businessId: json['business_id']?.toString(),
      participantName: participant ??
          title ??
          (json['business_id'] != null ? 'Business chat' : 'Chat'),
      participantPhone: json['participant_phone']?.toString(),
      peerUserId: json['peer_user_id']?.toString(),
      avatarUrl: (primary != null && primary.isNotEmpty)
          ? primary
          : (avatars.isNotEmpty ? avatars.first : null),
      avatarUrls: avatars,
      lastMessageAt: json['last_message_at']?.toString() ?? json['updated_at']?.toString(),
      lastMessagePreview: json['last_message_preview']?.toString(),
      lastMessageFromMe: json['last_message_from_me'] == true,
      lastMessageStatus: json['last_message_status']?.toString(),
      unreadCount: parseIntOrZero(json['unread_count']),
      title: title,
      communitySlug: json['community_slug']?.toString(),
      memberCount: parseIntOrZero(json['member_count']),
      muted: json['muted'] == true,
      pinned: json['pinned'] == true,
      archived: json['archived'] == true,
      favourite: json['favourite'] == true,
      peerOnline: json['peer_online'] == true,
      peerLastSeenAt: json['peer_last_seen_at']?.toString(),
    );
  }

  final String id;
  final String type;
  final String? businessId;
  final String? participantName;
  final String? participantPhone;
  final String? peerUserId;
  final String? avatarUrl;
  final List<String> avatarUrls;
  final String? lastMessageAt;
  final String? lastMessagePreview;
  final bool lastMessageFromMe;
  final String? lastMessageStatus;
  final int unreadCount;
  final String? title;
  final String? communitySlug;
  final int memberCount;
  final bool muted;
  final bool pinned;
  final bool archived;
  final bool favourite;
  final bool peerOnline;
  final String? peerLastSeenAt;

  bool get isGroup => type == 'GROUP';

  String get displayName => title ?? participantName ?? 'Chat';

  ConversationModel copyWith({
    bool? muted,
    bool? pinned,
    bool? archived,
    bool? favourite,
    int? unreadCount,
    bool? peerOnline,
    String? peerLastSeenAt,
    String? avatarUrl,
    List<String>? avatarUrls,
  }) {
    return ConversationModel(
      id: id,
      type: type,
      businessId: businessId,
      participantName: participantName,
      participantPhone: participantPhone,
      peerUserId: peerUserId,
      avatarUrl: avatarUrl ?? this.avatarUrl,
      avatarUrls: avatarUrls ?? this.avatarUrls,
      lastMessageAt: lastMessageAt,
      lastMessagePreview: lastMessagePreview,
      lastMessageFromMe: lastMessageFromMe,
      lastMessageStatus: lastMessageStatus,
      unreadCount: unreadCount ?? this.unreadCount,
      title: title,
      communitySlug: communitySlug,
      memberCount: memberCount,
      muted: muted ?? this.muted,
      pinned: pinned ?? this.pinned,
      archived: archived ?? this.archived,
      favourite: favourite ?? this.favourite,
      peerOnline: peerOnline ?? this.peerOnline,
      peerLastSeenAt: peerLastSeenAt ?? this.peerLastSeenAt,
    );
  }
}

class MessageReplyPreview {
  const MessageReplyPreview({
    required this.id,
    required this.body,
    required this.senderId,
    this.messageType = 'TEXT',
    this.senderName,
  });

  factory MessageReplyPreview.fromJson(Map<String, dynamic> json) {
    return MessageReplyPreview(
      id: json['id']?.toString() ?? '',
      body: json['body']?.toString() ?? '',
      senderId: json['sender_id']?.toString() ?? '',
      messageType: (json['message_type']?.toString() ?? 'TEXT').toUpperCase(),
      senderName: json['sender_name']?.toString(),
    );
  }

  final String id;
  final String body;
  final String senderId;
  final String messageType;
  final String? senderName;
}

class ChatMessageModel {
  const ChatMessageModel({
    required this.id,
    required this.content,
    required this.isMine,
    this.createdAt,
    this.status = 'SENT',
    this.messageType = 'TEXT',
    this.mediaUrl,
    this.reactions = const {},
    this.replyToMessageId,
    this.replyTo,
  });

  factory ChatMessageModel.fromJson(Map<String, dynamic> json, {String? currentUserId}) {
    final senderId = json['sender_id']?.toString();
    final rawReactions = json['reactions'];
    final reactions = <String, int>{};
    if (rawReactions is Map) {
      rawReactions.forEach((k, v) {
        reactions[k.toString()] = parseIntOrZero(v);
      });
    }
    MessageReplyPreview? reply;
    final replyRaw = json['reply_to'];
    if (replyRaw is Map<String, dynamic>) {
      reply = MessageReplyPreview.fromJson(replyRaw);
    } else if (replyRaw is Map) {
      reply = MessageReplyPreview.fromJson(Map<String, dynamic>.from(replyRaw));
    }
    return ChatMessageModel(
      id: json['id']?.toString() ?? '',
      content: json['body']?.toString() ?? json['content']?.toString() ?? '',
      isMine: currentUserId != null && senderId == currentUserId,
      createdAt: json['created_at']?.toString(),
      status: json['status']?.toString() ?? 'SENT',
      messageType: (json['message_type']?.toString() ?? 'TEXT').toUpperCase(),
      mediaUrl: json['media_url']?.toString(),
      reactions: reactions,
      replyToMessageId: json['reply_to_message_id']?.toString(),
      replyTo: reply,
    );
  }

  final String id;
  final String content;
  final bool isMine;
  final String? createdAt;
  final String status;
  final String messageType;
  final String? mediaUrl;
  final Map<String, int> reactions;
  final String? replyToMessageId;
  final MessageReplyPreview? replyTo;

  bool get isImage => messageType == 'IMAGE';
  bool get isVoice => messageType == 'VOICE';
  bool get isDocument => messageType == 'DOCUMENT';

  /// UI-only: body starts with forwarded marker (no backend field yet).
  bool get isForwarded =>
      content.startsWith('↪ ') || content.toLowerCase().startsWith('forwarded:');

  Map<String, dynamic> toCacheJson() => {
        'id': id,
        'body': content,
        'is_mine': isMine,
        'created_at': createdAt,
        'status': status,
        'message_type': messageType,
        if (mediaUrl != null) 'media_url': mediaUrl,
        'reactions': reactions,
        if (replyToMessageId != null) 'reply_to_message_id': replyToMessageId,
        if (replyTo != null)
          'reply_to': {
            'id': replyTo!.id,
            'body': replyTo!.body,
            'sender_id': replyTo!.senderId,
            'message_type': replyTo!.messageType,
            if (replyTo!.senderName != null) 'sender_name': replyTo!.senderName,
          },
      };

  factory ChatMessageModel.fromCacheJson(Map<String, dynamic> json) {
    MessageReplyPreview? reply;
    final replyRaw = json['reply_to'];
    if (replyRaw is Map) {
      reply = MessageReplyPreview.fromJson(Map<String, dynamic>.from(replyRaw));
    }
    final reactions = <String, int>{};
    final rawReactions = json['reactions'];
    if (rawReactions is Map) {
      rawReactions.forEach((k, v) {
        reactions[k.toString()] = parseIntOrZero(v);
      });
    }
    return ChatMessageModel(
      id: json['id']?.toString() ?? '',
      content: json['body']?.toString() ?? json['content']?.toString() ?? '',
      isMine: json['is_mine'] == true,
      createdAt: json['created_at']?.toString(),
      status: json['status']?.toString() ?? 'SENT',
      messageType: (json['message_type']?.toString() ?? 'TEXT').toUpperCase(),
      mediaUrl: json['media_url']?.toString(),
      reactions: reactions,
      replyToMessageId: json['reply_to_message_id']?.toString(),
      replyTo: reply,
    );
  }

  ChatMessageModel copyWith({
    Map<String, int>? reactions,
    String? status,
    MessageReplyPreview? replyTo,
    String? replyToMessageId,
    String? content,
    String? messageType,
    String? mediaUrl,
  }) {
    return ChatMessageModel(
      id: id,
      content: content ?? this.content,
      isMine: isMine,
      createdAt: createdAt,
      status: status ?? this.status,
      messageType: messageType ?? this.messageType,
      mediaUrl: mediaUrl ?? this.mediaUrl,
      reactions: reactions ?? this.reactions,
      replyToMessageId: replyToMessageId ?? this.replyToMessageId,
      replyTo: replyTo ?? this.replyTo,
    );
  }
}
