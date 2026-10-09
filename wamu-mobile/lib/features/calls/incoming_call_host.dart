import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

import '../../core/notifications/notification_sound_service.dart';
import '../../core/theme/notification_settings_provider.dart';
import '../../features/auth/auth_provider.dart';
import '../../features/calls/active_call_screen.dart';
import '../../features/calls/calls_repository.dart';

/// Global incoming-call listener while authenticated (any tab).
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
          if (data['event']?.toString() != 'call.incoming') return;
          final call = CallModel.fromJson(data);
          unawaited(_showIncoming(call, data['caller_name']?.toString()));
        } catch (_) {}
      });
    } catch (_) {
      _boundUserId = null;
    }
  }

  Future<void> _showIncoming(CallModel call, String? callerName) async {
    if (!mounted || _dialogOpen) return;
    _dialogOpen = true;
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
      _dialogOpen = false;
    }
    if (!mounted) return;
    if (accept == true) {
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
    } else {
      try {
        await ref.read(callsRepositoryProvider).reject(call.id);
      } catch (_) {}
    }
  }

  @override
  Widget build(BuildContext context) {
    final userId = ref.watch(authProvider).user?.id;
    WidgetsBinding.instance.addPostFrameCallback((_) => _ensureListening(userId));
    return widget.child;
  }
}
