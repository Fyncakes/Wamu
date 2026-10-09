import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../storage/secure_storage.dart';

/// Auto-download / data rules for Uganda networks (Phase E).
class StorageSettings {
  const StorageSettings({
    this.autoPhotosWifi = true,
    this.autoPhotosMobile = false,
    this.autoVoiceWifi = true,
    this.autoVoiceMobile = true,
  });

  final bool autoPhotosWifi;
  final bool autoPhotosMobile;
  final bool autoVoiceWifi;
  final bool autoVoiceMobile;

  StorageSettings copyWith({
    bool? autoPhotosWifi,
    bool? autoPhotosMobile,
    bool? autoVoiceWifi,
    bool? autoVoiceMobile,
  }) {
    return StorageSettings(
      autoPhotosWifi: autoPhotosWifi ?? this.autoPhotosWifi,
      autoPhotosMobile: autoPhotosMobile ?? this.autoPhotosMobile,
      autoVoiceWifi: autoVoiceWifi ?? this.autoVoiceWifi,
      autoVoiceMobile: autoVoiceMobile ?? this.autoVoiceMobile,
    );
  }
}

class StorageNotifier extends StateNotifier<StorageSettings> {
  StorageNotifier(this._storage) : super(const StorageSettings()) {
    _restore();
  }

  final SecureStorageService _storage;

  Future<void> _restore() async {
    final pW = await _storage.read('wamu_auto_photo_wifi');
    final pM = await _storage.read('wamu_auto_photo_mobile');
    final vW = await _storage.read('wamu_auto_voice_wifi');
    final vM = await _storage.read('wamu_auto_voice_mobile');
    state = StorageSettings(
      autoPhotosWifi: pW != '0',
      autoPhotosMobile: pM == '1',
      autoVoiceWifi: vW != '0',
      autoVoiceMobile: vM != '0',
    );
  }

  Future<void> set({
    bool? autoPhotosWifi,
    bool? autoPhotosMobile,
    bool? autoVoiceWifi,
    bool? autoVoiceMobile,
  }) async {
    state = state.copyWith(
      autoPhotosWifi: autoPhotosWifi,
      autoPhotosMobile: autoPhotosMobile,
      autoVoiceWifi: autoVoiceWifi,
      autoVoiceMobile: autoVoiceMobile,
    );
    if (autoPhotosWifi != null) {
      await _storage.write('wamu_auto_photo_wifi', autoPhotosWifi ? '1' : '0');
    }
    if (autoPhotosMobile != null) {
      await _storage.write('wamu_auto_photo_mobile', autoPhotosMobile ? '1' : '0');
    }
    if (autoVoiceWifi != null) {
      await _storage.write('wamu_auto_voice_wifi', autoVoiceWifi ? '1' : '0');
    }
    if (autoVoiceMobile != null) {
      await _storage.write('wamu_auto_voice_mobile', autoVoiceMobile ? '1' : '0');
    }
  }
}

final storageSettingsProvider =
    StateNotifierProvider<StorageNotifier, StorageSettings>((ref) {
  return StorageNotifier(ref.watch(secureStorageProvider));
});
