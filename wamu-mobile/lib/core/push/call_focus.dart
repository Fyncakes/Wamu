import 'package:flutter_riverpod/flutter_riverpod.dart';

/// Incoming call from FCM (background/killed) waiting for IncomingCallHost UI.
class PendingIncomingCall {
  const PendingIncomingCall({
    required this.callId,
    required this.callType,
    this.callerId,
    this.callerName,
  });

  final String callId;
  final String callType;
  final String? callerId;
  final String? callerName;

  bool get isVideo => callType.toUpperCase() == 'VIDEO';
}

final pendingIncomingCallProvider = StateProvider<PendingIncomingCall?>((ref) => null);

/// When set, IncomingCallHost dismisses a ringing dialog for this call id.
final cancelledCallIdProvider = StateProvider<String?>((ref) => null);
