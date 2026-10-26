import 'dart:async';

import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:flutter/material.dart';

import '../../firebase_options.dart';
import '../../features/profile/commerce_notif_provider.dart';
import '../routing/app_router.dart';
import '../storage/secure_storage.dart';
import 'chat_focus.dart';
import 'push_token_repository.dart';

/// Background isolate entry. The OS shows the generic notification payload.
@pragma('vm:entry-point')
Future<void> firebaseMessagingBackgroundHandler(RemoteMessage message) async {
  // Wake only. Do not build a second notification here.
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

    _foregroundSub?.cancel();
    _foregroundSub = FirebaseMessaging.onMessage.listen((message) {
      if (_isChatPush(message)) {
        _onChatPush(message, tapped: false);
      } else {
        unawaited(_refreshCommerceInbox());
      }
    });

    _openedSub?.cancel();
    _openedSub = FirebaseMessaging.onMessageOpenedApp.listen((message) {
      if (_isChatPush(message)) {
        _onChatPush(message, tapped: true);
      } else {
        unawaited(_refreshCommerceInbox());
      }
    });

    final initial = await FirebaseMessaging.instance.getInitialMessage();
    if (initial != null) {
      if (_isChatPush(initial)) {
        _onChatPush(initial, tapped: true);
      }
    }
  }

  bool _isChatPush(RemoteMessage message) {
    final type = message.data['type'] ?? '';
    return type == 'NEW_MESSAGE' && (message.data['conversation_id'] ?? '').isNotEmpty;
  }

  String _chatLabel(RemoteMessage message) {
    final kind = (message.data['message_kind'] ?? '').toUpperCase();
    switch (kind) {
      case 'IMAGE':
        return 'Photo';
      case 'VOICE':
        return 'Voice message';
      case 'DOCUMENT':
        return 'Document';
      default:
        return 'New message';
    }
  }

  void _onChatPush(RemoteMessage message, {required bool tapped}) {
    final id = message.data['conversation_id'] ?? '';
    if (id.isEmpty) return;
    if (tapped) {
      _ref.read(pendingChatOpenProvider.notifier).state = id;
      return;
    }
    final open = _ref.read(openChatIdProvider);
    if (open == id) return;
    final context = _ref.read(appRouterProvider).routerDelegate.navigatorKey.currentContext;
    if (context == null) return;
    final messenger = ScaffoldMessenger.maybeOf(context);
    messenger?.showSnackBar(
      SnackBar(
        content: Text(_chatLabel(message)),
        action: SnackBarAction(
          label: 'Open',
          onPressed: () {
            _ref.read(pendingChatOpenProvider.notifier).state = id;
          },
        ),
      ),
    );
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
