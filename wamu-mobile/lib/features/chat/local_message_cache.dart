import 'dart:convert';

import '../../core/storage/kv_store.dart';
import '../../core/storage/secure_storage.dart';
import '../../shared/models/chat_model.dart';
import 'message_outbox.dart';

/// Offline thread cache — [KvStore] (SQLCipher Drift native / secure storage web).
class LocalMessageCache {
  LocalMessageCache({
    required OutboxReader read,
    required OutboxWriter write,
  })  : _read = read,
        _write = write;

  factory LocalMessageCache.fromKv(KvStore store) {
    return LocalMessageCache(read: store.read, write: store.write);
  }

  factory LocalMessageCache.fromSecure(SecureStorageService storage) {
    return LocalMessageCache(read: storage.read, write: storage.write);
  }

  final OutboxReader _read;
  final OutboxWriter _write;
  static const _prefix = 'wamu_msg_cache_v1_';
  static const _maxMessages = 200;

  String _key(String conversationId) => '$_prefix$conversationId';

  Future<List<ChatMessageModel>> load(String conversationId) async {
    final raw = await _read(_key(conversationId));
    if (raw == null || raw.isEmpty) return [];
    try {
      final list = jsonDecode(raw) as List<dynamic>;
      return list
          .whereType<Map>()
          .map((e) => ChatMessageModel.fromCacheJson(Map<String, dynamic>.from(e)))
          .toList();
    } catch (_) {
      return [];
    }
  }

  Future<void> save(String conversationId, List<ChatMessageModel> messages) async {
    final trimmed = messages.length > _maxMessages
        ? messages.sublist(messages.length - _maxMessages)
        : messages;
    final payload = jsonEncode(trimmed.map((m) => m.toCacheJson()).toList());
    await _write(_key(conversationId), payload);
  }

  Future<void> upsert(String conversationId, ChatMessageModel message) async {
    final current = await load(conversationId);
    final next = [
      for (final m in current)
        if (m.id != message.id) m,
      message,
    ];
    // Keep chronological if createdAt present
    next.sort((a, b) => (a.createdAt ?? '').compareTo(b.createdAt ?? ''));
    await save(conversationId, next);
  }
}
