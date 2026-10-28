import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Persists auth tokens using platform secure storage.
///
/// On web (especially LAN http:// not localhost), flutter_secure_storage can throw
/// "Null check operator used on a null value" when Web Crypto / options fail.
/// We fall back to SharedPreferences so login still works on phone Chrome.
class SecureStorageService {
  SecureStorageService({FlutterSecureStorage? storage})
      : _storage = storage ??
            const FlutterSecureStorage(
              aOptions: AndroidOptions(encryptedSharedPreferences: true),
              webOptions: WebOptions(
                dbName: 'WamuSecureStorage',
                publicKey: 'WamuSecureStorage',
              ),
            );

  final FlutterSecureStorage _storage;
  bool _preferPrefs = kIsWeb;

  static const _tokenKey = 'auth_token';
  static const _refreshKey = 'refresh_token';
  static const _userIdKey = 'user_id';
  static const _phoneKey = 'phone';
  static const _userSnapshotKey = 'user_snapshot';

  Future<void> _prefsWrite(String key, String value) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('wamu_$key', value);
  }

  Future<String?> _prefsRead(String key) async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString('wamu_$key');
  }

  Future<void> _prefsDelete(String key) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove('wamu_$key');
  }

  Future<void> _write(String key, String value) async {
    if (_preferPrefs) {
      await _prefsWrite(key, value);
      return;
    }
    try {
      await _storage.write(key: key, value: value);
    } catch (_) {
      _preferPrefs = true;
      await _prefsWrite(key, value);
    }
  }

  Future<String?> _read(String key) async {
    if (_preferPrefs) {
      return _prefsRead(key);
    }
    try {
      return await _storage.read(key: key);
    } catch (_) {
      _preferPrefs = true;
      return _prefsRead(key);
    }
  }

  Future<void> _delete(String key) async {
    if (_preferPrefs) {
      await _prefsDelete(key);
      return;
    }
    try {
      await _storage.delete(key: key);
    } catch (_) {
      _preferPrefs = true;
      await _prefsDelete(key);
    }
  }

  Future<void> saveToken(String token) => _write(_tokenKey, token);
  Future<String?> getToken() => _read(_tokenKey);

  Future<void> saveRefreshToken(String token) => _write(_refreshKey, token);
  Future<String?> getRefreshToken() => _read(_refreshKey);

  Future<void> saveUserId(String userId) => _write(_userIdKey, userId);
  Future<String?> getUserId() => _read(_userIdKey);

  Future<void> savePhone(String phone) => _write(_phoneKey, phone);
  Future<String?> getPhone() => _read(_phoneKey);

  Future<void> saveUserSnapshot(String json) => _write(_userSnapshotKey, json);
  Future<String?> getUserSnapshot() => _read(_userSnapshotKey);

  /// Generic key-value helpers (cart persistence, etc.).
  Future<void> write(String key, String value) => _write(key, value);
  Future<String?> read(String key) => _read(key);
  Future<void> delete(String key) => _delete(key);

  Future<void> clearAuth() async {
    await _delete(_tokenKey);
    await _delete(_refreshKey);
    await _delete(_userIdKey);
    await _delete(_phoneKey);
    await _delete(_userSnapshotKey);
  }

  Future<void> clearAll() async {
    try {
      await _storage.deleteAll();
    } catch (_) {}
    final prefs = await SharedPreferences.getInstance();
    final keys = prefs.getKeys().where((k) => k.startsWith('wamu_')).toList();
    for (final k in keys) {
      await prefs.remove(k);
    }
  }
}

final secureStorageProvider = Provider<SecureStorageService>(
  (ref) => SecureStorageService(),
);
