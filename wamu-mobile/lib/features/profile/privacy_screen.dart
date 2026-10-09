import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/theme/app_theme.dart';
import '../auth/auth_provider.dart';

/// Last seen / online / read receipts privacy (Phase E).
class PrivacyScreen extends ConsumerWidget {
  const PrivacyScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final user = ref.watch(authProvider).user;
    final showLast = user?.showLastSeen ?? true;
    final showOnline = user?.showOnline ?? true;
    final showReceipts = user?.showReadReceipts ?? true;

    return Scaffold(
      appBar: AppBar(title: const Text('Privacy')),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(0, 8, 0, 32),
        children: [
          SwitchListTile(
            secondary: const Icon(Icons.visibility_outlined, color: AppTheme.accentGreen),
            title: const Text('Last seen'),
            subtitle: const Text(
              'If off, you won’t share or see last seen',
            ),
            value: showLast,
            activeThumbColor: Colors.black,
            activeTrackColor: AppTheme.accentGreen,
            onChanged: (v) => ref.read(authProvider.notifier).updatePrivacy(showLastSeen: v),
          ),
          SwitchListTile(
            secondary: const Icon(Icons.circle, color: AppTheme.accentGreen, size: 18),
            title: const Text('Online status'),
            subtitle: const Text(
              'If off, you won’t share or see “online”',
            ),
            value: showOnline,
            activeThumbColor: Colors.black,
            activeTrackColor: AppTheme.accentGreen,
            onChanged: (v) => ref.read(authProvider.notifier).updatePrivacy(showOnline: v),
          ),
          SwitchListTile(
            secondary: const Icon(Icons.done_all, color: AppTheme.accentGreen),
            title: const Text('Read receipts'),
            subtitle: const Text(
              'If off, you won’t send or see blue ✓✓ in 1:1 chats (groups unchanged)',
            ),
            value: showReceipts,
            activeThumbColor: Colors.black,
            activeTrackColor: AppTheme.accentGreen,
            onChanged: (v) =>
                ref.read(authProvider.notifier).updatePrivacy(showReadReceipts: v),
          ),
          const Divider(),
          const ListTile(
            leading: Icon(Icons.lock_outline, color: AppTheme.messengerMuted),
            title: Text('Encryption'),
            subtitle: Text(
              'Messages travel over TLS today. Signal-protocol E2EE is planned — '
              'we will not invent our own crypto.',
            ),
          ),
        ],
      ),
    );
  }
}
