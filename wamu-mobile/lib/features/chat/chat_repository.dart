import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:http_parser/http_parser.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

import '../../core/network/api_client.dart';
import '../../core/server_config.dart';
import '../../core/storage/secure_storage.dart';
import '../../shared/models/chat_model.dart';

class ChatRepository {
  ChatRepository(this._client, this._storage);

  final ApiClient _client;
  final SecureStorageService _storage;

  Future<List<ConversationModel>> getConversations() async {
    final response = await _client.get('/chat/conversations');
    return _extractList(response.data).map(ConversationModel.fromJson).toList();
  }

  Future<ConversationModel> getConversation(String id) async {
    final response = await _client.get('/chat/conversations/$id');
    return ConversationModel.fromJson(response.data as Map<String, dynamic>);
  }

  Future<ConversationModel> updatePrefs(
    String conversationId, {
    bool? muted,
    bool? pinned,
    bool? archived,
    bool? favourite,
  }) async {
    final response = await _client.patch(
      '/chat/conversations/$conversationId/prefs',
      data: {
        if (muted != null) 'muted': muted,
        if (pinned != null) 'pinned': pinned,
        if (archived != null) 'archived': archived,
        if (favourite != null) 'favourite': favourite,
      },
    );
    return ConversationModel.fromJson(response.data as Map<String, dynamic>);
  }

  Future<void> hideConversation(String conversationId) async {
    await _client.post('/chat/conversations/$conversationId/hide');
  }

  Future<List<Map<String, dynamic>>> getMembers(String conversationId) async {
    final response = await _client.get('/chat/conversations/$conversationId/members');
    final data = response.data;
    if (data is Map && data['items'] is List) {
      return (data['items'] as List).cast<Map<String, dynamic>>();
    }
    return [];
  }

  Future<void> leaveConversation(String conversationId) async {
    await _client.post('/chat/conversations/$conversationId/leave');
  }

  Future<void> kickMember(String conversationId, String userId) async {
    await _client.post('/chat/conversations/$conversationId/kick/$userId');
  }

  Future<void> blockUser(String userId) async {
    await _client.post('/users/me/blocks/$userId');
  }

  Future<void> reportUser({
    required String userId,
    required String reason,
    String? description,
  }) async {
    await _client.post('/reports', data: {
      'target_type': 'USER',
      'target_id': userId,
      'reason': reason,
      if (description != null && description.isNotEmpty) 'description': description,
    });
  }

  Future<ConversationModel> renameConversation(String conversationId, String title) async {
    final response = await _client.patch(
      '/chat/conversations/$conversationId',
      data: {'title': title},
    );
    return ConversationModel.fromJson(response.data as Map<String, dynamic>);
  }

  Future<ConversationModel> joinCommunity(String communityId) async {
    final response = await _client.post('/communities/$communityId/join');
    return ConversationModel.fromJson(response.data as Map<String, dynamic>);
  }

  Future<void> leaveCommunity(String communityId) async {
    await _client.post('/communities/$communityId/leave');
  }

  Future<ConversationModel> createGroup({
    required String title,
    List<String> memberPhones = const [],
    String? initialMessage,
  }) async {
    final response = await _client.post('/communities/groups', data: {
      'title': title,
      'member_phones': memberPhones,
      if (initialMessage != null && initialMessage.isNotEmpty) 'initial_message': initialMessage,
    });
    return ConversationModel.fromJson(response.data as Map<String, dynamic>);
  }

  Future<ConversationModel> startBusinessConversation(
    String businessId, {
    String? message,
  }) async {
    final response = await _client.post('/chat/conversations', data: {
      'business_id': businessId,
      if (message != null && message.isNotEmpty) 'initial_message': message,
    });
    return ConversationModel.fromJson(response.data as Map<String, dynamic>);
  }

  Future<ConversationModel> startConversation(String businessId, {String? message}) =>
      startBusinessConversation(businessId, message: message);

  Future<ConversationModel> startDirectChat({
    String? peerPhone,
    String? peerUserId,
    String? message,
  }) async {
    final response = await _client.post('/chat/conversations', data: {
      if (peerPhone != null) 'peer_phone': peerPhone,
      if (peerUserId != null) 'peer_user_id': peerUserId,
      if (message != null && message.isNotEmpty) 'initial_message': message,
    });
    return ConversationModel.fromJson(response.data as Map<String, dynamic>);
  }

  Future<Map<String, dynamic>?> lookupByPhone(String phone) async {
    try {
      final response = await _client.get('/chat/users/lookup', queryParameters: {
        'phone': phone,
      });
      return response.data as Map<String, dynamic>;
    } on DioException catch (e) {
      if (e.response?.statusCode == 404) return null;
      rethrow;
    }
  }

