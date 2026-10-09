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

  Future<String?> requestOtp(String phone) async {
    try {
      final response = await _client.post('/auth/request-otp', data: {'phone': phone});
      await _storage.savePhone(phone);
      final data = response.data;
      if (data is Map && data['mock_hint'] != null) {
        return data['mock_hint'].toString();
      }
      return null;
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
    await _storage.saveUserId(user.id);
    final phone = phoneHint ?? user.phone;
    if (phone.isNotEmpty) await _storage.savePhone(phone);
    return user;
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
      return UserModel.fromJson(Map<String, dynamic>.from(raw));
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
      return UserModel.fromJson(Map<String, dynamic>.from(raw));
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
      return UserModel.fromJson(Map<String, dynamic>.from(raw));
    } on DioException catch (e) {
      throw _mapDio(e, fallback: 'Could not update privacy');
    }
  }

  Future<UserModel?> getCurrentUser() async {
    final token = await _storage.getToken();
    if (token == null || token.isEmpty) return null;
    try {
      final response = await _client.get('/users/me');
      final raw = response.data;
      if (raw is! Map) return null;
      return UserModel.fromJson(Map<String, dynamic>.from(raw));
    } on DioException catch (e) {
      // Only clear session on auth failure — keep token on flaky tunnel/network.
      final code = e.response?.statusCode;
      if (code == 401 || code == 403) {
        await _storage.clearAuth();
        return null;
      }
      rethrow;
    }
  }

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
  const AuthState({this.status = AuthStatus.unknown, this.user, this.mockOtpHint});

  final AuthStatus status;
  final UserModel? user;
  final String? mockOtpHint;

  AuthState copyWith({AuthStatus? status, UserModel? user, String? mockOtpHint}) {
    return AuthState(
      status: status ?? this.status,
      user: user ?? this.user,
      mockOtpHint: mockOtpHint ?? this.mockOtpHint,
    );
  }
}

class AuthNotifier extends StateNotifier<AuthState> {
  AuthNotifier(this._repo) : super(const AuthState()) {
    _bootstrap();
  }

  final AuthRepository _repo;

  Future<void> _bootstrap() async {
    try {
      final user = await _repo.getCurrentUser();
      if (user == null) {
        state = const AuthState(status: AuthStatus.unauthenticated);
        return;
      }
      state = AuthState(
        status: user.needsProfileSetup ? AuthStatus.needsProfile : AuthStatus.authenticated,
        user: user,
      );
    } catch (_) {
      // Network/tunnel blip with a stored token — stay unknown briefly then unauthenticated UI
      // without wiping the token so a retry can succeed.
      state = const AuthState(status: AuthStatus.unauthenticated);
    }
  }

  Future<void> requestOtp(String phone) async {
    final hint = await _repo.requestOtp(phone);
    state = state.copyWith(mockOtpHint: hint);
  }

  Future<void> verifyOtp(String phone, String code) async {
    final user = await _repo.verifyOtp(phone, code);
    state = AuthState(
      status: user.needsProfileSetup ? AuthStatus.needsProfile : AuthStatus.authenticated,
      user: user,
    );
  }

  Future<void> claimDeviceLink(String token, {String? deviceName}) async {
    final user = await _repo.claimDeviceLink(token, deviceName: deviceName);
    state = AuthState(
      status: user.needsProfileSetup ? AuthStatus.needsProfile : AuthStatus.authenticated,
      user: user,
    );
  }

  Future<void> completeProfile(String name, {String? email}) async {
    final parts = name.trim().split(RegExp(r'\s+'));
    final first = parts.first;
    final last = parts.length > 1 ? parts.skip(1).join(' ') : null;
    final user = await _repo.updateProfile(firstName: first, lastName: last);
    state = AuthState(status: AuthStatus.authenticated, user: user);
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
    state = AuthState(status: AuthStatus.authenticated, user: user);
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
    state = state.copyWith(user: user);
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
    state = state.copyWith(user: user);
  }

  Future<void> refreshMe() async {
    final user = await _repo.getCurrentUser();
    if (user == null) return;
    state = AuthState(
      status: user.needsProfileSetup ? AuthStatus.needsProfile : AuthStatus.authenticated,
      user: user,
    );
  }

  Future<void> logout() async {
    await _repo.logout();
    state = const AuthState(status: AuthStatus.unauthenticated);
  }
}

final authProvider = StateNotifierProvider<AuthNotifier, AuthState>((ref) {
  return AuthNotifier(ref.watch(authRepositoryProvider));
});
