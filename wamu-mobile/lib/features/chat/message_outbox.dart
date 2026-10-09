import 'dart:convert';

import 'package:uuid/uuid.dart';

import '../../core/storage/kv_store.dart';
import '../../core/storage/secure_storage.dart';

/// Local message outbox states (Messaging Beta Phase 1).
///
/// Flow: composed → queued → sending → sent | failed
enum OutboxStatus { composed, queued, sending, sent, failed }

class OutboxEntry {
  const OutboxEntry({
    required this.id,
    required this.conversationId,
    required this.body,
    required this.messageType,
    required this.createdAt,
    this.mediaUrl,
    this.replyToMessageId,
    this.status = OutboxStatus.queued,
    this.attempts = 0,
    this.lastError,
  });

  factory OutboxEntry.fromJson(Map<String, dynamic> json) {
    return OutboxEntry(
      id: json['id']?.toString() ?? '',
      conversationId: json['conversation_id']?.toString() ?? '',
      body: json['body']?.toString() ?? '',
      messageType: json['message_type']?.toString() ?? 'TEXT',
      mediaUrl: json['media_url']?.toString(),
      replyToMessageId: json['reply_to_message_id']?.toString(),
      createdAt: json['created_at']?.toString() ?? DateTime.now().toIso8601String(),
      status: OutboxStatus.values.firstWhere(
        (s) => s.name == json['status'],
        orElse: () => OutboxStatus.queued,
      ),
      attempts: int.tryParse('${json['attempts']}') ?? 0,
      lastError: json['last_error']?.toString(),
    );
  }

  final String id;
  final String conversationId;
  final String body;
  final String messageType;
  final String? mediaUrl;
  final String? replyToMessageId;
  final String createdAt;
  final OutboxStatus status;
  final int attempts;
  final String? lastError;

  Map<String, dynamic> toJson() => {
        'id': id,
        'conversation_id': conversationId,
        'body': body,
        'message_type': messageType,
        if (mediaUrl != null) 'media_url': mediaUrl,
        if (replyToMessageId != null) 'reply_to_message_id': replyToMessageId,
        'created_at': createdAt,
        'status': status.name,
        'attempts': attempts,
        if (lastError != null) 'last_error': lastError,
      };

  OutboxEntry copyWith({
    OutboxStatus? status,
    int? attempts,
    String? lastError,
  }) {
    return OutboxEntry(
      id: id,
      conversationId: conversationId,
      body: body,
      messageType: messageType,
      mediaUrl: mediaUrl,
      replyToMessageId: replyToMessageId,
      createdAt: createdAt,
      status: status ?? this.status,
      attempts: attempts ?? this.attempts,
      lastError: lastError,
    );
  }
}

typedef OutboxReader = Future<String?> Function(String key);
typedef OutboxWriter = Future<void> Function(String key, String value);

/// Persists pending sends so flaky networks don't drop composed messages.
/// Backed by [KvStore] (SQLCipher Drift on native, secure storage on web).
class MessageOutbox {
  MessageOutbox({
    required OutboxReader read,
    required OutboxWriter write,
  })  : _read = read,
        _write = write;

  factory MessageOutbox.fromKv(KvStore store) {
    return MessageOutbox(read: store.read, write: store.write);
  }

  factory MessageOutbox.fromSecure(SecureStorageService storage) {
    return MessageOutbox(read: storage.read, write: storage.write);
  }

  final OutboxReader _read;
  final OutboxWriter _write;
  static const _key = 'wamu_message_outbox_v1';
  static const _uuid = Uuid();

  Future<List<OutboxEntry>> _load() async {
    final raw = await _read(_key);
    if (raw == null || raw.isEmpty) return [];
    try {
      final list = jsonDecode(raw) as List<dynamic>;
      return list
          .whereType<Map>()
          .map((e) => OutboxEntry.fromJson(Map<String, dynamic>.from(e)))
          .where((e) => e.status != OutboxStatus.sent)
          .toList();
    } catch (_) {
      return [];
    }
  }

  Future<void> _save(List<OutboxEntry> entries) async {
    final pending = entries.where((e) => e.status != OutboxStatus.sent).toList();
    await _write(_key, jsonEncode(pending.map((e) => e.toJson()).toList()));
  }

  Future<OutboxEntry> enqueue({
    required String conversationId,
    required String body,
    String messageType = 'TEXT',
    String? mediaUrl,
    String? replyToMessageId,
    String? clientId,
  }) async {
    final entry = OutboxEntry(
      id: clientId ?? 'local-${_uuid.v4()}',
      conversationId: conversationId,
      body: body,
      messageType: messageType,
      mediaUrl: mediaUrl,
      replyToMessageId: replyToMessageId,
      createdAt: DateTime.now().toUtc().toIso8601String(),
      status: OutboxStatus.queued,
    );
    final all = await _load();
    all.add(entry);
    await _save(all);
    return entry;
  }

  Future<void> markSending(String id) async {
    final all = await _load();
    final next = [
      for (final e in all)
        if (e.id == id)
          e.copyWith(status: OutboxStatus.sending, attempts: e.attempts + 1)
        else
          e,
    ];
    await _save(next);
  }

  Future<void> markSent(String id) async {
    final all = await _load();
    await _save(all.where((e) => e.id != id).toList());
  }

  Future<void> markFailed(String id, String error) async {
    final all = await _load();
    final next = [
      for (final e in all)
        if (e.id == id) e.copyWith(status: OutboxStatus.failed, lastError: error) else e,
    ];
    await _save(next);
  }

  Future<List<OutboxEntry>> pendingFor(String conversationId) async {
    final all = await _load();
    return all.where((e) => e.conversationId == conversationId).toList();
  }

  Future<List<OutboxEntry>> allPending() => _load();
}
