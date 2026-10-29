import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

import '../../core/notifications/local_notifications.dart';
import '../../core/notifications/notification_sound_service.dart';
import '../../core/push/call_focus.dart';
import '../../core/theme/notification_settings_provider.dart';
import '../../features/auth/auth_provider.dart';
import '../../features/calls/active_call_screen.dart';
import '../../features/calls/calls_repository.dart';

/// Global incoming-call listener while authenticated (any tab).
///
/// Rings from WebSocket when the app is open, and from FCM via
/// [pendingIncomingCallProvider] when the phone was asleep.
class IncomingCallHost extends ConsumerStatefulWidget {
  const IncomingCallHost({super.key, required this.child});

  final Widget child;

  @override
  ConsumerState<IncomingCallHost> createState() => _IncomingCallHostState();
}

class _IncomingCallHostState extends ConsumerState<IncomingCallHost> {
  WebSocketChannel? _channel;
  StreamSubscription? _sub;
  bool _dialogOpen = false;
  String? _boundUserId;
  String? _activeCallId;

  @override
  void dispose() {
    try {
      unawaited(ref.read(notificationSoundServiceProvider).stopRingtone());
    } catch (_) {}
    _tearDown();
    super.dispose();
  }

  void _tearDown() {
    _sub?.cancel();
    _sub = null;
    _channel?.sink.close();
    _channel = null;
    _boundUserId = null;
  }

  Future<void> _ensureListening(String? userId) async {
    if (userId == null || userId.isEmpty) {
      _tearDown();
      return;
    }
    if (_boundUserId == userId && _channel != null) return;
    _tearDown();
    _boundUserId = userId;
    try {
      _channel = await ref.read(callsRepositoryProvider).connectSignal();
      _sub = _channel!.stream.listen((raw) {
        try {
          final data = raw is String
              ? jsonDecode(raw) as Map<String, dynamic>
              : Map<String, dynamic>.from(raw as Map);
          final event = data['event']?.toString();
          if (event == 'call.ended' || event == 'call.rejected') {
            final id = data['id']?.toString() ?? data['call_id']?.toString();
            if (id != null && id.isNotEmpty) {
              ref.read(cancelledCallIdProvider.notifier).state = id;
            }
            return;
          }
          if (event != 'call.incoming') return;
          final call = CallModel.fromJson(data);
          unawaited(_showIncoming(call, data['caller_name']?.toString()));
        } catch (_) {}
      });
    } catch (_) {
      _boundUserId = null;
    }
  }

  Future<void> _showFromPush(PendingIncomingCall pending) async {
    CallModel call;
    try {
      call = await ref.read(callsRepositoryProvider).get(pending.callId);
    } catch (_) {
      call = CallModel(
        id: pending.callId,
        callerId: pending.callerId ?? '',
        calleeId: ref.read(authProvider).user?.id ?? '',
        callType: pending.callType.toUpperCase() == 'VIDEO' ? 'VIDEO' : 'VOICE',
        status: 'RINGING',
        peerName: pending.callerName,
        direction: 'INCOMING',
      );
    }
    if (call.status != 'RINGING') return;
    await _showIncoming(call, pending.callerName ?? call.peerName);
  }

  Future<void> _showIncoming(CallModel call, String? callerName) async {
    if (!mounted || _dialogOpen) return;
    if (call.id.isEmpty) return;
    if (_activeCallId == call.id) return;
    _dialogOpen = true;
    _activeCallId = call.id;
    final sounds = ref.read(notificationSoundServiceProvider);
    final prefs = ref.read(notificationSettingsProvider);
    if (prefs.callAlerts) {
      await sounds.startRingtone();
    }
    final name = callerName ?? call.peerName ?? 'Someone';
    bool? accept;
    try {
      accept = await showDialog<bool>(
        context: context,
        barrierDismissible: false,
        builder: (ctx) => AlertDialog(
          title: Text(call.isVideo ? 'Incoming video call' : 'Incoming voice call'),
          content: Text('$name is calling you on Wamu'),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Decline')),
            ElevatedButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Accept')),
          ],
        ),
      );
    } finally {
      await sounds.stopRingtone();
      unawaited(cancelWamuNotificationForPayload('call:${call.id}'));
      _dialogOpen = false;
      if (_activeCallId == call.id) _activeCallId = null;
    }
    if (!mounted) return;
    if (accept == true) {
      if (!mounted) return;
      await Navigator.of(context).push(
        MaterialPageRoute(
          builder: (_) => ActiveCallScreen(
            callId: call.id,
            isCaller: false,
            peerName: name,
            video: call.isVideo,
          ),
        ),
      );
    } else if (accept == false) {
      try {
        await ref.read(callsRepositoryProvider).reject(call.id);
      } catch (_) {}
    }
  }

  void _dismissIfCancelled(String? callId) {
    if (callId == null || callId.isEmpty) return;
    if (_activeCallId != callId || !_dialogOpen) return;
    final nav = Navigator.of(context, rootNavigator: true);
    if (nav.canPop()) {
      nav.pop(null);
    }
    unawaited(cancelWamuNotificationForPayload('call:$callId'));
  }

  @override
  Widget build(BuildContext context) {
    final userId = ref.watch(authProvider).user?.id;
    WidgetsBinding.instance.addPostFrameCallback((_) => _ensureListening(userId));

    ref.listen<PendingIncomingCall?>(pendingIncomingCallProvider, (prev, next) {
      if (next == null) return;
      // Clear so the same call can re-queue if needed after dismiss.
      Future.microtask(() {
        if (ref.read(pendingIncomingCallProvider)?.callId == next.callId) {
          ref.read(pendingIncomingCallProvider.notifier).state = null;
        }
      });
      unawaited(_showFromPush(next));
    });

    ref.listen<String?>(cancelledCallIdProvider, (prev, next) {
      if (next == null || next.isEmpty) return;
      _dismissIfCancelled(next);
      Future.microtask(() {
        if (ref.read(cancelledCallIdProvider) == next) {
          ref.read(cancelledCallIdProvider.notifier).state = null;
        }
      });
    });

    return widget.child;
  }
}
