import 'dart:io';
import 'dart:math';

import 'package:drift/drift.dart';
import 'package:drift/native.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:sqlite3/common.dart' show CommonDatabase;

import 'secure_storage.dart';
import 'chat_local_database.dart';
import 'drift_kv_store.dart';
import 'kv_store.dart';
import 'secure_kv_store.dart';

const _dbKeyStorage = 'wamu_chat_db_key_v1';
const _migratedFlag = 'wamu_chat_db_migrated_v1';

/// Keys historically stored as JSON blobs in secure storage.
const _legacyOutboxKey = 'wamu_message_outbox_v1';
const _legacyMediaKey = 'wamu_media_outbox_v1';

Future<String> _passphrase(SecureStorageService secure) async {
  final existing = await secure.read(_dbKeyStorage);
  if (existing != null && existing.length >= 32) return existing;
  final rng = Random.secure();
  final bytes = List<int>.generate(32, (_) => rng.nextInt(256));
  final key = bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
  await secure.write(_dbKeyStorage, key);
  return key;
}

bool _hasCipher(CommonDatabase database) {
  try {
    return database.select('PRAGMA cipher;').isNotEmpty;
  } catch (_) {
    return false;
  }
}

LazyDatabase _openEncrypted(String passphrase) {
  assert(RegExp(r'^[0-9a-f]+$').hasMatch(passphrase));
  return LazyDatabase(() async {
    final dir = await getApplicationDocumentsDirectory();
    final file = File(p.join(dir.path, 'wamu_chat_local.db'));
    return NativeDatabase.createInBackground(
      file,
      setup: (rawDb) {
        // sqlite3mc hook must be enabled in pubspec (`source: sqlite3mc`).
        assert(_hasCipher(rawDb), 'sqlite3mc cipher missing — check pubspec hooks');
        rawDb.execute("PRAGMA key = '$passphrase';");
      },
    );
  });
}

/// Native: encrypted Drift DB (SQLite3MultipleCiphers); migrates from secure JSON.
Future<KvStore> openPlatformChatKvStore(SecureStorageService secure) async {
  try {
    final passphrase = await _passphrase(secure);
    final db = ChatLocalDatabase(_openEncrypted(passphrase));
    await db.customSelect('SELECT 1').get();
    final store = DriftKvStore(db);
    await _migrateFromSecureIfNeeded(secure, store);
    return store;
  } catch (_) {
    return SecureKvStore(secure);
  }
}

Future<void> _migrateFromSecureIfNeeded(
  SecureStorageService secure,
  DriftKvStore store,
) async {
  final done = await secure.read(_migratedFlag);
  if (done == '1') return;

  final toCopy = <String, String>{};
  for (final key in [_legacyOutboxKey, _legacyMediaKey]) {
    final v = await secure.read(key);
    if (v != null && v.isNotEmpty) toCopy[key] = v;
  }

  if (toCopy.isNotEmpty) {
    await store.database.putAll(toCopy);
    for (final key in toCopy.keys) {
      await secure.delete(key);
    }
  }
  await secure.write(_migratedFlag, '1');
}