  Future<({List<Map<String, dynamic>> items, int onWamuCount})> getDirectory() async {
    final response = await _client.get('/chat/directory');
    final data = response.data;
    if (data is Map<String, dynamic>) {
      final items = (data['items'] is List)
          ? (data['items'] as List).cast<Map<String, dynamic>>()
          : <Map<String, dynamic>>[];
      final raw = data['on_wamu_count'];
      final count = raw is int ? raw : int.tryParse('$raw') ?? items.length;
      return (items: items, onWamuCount: count);
    }
    return (items: <Map<String, dynamic>>[], onWamuCount: 0);
  }

  Future<List<ChatMessageModel>> getMessages(String conversationId, {String? currentUserId}) async {
    final response = await _client.get('/chat/conversations/$conversationId/messages');
    return _extractList(response.data)
        .map((e) => ChatMessageModel.fromJson(e, currentUserId: currentUserId))
        .toList();
  }

  Future<ChatMessageModel> sendMessage(
    String conversationId,
    String body, {
    String? currentUserId,
    String messageType = 'TEXT',
    String? mediaUrl,
    String? replyToMessageId,
    String? clientMessageId,
  }) async {
    final response = await _client.post(
      '/chat/conversations/$conversationId/messages',
      data: {
        'body': body,
        'message_type': messageType,
        if (mediaUrl != null) 'media_url': mediaUrl,
        if (replyToMessageId != null) 'reply_to_message_id': replyToMessageId,
        if (clientMessageId != null) 'client_message_id': clientMessageId,
      },
    );
    return ChatMessageModel.fromJson(
      response.data as Map<String, dynamic>,
      currentUserId: currentUserId,
    );
  }

  Future<ChatMessageModel> ackMessage(
    String messageId,
    String status, {
    String? currentUserId,
  }) async {
    final response = await _client.post(
      '/chat/messages/$messageId/ack',
      data: {'status': status},
    );
    return ChatMessageModel.fromJson(
      response.data as Map<String, dynamic>,
      currentUserId: currentUserId,
    );
  }

  /// Upload bytes to /media/upload — returns public URL (local fallback or MinIO).
  Future<String> uploadBytes(
    Uint8List bytes, {
    required String filename,
    String contentType = 'application/octet-stream',
  }) async {
    final form = FormData.fromMap({
      'file': MultipartFile.fromBytes(
        bytes,
        filename: filename,
        contentType: MediaType.parse(contentType),
      ),
    });
    final response = await _client.dio.post('/media/upload', data: form);
    final data = response.data as Map<String, dynamic>;
    final url = data['url']?.toString();
    if (url == null || url.isEmpty) {
      throw StateError('Upload failed — no URL returned');
    }
    return url;
  }

  Future<ChatMessageModel> react(String messageId, String emoji, {String? currentUserId}) async {
    final response = await _client.post(
      '/chat/messages/$messageId/reactions',
      data: {'emoji': emoji},
    );
    return ChatMessageModel.fromJson(
      response.data as Map<String, dynamic>,
      currentUserId: currentUserId,
    );
  }

  /// scope `me` = local hide; `everyone` = silent unsend of own messages.
  Future<List<String>> deleteMessages(
    String conversationId,
    List<String> messageIds, {
    String scope = 'me',
  }) async {
    if (messageIds.isEmpty) return [];
    final response = await _client.post(
      '/chat/conversations/$conversationId/messages/delete',
      data: {'message_ids': messageIds, 'scope': scope},
    );
    final data = response.data;
    if (data is Map) {
      final ids = data['deleted_ids'];
      if (ids is List) {
        return ids.map((e) => e.toString()).toList();
      }
    }
    return [];
  }

  Future<WebSocketChannel> connectRealtime(String conversationId) async {
    final ticketRes = await _client.post(
      '/chat/ws-ticket',
      data: {'conversation_id': conversationId},
    );
    final ticket = (ticketRes.data as Map)['ticket']?.toString() ?? '';
    if (ticket.isEmpty) {
      throw StateError('Could not obtain chat WS ticket');
    }
    final uri = Uri.parse(
      '${ServerConfig.wsBaseUrl}/chat/ws/$conversationId?ticket=${Uri.encodeComponent(ticket)}',
    );
    return WebSocketChannel.connect(uri);
  }

  Future<bool> isDataSaverOn() async {
    final raw = await _storage.read('wamu_data_saver');
    return raw != '0';
  }

  List<Map<String, dynamic>> _extractList(dynamic data) {
    if (data is List) return data.cast<Map<String, dynamic>>();
    if (data is Map<String, dynamic>) {
      for (final key in ['conversations', 'messages', 'results', 'data', 'items']) {
        final value = data[key];
        if (value is List) return value.cast<Map<String, dynamic>>();
      }
    }
    return [];
  }
}

final chatRepositoryProvider = Provider<ChatRepository>((ref) {
  return ChatRepository(
    ref.watch(apiClientProvider),
    ref.watch(secureStorageProvider),
  );
});
