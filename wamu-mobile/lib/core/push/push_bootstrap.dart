import 'dart:async';

import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../firebase_options.dart';
import '../../features/profile/commerce_notif_provider.dart';
import '../storage/secure_storage.dart';
import 'push_token_repository.dart';

/// Background isolate entry — keep data-only; never log message bodies.
@pragma('vm:entry-point')
Future<void> firebaseMessagingBackgroundHandler(RemoteMessage message) async {
  // Wake only — UI reads the authenticated inbox. No plaintext toast here.
}

/// Initializes Firebase + FCM when options are configured (store builds).
/// Web / placeholder options → no-op so Chrome demos keep working.
class PushBootstrap {
  PushBootstrap(this._ref);

  final Ref _ref;
  StreamSubscription<String>? _tokenSub;
  StreamSubscription<RemoteMessage>? _foregroundSub;
  StreamSubscription<RemoteMessage>? _openedSub;
  bool _started = false;

  Future<bool> ensureInitialized() async {
    if (kIsWeb) return false;
    if (Firebase.apps.isNotEmpty) return true;
    try {
      final opts = DefaultFirebaseOptions.currentPlatform;
      // Placeholder until `flutterfire configure` (see PUSH_NOTIFICATIONS.md).
      if (opts.projectId == 'wamu-unconfigured') return false;
      await Firebase.initializeApp(options: opts);
      FirebaseMessaging.onBackgroundMessage(firebaseMessagingBackgroundHandler);
      return true;
    } catch (_) {
      return false;
    }
  }

  /// Register current FCM token with the API when the user is signed in.
  Future<void> syncToken() async {
    final access = await _ref.read(secureStorageProvider).getToken();
    if (access == null || access.isEmpty) return;

    final ready = await ensureInitialized();
    if (!ready) return;

    try {
      final messaging = FirebaseMessaging.instance;
      await messaging.requestPermission(alert: true, badge: true, sound: true);
      final token = await messaging.getToken();
      if (token == null || token.isEmpty) return;
      await registerPushTokenIfSupported(_ref, token: token);
    } catch (_) {
      // Missing google-services.json / APNs — ignore locally.
    }
  }

  void startTokenRefreshListener() {
    if (_started || kIsWeb) return;
    _started = true;
    unawaited(_listen());
  }

  Future<void> _listen() async {
    final ready = await ensureInitialized();
    if (!ready) return;
    _tokenSub?.cancel();
    _tokenSub = FirebaseMessaging.instance.onTokenRefresh.listen((token) {
      unawaited(registerPushTokenIfSupported(_ref, token: token));
    });

    // Foreground: refresh in-app commerce inbox (shell snackbar / badge).
    _foregroundSub?.cancel();
    _foregroundSub = FirebaseMessaging.onMessage.listen((_) {
      unawaited(_refreshCommerceInbox());
    });

    // Notification tap while app in background → refresh so deeplink snackbar can fire.
    _openedSub?.cancel();
    _openedSub = FirebaseMessaging.onMessageOpenedApp.listen((_) {
      unawaited(_refreshCommerceInbox());
    });
  }

  Future<void> _refreshCommerceInbox() async {
    try {
      // Lazy import path via provider — avoids circular imports at load time.
      final commerce = _ref.read(commerceNotifProvider.notifier);
      await commerce.refresh();
    } catch (_) {}
  }

  Future<void> unregisterCurrent() async {
    final ready = await ensureInitialized();
    if (!ready) return;
    try {
      final token = await FirebaseMessaging.instance.getToken();
      if (token == null || token.isEmpty) return;
      await _ref.read(pushTokenRepositoryProvider).unregister(token);
    } catch (_) {}
  }

  void dispose() {
    _tokenSub?.cancel();
    _tokenSub = null;
    _foregroundSub?.cancel();
    _foregroundSub = null;
    _openedSub?.cancel();
    _openedSub = null;
    _started = false;
  }
}
