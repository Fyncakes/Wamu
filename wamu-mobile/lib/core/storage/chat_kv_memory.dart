import 'package:drift/native.dart';

import 'chat_local_database.dart';
import 'drift_kv_store.dart';

/// In-memory Drift store for unit tests (no encryption hooks required).
DriftKvStore openMemoryChatKvStore() {
  final db = ChatLocalDatabase(NativeDatabase.memory());
  return DriftKvStore(db);
}
