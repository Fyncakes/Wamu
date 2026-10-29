import 'dart:async';

import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../firebase_options.dart';
import '../../features/profile/commerce_notif_provider.dart';
import '../notifications/local_notifications.dart';
import '../storage/secure_storage.dart';
import 'call_focus.dart';
import 'chat_focus.dart';
import 'push_token_repository.dart';

/// Background isolate entry. The OS shows the FCM notification payload.
/// For data-only call wakes, mirror a local heads-up on the calls channel.
@pragma('vm:entry-point')
Future<void> firebaseMessagingBackgroundHandler(RemoteMessage message) async {
  final type = message.data['type']?.toString() ?? '';
  if (type != 'INCOMING_CALL') return;
  final callId = message.data['call_id']?.toString() ?? '';
  if (callId.isEmpty) return;
  // When FCM already includes a notification block, Android shows it — skip duplicate.
  if (message.notification != null) return;
  try {
    await ensureLocalNotificationsReady();
    final kind = (message.data['call_type']?.toString() ?? 'VOICE').toUpperCase();
    final name = message.data['caller_name']?.toString();
    await showWamuLocalNotification(
      title: name == null || name.isEmpty ? 'Wamu' : name,
      body: kind == 'VIDEO' ? 'Incoming video call' : 'Incoming voice call',
      payload: 'call:$callId',
      callAlert: true,
    );
  } catch (_) {}
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
      await ensureLocalNotificationsReady();
      final messaging = FirebaseMessaging.instance;
      await messaging.requestPermission(alert: true, badge: true, sound: true);
      // Android 13+: also ask via the notifications plugin channel.
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

    onWamuNotificationTap ??= (payload) {
      _handleLocalTap(payload);
    };

    _tokenSub?.cancel();
    _tokenSub = FirebaseMessaging.instance.onTokenRefresh.listen((token) {
      unawaited(registerPushTokenIfSupported(_ref, token: token));
    });

    _foregroundSub?.cancel();
    _foregroundSub = FirebaseMessaging.onMessage.listen((message) {
      unawaited(_onForeground(message));
    });

    _openedSub?.cancel();
    _openedSub = FirebaseMessaging.onMessageOpenedApp.listen((message) {
      _routePush(message, tapped: true);
    });

    final initial = await FirebaseMessaging.instance.getInitialMessage();
    if (initial != null) {
      _routePush(initial, tapped: true);
    }
  }

  void _handleLocalTap(String? payload) {
    if (payload == null || payload.isEmpty) return;
    if (payload.startsWith('call:')) {
      final callId = payload.substring(5);
      if (callId.isEmpty) return;
      _ref.read(pendingIncomingCallProvider.notifier).state = PendingIncomingCall(
        callId: callId,
        callType: 'VOICE',
      );
      return;
    }
    if (payload.startsWith('chat:')) {
      final id = payload.substring(5);
      if (id.isNotEmpty) {
        _ref.read(pendingChatOpenProvider.notifier).state = id;
      }
    }
  }

  Future<void> _onForeground(RemoteMessage message) async {
    final type = message.data['type']?.toString() ?? '';
    if (type == 'CALL_CANCELLED') {
      final callId = message.data['call_id']?.toString() ?? '';
      if (callId.isNotEmpty) {
        _ref.read(cancelledCallIdProvider.notifier).state = callId;
        unawaited(cancelWamuNotificationForPayload('call:$callId'));
      }
      return;
    }
    if (type == 'INCOMING_CALL') {
      _routePush(message, tapped: false);
      return;
    }
    unawaited(_showForegroundBanner(message));
    if (_isChatPush(message)) {
      _onChatPush(message, tapped: false);
    } else {
      unawaited(_refreshCommerceInbox());
    }
  }

  void _routePush(RemoteMessage message, {required bool tapped}) {
    final type = message.data['type']?.toString() ?? '';
    if (type == 'CALL_CANCELLED') {
      final callId = message.data['call_id']?.toString() ?? '';
      if (callId.isNotEmpty) {
        _ref.read(cancelledCallIdProvider.notifier).state = callId;
        unawaited(cancelWamuNotificationForPayload('call:$callId'));
      }
      return;
    }
    if (type == 'INCOMING_CALL') {
      _onCallPush(message, tapped: tapped);
      return;
    }
    if (_isChatPush(message)) {
      _onChatPush(message, tapped: tapped);
      return;
    }
    if (tapped) {
      unawaited(_refreshCommerceInbox());
    }
  }

  bool _isChatPush(RemoteMessage message) {
    final type = message.data['type'] ?? '';
    return type == 'NEW_MESSAGE' && (message.data['conversation_id'] ?? '').isNotEmpty;
  }

  void _onCallPush(RemoteMessage message, {required bool tapped}) {
    final callId = message.data['call_id']?.toString() ?? '';
    if (callId.isEmpty) return;
    final pending = PendingIncomingCall(
      callId: callId,
      callType: message.data['call_type']?.toString() ?? 'VOICE',
      callerId: message.data['caller_id']?.toString(),
      callerName: message.data['caller_name']?.toString(),
    );
    _ref.read(pendingIncomingCallProvider.notifier).state = pending;
    if (!tapped) {
      // App already open — still show a heads-up in case the dialog is delayed.
      unawaited(
        showWamuLocalNotification(
          title: pending.callerName?.isNotEmpty == true
              ? pending.callerName!
              : 'Wamu',
          body: pending.isVideo ? 'Incoming video call' : 'Incoming voice call',
          payload: 'call:$callId',
          callAlert: true,
        ),
      );
    }
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

  Future<void> _showForegroundBanner(RemoteMessage message) async {
    final title = message.notification?.title ??
        message.data['title']?.toString() ??
        'Wamu';
    final body = message.notification?.body ??
        message.data['body']?.toString() ??
        (_isChatPush(message) ? _chatLabel(message) : 'New update');
    final open = _ref.read(openChatIdProvider);
    final convo = message.data['conversation_id'] ?? '';
    if (convo.isNotEmpty && open == convo) return;
    await showWamuLocalNotification(
      title: title,
      body: body,
      payload: convo.isEmpty ? null : 'chat:$convo',
    );
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
