import 'dart:async';
import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/network/api_client.dart';
import '../../core/storage/secure_storage.dart';
import '../../shared/models/user_model.dart';

/// OTP auth + profile against WAMU FastAPI (`code`, `/users/me`).
class AuthRepository {
  AuthRepository(this._client, this._storage);

  final ApiClient _client;
  final SecureStorageService _storage;

  Future<void> requestOtp(String phone) async {
    try {
      await _client.post('/auth/request-otp', data: {'phone': phone});
      try {
        await _storage.savePhone(phone);
      } catch (_) {
        // Storage failures must not block login (common on LAN http web).
      }
    } on DioException catch (e) {
      throw _mapDio(e, fallback: 'Failed to send OTP');
    }
  }

  Future<UserModel> verifyOtp(String phone, String code) async {
    try {
      final response = await _client.post('/auth/verify-otp', data: {
        'phone': phone,
        'code': code,
      });
      final raw = response.data;
      if (raw is! Map) {
        throw StateError('Unexpected login response from server');
      }
      return await _persistSession(Map<String, dynamic>.from(raw), phoneHint: phone);
    } on DioException catch (e) {
      throw _mapDio(e, fallback: 'Verification failed');
    }
  }

  Future<UserModel> claimDeviceLink(String token, {String? deviceName}) async {
    try {
      final response = await _client.post('/auth/device-link/claim', data: {
        'token': token,
        if (deviceName != null) 'device_name': deviceName,
      });
      final raw = response.data;
      if (raw is! Map) {
        throw StateError('Unexpected login response from server');
      }
      return await _persistSession(Map<String, dynamic>.from(raw));
    } on DioException catch (e) {
      throw _mapDio(e, fallback: 'Could not connect this device');
    }
  }

  Future<({String id, String qr, int expiresIn})> createDeviceLink() async {
    try {
      final response = await _client.post('/auth/device-link');
      final raw = response.data;
      if (raw is! Map) throw StateError('Unexpected QR response');
      final data = Map<String, dynamic>.from(raw);
      return (
        id: data['id'].toString(),
        qr: data['qr'].toString(),
        expiresIn: (data['expires_in'] as num?)?.toInt() ?? 120,
      );
    } on DioException catch (e) {
      throw _mapDio(e, fallback: 'Could not create QR code');
    }
  }

  Future<({String status, String? deviceName})> deviceLinkStatus(String id) async {
    try {
      final response = await _client.get('/auth/device-link/$id');
      final raw = response.data;
      if (raw is! Map) throw StateError('Unexpected status response');
      final data = Map<String, dynamic>.from(raw);
      return (
        status: data['status']?.toString() ?? 'pending',
        deviceName: data['device_name']?.toString(),
      );
    } on DioException catch (e) {
      throw _mapDio(e, fallback: 'Could not check QR status');
    }
  }

  Future<void> revokeDeviceLinks() async {
    try {
      await _client.post('/auth/device-link/revoke');
    } catch (_) {}
  }

  Future<UserModel> _persistSession(Map<String, dynamic> data, {String? phoneHint}) async {
    final access = data['access_token']?.toString();
    final refresh = data['refresh_token']?.toString();
    if (access == null || access.isEmpty) {
      throw StateError('Login response missing access token');
    }
    await _storage.saveToken(access);
    if (refresh != null) await _storage.saveRefreshToken(refresh);

    final userRaw = data['user'];
    final userMap = userRaw is Map ? Map<String, dynamic>.from(userRaw) : data;
    final user = UserModel.fromJson(userMap);
    await _cacheUser(user);
    final phone = phoneHint ?? user.phone;
    if (phone.isNotEmpty) await _storage.savePhone(phone);
    return user;
  }

  Future<void> _cacheUser(UserModel user) async {
    await _storage.saveUserId(user.id);
    try {
      await _storage.saveUserSnapshot(jsonEncode(user.toJson()));
    } catch (_) {}
  }

