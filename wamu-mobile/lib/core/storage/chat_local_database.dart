import 'package:drift/drift.dart';

part 'chat_local_database.g.dart';

/// Simple KV table — outbox/cache keep their JSON shapes; Drift owns durability.
class KvEntries extends Table {
  TextColumn get key => text()();
  TextColumn get value => text()();

  @override
  Set<Column<Object>> get primaryKey => {key};
}

@DriftDatabase(tables: [KvEntries])
class ChatLocalDatabase extends _$ChatLocalDatabase {
  ChatLocalDatabase(super.e);

  @override
  int get schemaVersion => 1;

  Future<String?> getValue(String key) async {
    final row = await (select(kvEntries)..where((t) => t.key.equals(key)))
        .getSingleOrNull();
    return row?.value;
  }

  Future<void> putValue(String key, String value) async {
    await into(kvEntries).insertOnConflictUpdate(
      KvEntriesCompanion.insert(key: key, value: value),
    );
  }

  Future<void> removeValue(String key) async {
    await (delete(kvEntries)..where((t) => t.key.equals(key))).go();
  }

  Future<Map<String, String>> dumpAll() async {
    final rows = await select(kvEntries).get();
    return {for (final r in rows) r.key: r.value};
  }

  Future<void> putAll(Map<String, String> entries) async {
    for (final e in entries.entries) {
      await putValue(e.key, e.value);
    }
  }
}
