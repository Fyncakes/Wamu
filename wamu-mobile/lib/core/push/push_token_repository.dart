import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../network/api_client.dart';

/// Registers FCM/APNs tokens with the backend (data-only push).
class PushTokenRepository {
  PushTokenRepository(this._client);

  final ApiClient _client;

  Future<void> register({
    required String token,
    String platform = 'android',
  }) async {
    await _client.put('/devices/push-token', data: {
      'token': token,
      'platform': platform,
    });
  }

  Future<void> unregister(String token) async {
    final q = Uri.encodeQueryComponent(token);
    await _client.delete('/devices/push-token?token=$q');
  }
}

final pushTokenRepositoryProvider = Provider<PushTokenRepository>((ref) {
  return PushTokenRepository(ref.watch(apiClientProvider));
});

/// Best-effort register after login. Prefer [PushBootstrap.syncToken] which
/// fetches the FCM token when Firebase is configured.
Future<void> registerPushTokenIfSupported(Ref ref, {String? token}) async {
  if (kIsWeb) return;
  final t = (token ?? '').trim();
  if (t.isEmpty) return;
  try {
    final platform = defaultTargetPlatform == TargetPlatform.iOS ? 'ios' : 'android';
    await ref.read(pushTokenRepositoryProvider).register(token: t, platform: platform);
  } on DioException {
    // Backend optional during local demos — ignore.
  } catch (_) {}
}