  /// Last known profile for offline reopen (tokens stay in secure storage).
  Future<UserModel?> loadCachedUser() async {
    try {
      final raw = await _storage.getUserSnapshot();
      if (raw != null && raw.isNotEmpty) {
        final map = jsonDecode(raw);
        if (map is Map<String, dynamic>) {
          return UserModel.fromJson(map);
        }
        if (map is Map) {
          return UserModel.fromJson(Map<String, dynamic>.from(map));
        }
      }
    } catch (_) {}

    final id = await _storage.getUserId();
    final phone = await _storage.getPhone();
    if ((id == null || id.isEmpty) && (phone == null || phone.isEmpty)) {
      return null;
    }
    return UserModel(
      id: id ?? '',
      phone: phone ?? '',
    );
  }

  Future<bool> hasLocalSession() async {
    final token = await _storage.getToken();
    if (token != null && token.isNotEmpty) return true;
    final refresh = await _storage.getRefreshToken();
    return refresh != null && refresh.isNotEmpty;
  }

  Future<UserModel> updateProfile({
    required String firstName,
    String? lastName,
    String? interests,
    String? bio,
    String? avatarUrl,
    bool? wantsToBuy,
    bool? ownsBusiness,
    bool? wantsToRide,
  }) async {
    try {
      final response = await _client.patch('/users/me/profile', data: {
        'first_name': firstName,
        if (lastName != null && lastName.isNotEmpty) 'last_name': lastName,
        if (interests != null) 'interests': interests,
        if (bio != null) 'bio': bio,
        if (avatarUrl != null) 'avatar_url': avatarUrl,
        if (wantsToBuy != null) 'wants_to_buy': wantsToBuy,
        if (ownsBusiness != null) 'owns_business': ownsBusiness,
        if (wantsToRide != null) 'wants_to_ride': wantsToRide,
      });
      final raw = response.data;
      if (raw is! Map) throw StateError('Unexpected profile response');
      final user = UserModel.fromJson(Map<String, dynamic>.from(raw));
      await _cacheUser(user);
      return user;
    } on DioException catch (e) {
      throw _mapDio(e, fallback: 'Could not save profile');
    }
  }

  Future<UserModel> updateCapabilities({
    required bool wantsToBuy,
    required bool ownsBusiness,
    required bool wantsToRide,
  }) async {
    try {
      final response = await _client.patch('/users/me/profile', data: {
        'wants_to_buy': wantsToBuy,
        'owns_business': ownsBusiness,
        'wants_to_ride': wantsToRide,
      });
      final raw = response.data;
      if (raw is! Map) throw StateError('Unexpected profile response');
      final user = UserModel.fromJson(Map<String, dynamic>.from(raw));
      await _cacheUser(user);
      return user;
    } on DioException catch (e) {
      throw _mapDio(e, fallback: 'Could not update roles');
    }
  }

  Future<UserModel> updatePrivacy({
    bool? showLastSeen,
    bool? showOnline,
    bool? showReadReceipts,
  }) async {
    try {
      final response = await _client.patch('/users/me/privacy', data: {
        if (showLastSeen != null) 'show_last_seen': showLastSeen,
        if (showOnline != null) 'show_online': showOnline,
        if (showReadReceipts != null) 'show_read_receipts': showReadReceipts,
      });
      final raw = response.data;
      if (raw is! Map) throw StateError('Unexpected privacy response');
      final user = UserModel.fromJson(Map<String, dynamic>.from(raw));
      await _cacheUser(user);
      return user;
    } on DioException catch (e) {
      throw _mapDio(e, fallback: 'Could not update privacy');
    }
  }

