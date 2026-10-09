import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

/// Persists auth tokens using platform secure storage.
class SecureStorageService {
  SecureStorageService({FlutterSecureStorage? storage})
      : _storage = storage ??
            const FlutterSecureStorage(
              aOptions: AndroidOptions(encryptedSharedPreferences: true),
            );

  final FlutterSecureStorage _storage;

  static const _tokenKey = 'auth_token';
  static const _refreshKey = 'refresh_token';
  static const _userIdKey = 'user_id';
  static const _phoneKey = 'phone';

  Future<void> saveToken(String token) => _storage.write(key: _tokenKey, value: token);
  Future<String?> getToken() => _storage.read(key: _tokenKey);

  Future<void> saveRefreshToken(String token) =>
      _storage.write(key: _refreshKey, value: token);
  Future<String?> getRefreshToken() => _storage.read(key: _refreshKey);

  Future<void> saveUserId(String userId) => _storage.write(key: _userIdKey, value: userId);
  Future<String?> getUserId() => _storage.read(key: _userIdKey);

  Future<void> savePhone(String phone) => _storage.write(key: _phoneKey, value: phone);
  Future<String?> getPhone() => _storage.read(key: _phoneKey);

  /// Generic key-value helpers (cart persistence, etc.).
  Future<void> write(String key, String value) => _storage.write(key: key, value: value);
  Future<String?> read(String key) => _storage.read(key: key);
  Future<void> delete(String key) => _storage.delete(key: key);

  Future<void> clearAuth() async {
    await _storage.delete(key: _tokenKey);
    await _storage.delete(key: _refreshKey);
    await _storage.delete(key: _userIdKey);
    await _storage.delete(key: _phoneKey);
  }

  Future<void> clearAll() => _storage.deleteAll();
}

final secureStorageProvider = Provider<SecureStorageService>(
  (ref) => SecureStorageService(),
);
