import 'chat_local_database.dart';
import 'kv_store.dart';

/// Drift-backed KvStore (native SQLCipher file or in-memory for tests).
class DriftKvStore implements KvStore {
  DriftKvStore(this._db);

  final ChatLocalDatabase _db;

  ChatLocalDatabase get database => _db;

  @override
  Future<String?> read(String key) => _db.getValue(key);

  @override
  Future<void> write(String key, String value) => _db.putValue(key, value);

  @override
  Future<void> delete(String key) => _db.removeValue(key);

  Future<void> close() => _db.close();
}
