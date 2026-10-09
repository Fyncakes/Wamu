import 'secure_storage.dart';
import 'kv_store.dart';
import 'secure_kv_store.dart';

/// Stub for analyzer when neither io nor html is resolved.
Future<KvStore> openPlatformChatKvStore(SecureStorageService secure) async {
  return SecureKvStore(secure);
}