  /// Online verification of `/users/me`. Throws [DioException] on network errors.
  Future<UserModel?> fetchCurrentUser() async {
    final token = await _storage.getToken();
    if (token == null || token.isEmpty) return null;
    try {
      final response = await _client.get('/users/me');
      final raw = response.data;
      if (raw is! Map) return null;
      final user = UserModel.fromJson(Map<String, dynamic>.from(raw));
      await _cacheUser(user);
      return user;
    } on DioException catch (e) {
      final code = e.response?.statusCode;
      if (code == 401 || code == 403) {
        await _storage.clearAuth();
        return null;
      }
      rethrow;
    }
  }

  @Deprecated('Use fetchCurrentUser')
  Future<UserModel?> getCurrentUser() => fetchCurrentUser();

  Future<void> logout() => _storage.clearAuth();

  Exception _mapDio(DioException e, {required String fallback}) {
    final code = e.response?.statusCode;
    final detail = e.response?.data;
    String? serverMsg;
    if (detail is Map && detail['detail'] != null) {
      serverMsg = detail['detail'].toString();
    } else if (detail is String && detail.isNotEmpty) {
      serverMsg = detail;
    }
    if (code == 429) {
      return Exception(serverMsg ?? 'Too many OTP requests. Wait a minute and try again.');
    }
    if (code == 400 || code == 401 || code == 403) {
      return Exception(serverMsg ?? fallback);
    }
    if (e.type == DioExceptionType.connectionTimeout ||
        e.type == DioExceptionType.receiveTimeout ||
        e.type == DioExceptionType.sendTimeout ||
        e.type == DioExceptionType.connectionError) {
      return Exception(
        'Cannot reach Wamu. Open Wamu server and scan the QR or paste your server link.',
      );
    }
    return Exception(serverMsg ?? '$fallback (${e.message})');
  }
}

final authRepositoryProvider = Provider<AuthRepository>((ref) {
  return AuthRepository(
    ref.watch(apiClientProvider),
    ref.watch(secureStorageProvider),
  );
});

enum AuthStatus { unknown, unauthenticated, needsProfile, authenticated }

class AuthState {
  const AuthState({
    this.status = AuthStatus.unknown,
    this.user,
    this.sessionVerified = false,
  });

  final AuthStatus status;
  final UserModel? user;

  /// True only after a successful `/users/me` (or login) against the server.
  /// Offline reopen keeps [status] authenticated with this false.
  final bool sessionVerified;

  AuthState copyWith({
    AuthStatus? status,
    UserModel? user,
    bool? sessionVerified,
  }) {
    return AuthState(
      status: status ?? this.status,
      user: user ?? this.user,
      sessionVerified: sessionVerified ?? this.sessionVerified,
    );
  }
}

class AuthNotifier extends StateNotifier<AuthState> {
  AuthNotifier(this._repo) : super(const AuthState()) {
    _bootstrap();
  }

  final AuthRepository _repo;
  bool _syncing = false;

  AuthState _stateFor(UserModel user, {required bool verified}) {
    return AuthState(
      status: user.needsProfileSetup ? AuthStatus.needsProfile : AuthStatus.authenticated,
      user: user,
      sessionVerified: verified,
    );
  }

  Future<void> _bootstrap() async {
    final hasSession = await _repo.hasLocalSession();
    if (!hasSession) {
      state = const AuthState(status: AuthStatus.unauthenticated);
      return;
    }

    try {
      final user = await _repo.fetchCurrentUser().timeout(const Duration(seconds: 12));
      if (user == null) {
        state = const AuthState(status: AuthStatus.unauthenticated);
        return;
      }
      state = _stateFor(user, verified: true);
    } on TimeoutException {
      await _enterOfflineIfPossible();
    } on DioException catch (e) {
      final code = e.response?.statusCode;
      if (code == 401 || code == 403) {
        state = const AuthState(status: AuthStatus.unauthenticated);
        return;
      }
      await _enterOfflineIfPossible();
    } catch (_) {
      await _enterOfflineIfPossible();
    }
  }

