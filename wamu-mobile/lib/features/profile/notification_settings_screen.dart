import 'dart:async';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/notifications/bundled_sounds.dart';
import '../../core/notifications/notification_sound_service.dart';
import '../../core/theme/app_theme.dart';
import '../../core/theme/notification_settings_provider.dart';

/// You → Notifications — alerts, sounds, and local audio import.
class NotificationSettingsScreen extends ConsumerWidget {
  const NotificationSettingsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final s = ref.watch(notificationSettingsProvider);
    final n = ref.read(notificationSettingsProvider.notifier);
    final sounds = ref.read(notificationSoundServiceProvider);
    final dark = Theme.of(context).brightness == Brightness.dark;

    return Scaffold(
      appBar: AppBar(title: const Text('Notifications')),
      body: ListView(
        children: [
          ListTile(
            leading: Icon(Icons.inbox_outlined, color: AppTheme.accentGreen),
            title: const Text('Notification inbox'),
            subtitle: const Text('Orders, payments, and system alerts'),
            trailing: Icon(
              Icons.chevron_right,
              color: dark ? AppTheme.messengerMuted : const Color(0xFF667781),
            ),
            onTap: () => context.push('/notifications'),
          ),
          const Divider(height: 1),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
            child: Text(
              'Messages',
              style: Theme.of(context).textTheme.titleSmall?.copyWith(
                    color: AppTheme.accentGreen,
                    fontWeight: FontWeight.w700,
                  ),
            ),
          ),
          SwitchListTile(
            title: const Text('Message notifications'),
            subtitle: const Text('Direct chats'),
            value: s.messageAlerts,
            activeThumbColor: Colors.black,
            activeTrackColor: AppTheme.accentGreen,
            onChanged: (v) => n.set(messageAlerts: v),
          ),
          SwitchListTile(
            title: const Text('Group notifications'),
            subtitle: const Text('Communities and group chats'),
            value: s.groupAlerts,
            activeThumbColor: Colors.black,
            activeTrackColor: AppTheme.accentGreen,
            onChanged: (v) => n.set(groupAlerts: v),
          ),
          SwitchListTile(
            title: const Text('Show preview'),
            subtitle: const Text('Name and message text on lock screen'),
            value: s.showPreview,
            activeThumbColor: Colors.black,
            activeTrackColor: AppTheme.accentGreen,
            onChanged: (v) => n.set(showPreview: v),
          ),
          const Divider(height: 24),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
            child: Text(
              'Calls',
              style: Theme.of(context).textTheme.titleSmall?.copyWith(
                    color: AppTheme.accentGreen,
                    fontWeight: FontWeight.w700,
                  ),
            ),
          ),
          SwitchListTile(
            title: const Text('Call notifications'),
            subtitle: const Text('Incoming voice and video rings'),
            value: s.callAlerts,
            activeThumbColor: Colors.black,
            activeTrackColor: AppTheme.accentGreen,
            onChanged: (v) => n.set(callAlerts: v),
          ),
          const Divider(height: 24),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
            child: Text(
              'Sounds',
              style: Theme.of(context).textTheme.titleSmall?.copyWith(
                    color: AppTheme.accentGreen,
                    fontWeight: FontWeight.w700,
                  ),
            ),
          ),
          SwitchListTile(
            title: const Text('Enable notification sounds'),
            subtitle: const Text('Play audio when a new alert arrives'),
            value: s.soundsEnabled,
            activeThumbColor: Colors.black,
            activeTrackColor: AppTheme.accentGreen,
            onChanged: (v) {
              n.set(soundsEnabled: v);
              if (v) {
                unawaited(sounds.play(s.copyWith(soundsEnabled: true)));
              }
            },
          ),
          if (s.soundsEnabled) ...[
            for (final tone in BundledSounds.all)
              RadioListTile<String>(
                title: Text(tone.label),
                value: tone.id,
                groupValue: s.soundId,
                activeColor: AppTheme.accentGreen,
                secondary: IconButton(
                  tooltip: 'Preview',
                  icon: const Icon(Icons.play_arrow_rounded),
                  onPressed: () => sounds.previewBundled(tone.id),
                ),
                onChanged: (v) {
                  if (v == null) return;
                  n.set(soundId: v);
                  unawaited(sounds.previewBundled(v));
                },
              ),
            RadioListTile<String>(
              title: const Text('My audio'),
              subtitle: Text(
                (s.customSoundPath ?? '').isEmpty
                    ? 'Import MP3, WAV, or AAC from this phone'
                    : s.customSoundPath!.split('/').last,
              ),
              value: BundledSounds.customId,
              groupValue: s.soundId,
              activeColor: AppTheme.accentGreen,
              secondary: IconButton(
                tooltip: 'Preview',
                icon: const Icon(Icons.play_arrow_rounded),
                onPressed: (s.customSoundPath ?? '').isEmpty
                    ? null
                    : () => sounds.previewFile(s.customSoundPath!),
              ),
              onChanged: (s.customSoundPath ?? '').isEmpty
                  ? null
                  : (v) {
                      if (v != null) n.set(soundId: v);
                    },
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
              child: OutlinedButton.icon(
                onPressed: () => _importLocal(context, ref),
                icon: const Icon(Icons.folder_open_outlined),
                label: const Text('Import from this device'),
              ),
            ),
          ],
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
            child: Text(
              'Background push is data-only (“New message”) — never your chat text. '
              'In-app sounds play while Wamu is open. Custom files are copied into '
              'the app (max 2 MB) so the choice survives restarts.',
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _importLocal(BuildContext context, WidgetRef ref) async {
    if (kIsWeb) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Import custom sounds in the Android app')),
      );
      return;
    }
    try {
      final picked = await FilePicker.platform.pickFiles(
        type: FileType.custom,
        allowedExtensions: const ['mp3', 'wav', 'aac', 'm4a', 'ogg'],
        withData: true,
      );
      if (picked == null || picked.files.isEmpty) return;
      final file = picked.files.single;
      final bytes = file.bytes;
      if (bytes == null || bytes.isEmpty) {
        if (context.mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Could not read that audio file')),
          );
        }
        return;
      }
      final path = await ref.read(notificationSoundServiceProvider).persistImported(
            bytes: bytes,
            originalName: file.name,
          );
      await ref.read(notificationSettingsProvider.notifier).set(
            soundId: BundledSounds.customId,
            customSoundPath: path,
          );
      await ref.read(notificationSoundServiceProvider).previewFile(path);
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Custom sound saved')),
        );
      }
    } on FormatException catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(e.message)));
      }
    } catch (_) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Could not import audio')),
        );
      }
    }
  }
}
