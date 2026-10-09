import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../features/auth/auth_provider.dart';
import 'push_bootstrap.dart';

/// Keeps FCM token registration in sync with auth for the app lifetime.
final pushRegistrationProvider = Provider<PushBootstrap>((ref) {
  final bootstrap = PushBootstrap(ref);
  ref.onDispose(bootstrap.dispose);

  ref.listen<AuthState>(authProvider, (prev, next) {
    if (next.status == AuthStatus.authenticated ||
        next.status == AuthStatus.needsProfile) {
      bootstrap.startTokenRefreshListener();
      unawaited(bootstrap.syncToken());
    } else if (next.status == AuthStatus.unauthenticated &&
        prev?.status != AuthStatus.unauthenticated &&
        prev?.status != AuthStatus.unknown) {
      unawaited(bootstrap.unregisterCurrent());
    }
  });

  // Cold start: auth may already be authenticated after bootstrap.
  final current = ref.read(authProvider);
  if (current.status == AuthStatus.authenticated ||
      current.status == AuthStatus.needsProfile) {
    bootstrap.startTokenRefreshListener();
    unawaited(bootstrap.syncToken());
  }

  return bootstrap;
});
