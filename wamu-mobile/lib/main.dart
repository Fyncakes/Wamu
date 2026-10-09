import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'core/push/push_registration_provider.dart';
import 'core/routing/app_router.dart';
import 'core/server_config.dart';
import 'core/storage/secure_storage.dart';
import 'core/theme/app_theme.dart';
import 'core/theme/appearance_provider.dart';
import 'features/auth/auth_provider.dart';
import 'features/chat/outbox_flush_provider.dart';

/// WAMU Uganda Super App entry point.
Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final storage = SecureStorageService();
  await ServerConfig.hydrate(storage);
  runApp(const ProviderScope(child: WamuApp()));
}

class WamuApp extends ConsumerWidget {
  const WamuApp({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    ref.watch(authProvider);
    ref.watch(serverConfigProvider);
    ref.watch(outboxFlushProvider);
    ref.watch(pushRegistrationProvider);
    final router = ref.watch(appRouterProvider);
    final appearance = ref.watch(appearanceProvider);

    return MaterialApp.router(
      title: 'WAMU',
      debugShowCheckedModeBanner: false,
      theme: AppTheme.messengerLightTheme,
      darkTheme: AppTheme.messengerDarkTheme,
      themeMode: appearance.themeMode,
      routerConfig: router,
    );
  }
}
