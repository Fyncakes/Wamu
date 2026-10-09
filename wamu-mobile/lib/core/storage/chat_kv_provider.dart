import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'secure_storage.dart';
import 'kv_store.dart';
import 'chat_kv_open_stub.dart'
    if (dart.library.io) 'chat_kv_open_io.dart'
    if (dart.library.html) 'chat_kv_open_web.dart' as platform;

/// Opens the platform chat KvStore (SQLCipher Drift on native, secure on web).
Future<KvStore> openChatKvStore(SecureStorageService secure) {
  return platform.openPlatformChatKvStore(secure);
}

/// Shared store for outbox + thread cache. Prefer this over SecureStorage JSON.
final chatKvStoreProvider = FutureProvider<KvStore>((ref) async {
  final secure = ref.watch(secureStorageProvider);
  return openChatKvStore(secure);
});
