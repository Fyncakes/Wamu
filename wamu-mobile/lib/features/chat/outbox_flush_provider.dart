import 'dart:async';

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/storage/chat_kv_provider.dart';
import '../../core/storage/kv_store.dart';
import '../../core/storage/secure_kv_store.dart';
import '../../core/storage/secure_storage.dart';
import '../auth/auth_provider.dart';
import 'chat_repository.dart';
import 'media_outbox.dart';
import 'message_outbox.dart';

/// Flushes text + media outboxes when connectivity returns.
class OutboxFlushService {
  OutboxFlushService(this._ref);

  final Ref _ref;
  StreamSubscription<List<ConnectivityResult>>? _sub;
  bool _flushing = false;

  void start() {
    _sub?.cancel();
    _sub = Connectivity().onConnectivityChanged.listen((results) {
      final online = results.any((r) => r != ConnectivityResult.none);
      if (online) {
        unawaited(flushAll());
      }
    });
    unawaited(flushAll());
  }

  void stop() {
    _sub?.cancel();
    _sub = null;
  }

  Future<KvStore> _kv() async {
    try {
      return await _ref.read(chatKvStoreProvider.future);
    } catch (_) {
      return SecureKvStore(_ref.read(secureStorageProvider));
    }
  }

  Future<int> flushAll() async {
    if (_flushing) return 0;
    final token = await _ref.read(secureStorageProvider).getToken();
    if (token == null || token.isEmpty) return 0;
    _flushing = true;
    var sent = 0;
    try {
      sent += await _flushMedia();
      sent += await _flushText();
    } finally {
      _flushing = false;
    }
    return sent;
  }

  Future<int> _flushText() async {
    var sent = 0;
    final outbox = MessageOutbox.fromKv(await _kv());
    final pending = await outbox.allPending();
    final userId = _ref.read(authProvider).user?.id;
    final repo = _ref.read(chatRepositoryProvider);
    for (final entry in pending) {
      if (entry.attempts >= 8) continue;
      await outbox.markSending(entry.id);
      try {
        await repo.sendMessage(
          entry.conversationId,
          entry.body,
          currentUserId: userId,
          messageType: entry.messageType,
          mediaUrl: entry.mediaUrl,
          replyToMessageId: entry.replyToMessageId,
          clientMessageId: entry.id,
        );
        await outbox.markSent(entry.id);
        sent++;
      } catch (e) {
        await outbox.markFailed(entry.id, '$e');
      }
    }
    return sent;
  }

  Future<int> _flushMedia() async {
    var sent = 0;
    final kv = await _kv();
    final media = MediaOutbox.fromKv(kv);
    final text = MessageOutbox.fromKv(kv);
    final pending = await media.allPending();
    final userId = _ref.read(authProvider).user?.id;
    final repo = _ref.read(chatRepositoryProvider);
    for (final entry in pending) {
      if (entry.attempts >= 8) continue;
      final bytes = await media.bytesFor(entry);
      if (bytes == null || bytes.isEmpty) {
        await media.markFailed(entry.id, 'bytes unavailable (re-attach media)');
        continue;
      }
      await media.markUploading(entry.id);
      try {
        final url = await repo.uploadBytes(
          bytes,
          filename: entry.filename,
          contentType: entry.contentType,
        );
        final clientId = 'local-media-${entry.id}';
        await text.enqueue(
          conversationId: entry.conversationId,
          body: entry.caption,
          messageType: entry.messageType,
          mediaUrl: url,
          clientId: clientId,
        );
        await repo.sendMessage(
          entry.conversationId,
          entry.caption,
          currentUserId: userId,
          messageType: entry.messageType,
          mediaUrl: url,
          clientMessageId: clientId,
        );
        await text.markSent(clientId);
        await media.markDone(entry.id);
        sent++;
      } catch (e) {
        await media.markFailed(entry.id, '$e');
      }
    }
    return sent;
  }
}

final outboxFlushProvider = Provider<OutboxFlushService>((ref) {
  final service = OutboxFlushService(ref);
  service.start();
  ref.onDispose(service.stop);
  return service;
});
