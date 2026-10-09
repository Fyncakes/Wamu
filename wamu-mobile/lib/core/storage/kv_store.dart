/// Key-value persistence used by message outbox, media outbox, and thread cache.
///
/// Implementations:
/// - [SecureKvStore] — web / fallback (flutter_secure_storage)
/// - [DriftKvStore] — native SQLCipher-backed Drift DB
abstract class KvStore {
  Future<String?> read(String key);
  Future<void> write(String key, String value);
  Future<void> delete(String key);
}

/// In-memory store for unit tests.
class MemoryKvStore implements KvStore {
  final Map<String, String> _data = {};

  @override
  Future<String?> read(String key) async => _data[key];

  @override
  Future<void> write(String key, String value) async => _data[key] = value;

  @override
  Future<void> delete(String key) async => _data.remove(key);
}
