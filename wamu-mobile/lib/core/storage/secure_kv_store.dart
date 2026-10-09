import 'secure_storage.dart';
import 'kv_store.dart';

/// Secure-storage backed KvStore (Chrome demos + fallback).
class SecureKvStore implements KvStore {
  SecureKvStore(this._storage);

  final SecureStorageService _storage;

  @override
  Future<String?> read(String key) => _storage.read(key);

  @override
  Future<void> write(String key, String value) => _storage.write(key, value);

  @override
  Future<void> delete(String key) => _storage.delete(key);
}
