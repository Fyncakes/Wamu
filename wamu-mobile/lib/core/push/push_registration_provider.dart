import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../features/auth/auth_provider.dart';
import '../routing/app_router.dart';
import 'chat_focus.dart';
import 'push_bootstrap.dart';

/// Keeps FCM token registration in sync with auth for the app lifetime.
final pushRegistrationProvider = Provider<PushBootstrap>((ref) {
  final bootstrap = PushBootstrap(ref);
  ref.onDispose(bootstrap.dispose);

  void openPendingChat() {
    final id = ref.read(pendingChatOpenProvider);
    if (id == null || id.isEmpty) return;
    final auth = ref.read(authProvider).status;
    if (auth != AuthStatus.authenticated && auth != AuthStatus.needsProfile) return;
    Future.microtask(() {
      final still = ref.read(pendingChatOpenProvider);
      if (still == null || still.isEmpty) return;
      final router = ref.read(appRouterProvider);
      final path = router.routeInformationProvider.value.uri.path;
      if (path != '/chat/$still') {
        router.go('/chat/$still');
      }
      ref.read(pendingChatOpenProvider.notifier).state = null;
    });
  }

  ref.listen<String?>(pendingChatOpenProvider, (prev, next) {
    if (next != null && next.isNotEmpty) openPendingChat();
  });

  ref.listen<AuthState>(authProvider, (prev, next) {
    if (next.status == AuthStatus.authenticated ||
        next.status == AuthStatus.needsProfile) {
      bootstrap.startTokenRefreshListener();
      unawaited(bootstrap.syncToken());
      openPendingChat();
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
