import 'dart:async';

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/theme/network_type_provider.dart';
import 'auth_provider.dart';

bool _isOnline(List<ConnectivityResult> results) {
  if (results.isEmpty) return false;
  return results.any((r) => r != ConnectivityResult.none);
}

/// When the phone regains a network, refresh the cached session without OTP.
final authReconnectProvider = Provider<void>((ref) {
  var wasOffline = false;

  ref.listen<AsyncValue<List<ConnectivityResult>>>(connectivityListProvider, (prev, next) {
    final results = next.valueOrNull;
    if (results == null) return;
    final online = _isOnline(results);
    if (!online) {
      wasOffline = true;
      return;
    }
    final cameBack = wasOffline ||
        (prev?.valueOrNull != null && !_isOnline(prev!.valueOrNull!));
    wasOffline = false;
    if (!cameBack && prev != null) return;
    unawaited(ref.read(authProvider.notifier).syncAfterReconnect());
  });
});
