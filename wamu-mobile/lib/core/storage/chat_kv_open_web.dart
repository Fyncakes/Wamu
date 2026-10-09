import 'secure_storage.dart';
import 'kv_store.dart';
import 'secure_kv_store.dart';

/// Web: always secure storage (no SQLCipher / Drift native file).
Future<KvStore> openPlatformChatKvStore(SecureStorageService secure) async {
  return SecureKvStore(secure);
}
