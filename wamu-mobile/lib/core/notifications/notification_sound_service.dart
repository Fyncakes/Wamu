import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../theme/notification_settings_provider.dart';
import 'bundled_sounds.dart';
import 'sound_file_store_stub.dart'
    if (dart.library.io) 'sound_file_store_io.dart' as disk;

/// Plays the user-selected notification sound (bundled asset or imported file).
class NotificationSoundService {
  NotificationSoundService({AudioPlayer? player})
      : _player = player ?? AudioPlayer();

  final AudioPlayer _player;
  final AudioPlayer _ringPlayer = AudioPlayer();
  bool _ready = false;
  bool _ringReady = false;

  Future<void> _ensurePlayer() async {
    if (_ready) return;
    // lowLatency + AssetSource is silent on Android (audioplayers #1176).
    await _player.setPlayerMode(PlayerMode.mediaPlayer);
    await _player.setReleaseMode(ReleaseMode.stop);
    await _player.setVolume(1);
    await _player.setAudioContext(
      AudioContext(
        android: const AudioContextAndroid(
          contentType: AndroidContentType.sonification,
          usageType: AndroidUsageType.notification,
          audioFocus: AndroidAudioFocus.gainTransientMayDuck,
        ),
        iOS: AudioContextIOS(
          category: AVAudioSessionCategory.playback,
          options: const {AVAudioSessionOptions.mixWithOthers},
        ),
      ),
    );
    _ready = true;
  }

  Future<void> play(NotificationSettings settings) async {
    if (!settings.soundsEnabled) return;
    if (settings.soundId == BundledSounds.customId &&
        (settings.customSoundPath ?? '').isNotEmpty) {
      final path = settings.customSoundPath!;
      if (await disk.notificationSoundFileExists(path)) {
        await previewFile(path);
        return;
      }
    }
    final id = BundledSounds.isBundledId(settings.soundId)
        ? settings.soundId
        : BundledSounds.defaultId;
    await previewBundled(id);
  }

  Future<void> previewBundled(String id) async {
    final sound =
        BundledSounds.byId(id) ?? BundledSounds.byId(BundledSounds.defaultId)!;
    await _play(AssetSource(sound.assetPath));
  }

  Future<void> previewFile(String path) async {
    await _play(DeviceFileSource(path));
  }

  Future<void> _play(Source source) async {
    try {
      await _ensurePlayer();
      await _player.stop();
      await _player.play(source);
    } catch (e, st) {
      debugPrint('Wamu notification sound failed: $e\n$st');
    }
  }

  Future<void> startRingtone() async {
    try {
      if (!_ringReady) {
        await _ringPlayer.setPlayerMode(PlayerMode.mediaPlayer);
        await _ringPlayer.setReleaseMode(ReleaseMode.loop);
        await _ringPlayer.setVolume(1);
        await _ringPlayer.setAudioContext(
          AudioContext(
            android: const AudioContextAndroid(
              contentType: AndroidContentType.sonification,
              usageType: AndroidUsageType.notificationRingtone,
              audioFocus: AndroidAudioFocus.gainTransient,
            ),
            iOS: AudioContextIOS(
              category: AVAudioSessionCategory.playback,
              options: const {AVAudioSessionOptions.duckOthers},
            ),
          ),
        );
        _ringReady = true;
      }
      await _ringPlayer.stop();
      await _ringPlayer.play(AssetSource(BundledSounds.ringtoneAsset));
    } catch (e, st) {
      debugPrint('Wamu ringtone failed: $e\n$st');
    }
  }

  Future<void> stopRingtone() async {
    try {
      await _ringPlayer.stop();
    } catch (_) {}
  }

  Future<String> persistImported({
    required List<int> bytes,
    required String originalName,
  }) {
    return disk.persistNotificationSound(bytes: bytes, originalName: originalName);
  }

  Future<void> dispose() async {
    await stopRingtone();
    await _ringPlayer.dispose();
    await _player.dispose();
  }
}

final notificationSoundServiceProvider = Provider<NotificationSoundService>((ref) {
  final svc = NotificationSoundService();
  ref.onDispose(svc.dispose);
  return svc;
});
