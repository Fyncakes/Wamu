import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/theme/app_theme.dart';
import '../../core/theme/network_type_provider.dart';
import '../../core/theme/storage_settings_provider.dart';

/// Storage & data — auto-download rules for MTN/Airtel (Phase E).
class StorageDataScreen extends ConsumerWidget {
  const StorageDataScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final s = ref.watch(storageSettingsProvider);
    final n = ref.read(storageSettingsProvider.notifier);
    final kind = ref.watch(networkKindProvider);
    final linkLabel = switch (kind) {
      WamuNetworkKind.wifi => 'On Wi‑Fi now',
      WamuNetworkKind.mobile => 'On mobile data now',
      WamuNetworkKind.none => 'Offline',
    };

    return Scaffold(
      appBar: AppBar(title: const Text('Storage and data')),
      body: ListView(
        children: [
          ListTile(
            leading: Icon(
              kind == WamuNetworkKind.mobile
                  ? Icons.signal_cellular_alt
                  : kind == WamuNetworkKind.none
                      ? Icons.cloud_off_outlined
                      : Icons.wifi,
              color: AppTheme.accentGreen,
            ),
            title: Text(linkLabel),
            subtitle: const Text(
              'Photo auto-download follows this link type (plus Data saver).',
            ),
          ),
          const ListTile(
            title: Text('Media auto-download'),
            subtitle: Text(
              'Built for Uganda data — photos off on mobile by default; voice stays on so chats keep flowing.',
            ),
          ),
          const Divider(),
          const Padding(
            padding: EdgeInsets.fromLTRB(16, 12, 16, 4),
            child: Text('Photos', style: TextStyle(fontWeight: FontWeight.w700)),
          ),
          SwitchListTile(
            secondary: const Icon(Icons.wifi, color: AppTheme.accentGreen),
            title: const Text('When using Wi‑Fi'),
            value: s.autoPhotosWifi,
            activeThumbColor: Colors.black,
            activeTrackColor: AppTheme.accentGreen,
            onChanged: (v) => n.set(autoPhotosWifi: v),
          ),
          SwitchListTile(
            secondary: const Icon(Icons.signal_cellular_alt, color: AppTheme.accentGreen),
            title: const Text('When using mobile data'),
            subtitle: const Text('Keep off to save MTN/Airtel bundles'),
            value: s.autoPhotosMobile,
            activeThumbColor: Colors.black,
            activeTrackColor: AppTheme.accentGreen,
            onChanged: (v) => n.set(autoPhotosMobile: v),
          ),
          const Divider(),
          const Padding(
            padding: EdgeInsets.fromLTRB(16, 12, 16, 4),
            child: Text('Voice notes', style: TextStyle(fontWeight: FontWeight.w700)),
          ),
          SwitchListTile(
            secondary: const Icon(Icons.wifi, color: AppTheme.accentGreen),
            title: const Text('When using Wi‑Fi'),
            value: s.autoVoiceWifi,
            activeThumbColor: Colors.black,
            activeTrackColor: AppTheme.accentGreen,
            onChanged: (v) => n.set(autoVoiceWifi: v),
          ),
          SwitchListTile(
            secondary: const Icon(Icons.signal_cellular_alt, color: AppTheme.accentGreen),
            title: const Text('When using mobile data'),
            value: s.autoVoiceMobile,
            activeThumbColor: Colors.black,
            activeTrackColor: AppTheme.accentGreen,
            onChanged: (v) => n.set(autoVoiceMobile: v),
          ),
          const Divider(),
          ListTile(
            leading: const Icon(Icons.data_saver_on, color: AppTheme.accentGreen),
            title: const Text('Data saver'),
            subtitle: const Text(
              'On You tab — shrinks outgoing photos for MTN/Airtel bundles',
            ),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => context.go('/settings'),
          ),
        ],
      ),
    );
  }
}
