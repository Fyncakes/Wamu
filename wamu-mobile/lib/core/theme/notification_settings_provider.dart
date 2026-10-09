import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../notifications/bundled_sounds.dart';
import '../storage/secure_storage.dart';

/// Local notification preference toggles (Phase E / You → Notifications).
class NotificationSettings {
  const NotificationSettings({
    this.messageAlerts = true,
    this.groupAlerts = true,
    this.callAlerts = true,
    this.showPreview = true,
    this.soundsEnabled = true,
    this.soundId = BundledSounds.defaultId,
    this.customSoundPath,
  });

  final bool messageAlerts;
  final bool groupAlerts;
  final bool callAlerts;
  final bool showPreview;
  final bool soundsEnabled;
  final String soundId;
  final String? customSoundPath;

  NotificationSettings copyWith({
    bool? messageAlerts,
    bool? groupAlerts,
    bool? callAlerts,
    bool? showPreview,
    bool? soundsEnabled,
    String? soundId,
    String? customSoundPath,
    bool clearCustomPath = false,
  }) {
    return NotificationSettings(
      messageAlerts: messageAlerts ?? this.messageAlerts,
      groupAlerts: groupAlerts ?? this.groupAlerts,
      callAlerts: callAlerts ?? this.callAlerts,
      showPreview: showPreview ?? this.showPreview,
      soundsEnabled: soundsEnabled ?? this.soundsEnabled,
      soundId: soundId ?? this.soundId,
      customSoundPath:
          clearCustomPath ? null : (customSoundPath ?? this.customSoundPath),
    );
  }
}

class NotificationSettingsNotifier extends StateNotifier<NotificationSettings> {
  NotificationSettingsNotifier(this._storage) : super(const NotificationSettings()) {
    _restore();
  }

  final SecureStorageService _storage;

  Future<void> _restore() async {
    final m = await _storage.read('wamu_notif_messages');
    final g = await _storage.read('wamu_notif_groups');
    final c = await _storage.read('wamu_notif_calls');
    final p = await _storage.read('wamu_notif_preview');
    final sounds = await _storage.read('wamu_notif_sounds');
    final soundId = await _storage.read('wamu_notif_sound_id');
    final custom = await _storage.read('wamu_notif_custom_path');
    state = NotificationSettings(
      messageAlerts: m != '0',
      groupAlerts: g != '0',
      callAlerts: c != '0',
      showPreview: p != '0',
      soundsEnabled: sounds != '0',
      soundId: (soundId == null || soundId.isEmpty)
          ? BundledSounds.defaultId
          : soundId,
      customSoundPath: (custom == null || custom.isEmpty) ? null : custom,
    );
  }

  Future<void> set({
    bool? messageAlerts,
    bool? groupAlerts,
    bool? callAlerts,
    bool? showPreview,
    bool? soundsEnabled,
    String? soundId,
    String? customSoundPath,
    bool clearCustomPath = false,
  }) async {
    state = state.copyWith(
      messageAlerts: messageAlerts,
      groupAlerts: groupAlerts,
      callAlerts: callAlerts,
      showPreview: showPreview,
      soundsEnabled: soundsEnabled,
      soundId: soundId,
      customSoundPath: customSoundPath,
      clearCustomPath: clearCustomPath,
    );
    if (messageAlerts != null) {
      await _storage.write('wamu_notif_messages', messageAlerts ? '1' : '0');
    }
    if (groupAlerts != null) {
      await _storage.write('wamu_notif_groups', groupAlerts ? '1' : '0');
    }
    if (callAlerts != null) {
      await _storage.write('wamu_notif_calls', callAlerts ? '1' : '0');
    }
    if (showPreview != null) {
      await _storage.write('wamu_notif_preview', showPreview ? '1' : '0');
    }
    if (soundsEnabled != null) {
      await _storage.write('wamu_notif_sounds', soundsEnabled ? '1' : '0');
    }
    if (soundId != null) {
      await _storage.write('wamu_notif_sound_id', soundId);
    }
    if (clearCustomPath) {
      await _storage.delete('wamu_notif_custom_path');
    } else if (customSoundPath != null) {
      await _storage.write('wamu_notif_custom_path', customSoundPath);
    }
  }
}

final notificationSettingsProvider =
    StateNotifierProvider<NotificationSettingsNotifier, NotificationSettings>((ref) {
  return NotificationSettingsNotifier(ref.watch(secureStorageProvider));
});