  Future<void> _enterOfflineIfPossible() async {
    final cached = await _repo.loadCachedUser();
    if (cached != null) {
      state = _stateFor(cached, verified: false);
      return;
    }
    // Tokens remain so reconnect can restore; stay on login until then.
    state = const AuthState(status: AuthStatus.unauthenticated);
  }

  /// Called when connectivity returns — refresh profile without forcing OTP.
  Future<void> syncAfterReconnect() async {
    if (_syncing) return;
    if (state.status != AuthStatus.authenticated &&
        state.status != AuthStatus.needsProfile) {
      // May have tokens but no UI session yet (cold start with empty cache).
      if (!await _repo.hasLocalSession()) return;
    }
    _syncing = true;
    try {
      final user = await _repo.fetchCurrentUser().timeout(const Duration(seconds: 20));
      if (user == null) {
        state = const AuthState(status: AuthStatus.unauthenticated);
        return;
      }
      state = _stateFor(user, verified: true);
    } on DioException catch (e) {
      final code = e.response?.statusCode;
      if (code == 401 || code == 403) {
        await _repo.logout();
        state = const AuthState(status: AuthStatus.unauthenticated);
      }
      // Stay on cached session for other errors.
    } catch (_) {
      // Stay offline with cached session.
    } finally {
      _syncing = false;
    }
  }

  Future<void> requestOtp(String phone) async {
    await _repo.requestOtp(phone);
  }

  Future<void> verifyOtp(String phone, String code) async {
    final user = await _repo.verifyOtp(phone, code);
    state = _stateFor(user, verified: true);
  }

  Future<void> claimDeviceLink(String token, {String? deviceName}) async {
    final user = await _repo.claimDeviceLink(token, deviceName: deviceName);
    state = _stateFor(user, verified: true);
  }

  Future<void> completeProfile(String name, {String? email}) async {
    final parts = name.trim().split(RegExp(r'\s+'));
    final first = parts.first;
    final last = parts.length > 1 ? parts.skip(1).join(' ') : null;
    final user = await _repo.updateProfile(firstName: first, lastName: last);
    state = _stateFor(user, verified: true);
  }

  Future<void> updateFullProfile({
    required String firstName,
    String? lastName,
    String? bio,
    String? avatarUrl,
  }) async {
    final user = await _repo.updateProfile(
      firstName: firstName,
      lastName: lastName,
      bio: bio,
      avatarUrl: avatarUrl,
    );
    state = _stateFor(user, verified: true);
  }

  Future<void> updatePrivacy({
    bool? showLastSeen,
    bool? showOnline,
    bool? showReadReceipts,
  }) async {
    final user = await _repo.updatePrivacy(
      showLastSeen: showLastSeen,
      showOnline: showOnline,
      showReadReceipts: showReadReceipts,
    );
    state = state.copyWith(user: user, sessionVerified: true);
  }

  Future<void> updateProfileCapabilities({
    required bool wantsToBuy,
    required bool ownsBusiness,
    required bool wantsToRide,
  }) async {
    final user = await _repo.updateCapabilities(
      wantsToBuy: wantsToBuy,
      ownsBusiness: ownsBusiness,
      wantsToRide: wantsToRide,
    );
    state = state.copyWith(user: user, sessionVerified: true);
  }

  Future<void> refreshMe() async {
    try {
      final user = await _repo.fetchCurrentUser();
      if (user == null) {
        state = const AuthState(status: AuthStatus.unauthenticated);
        return;
      }
      state = _stateFor(user, verified: true);
    } on DioException catch (e) {
      final code = e.response?.statusCode;
      if (code == 401 || code == 403) {
        state = const AuthState(status: AuthStatus.unauthenticated);
      }
      rethrow;
    }
  }

  Future<void> logout() async {
    await _repo.logout();
    state = const AuthState(status: AuthStatus.unauthenticated);
  }
}

final authProvider = StateNotifierProvider<AuthNotifier, AuthState>((ref) {
  return AuthNotifier(ref.watch(authRepositoryProvider));
});
