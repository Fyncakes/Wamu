import 'package:flutter_test/flutter_test.dart';
import 'package:wamu_mobile/core/notifications/bundled_sounds.dart';
import 'package:wamu_mobile/core/theme/notification_settings_provider.dart';

void main() {
  test('bundled catalog has unique ids and a default', () {
    expect(BundledSounds.all, isNotEmpty);
    expect(BundledSounds.isBundledId(BundledSounds.defaultId), isTrue);
    expect(BundledSounds.isBundledId(BundledSounds.customId), isFalse);
    final ids = BundledSounds.all.map((s) => s.id).toSet();
    expect(ids.length, BundledSounds.all.length);
    expect(BundledSounds.byId('chime')?.assetPath, contains('wamu_chime.wav'));
    expect(BundledSounds.ringtoneAsset, contains('wamu_ringtone.wav'));
  });

  test('sound prefs copyWith preserves and clears custom path', () {
    const base = NotificationSettings(
      soundsEnabled: true,
      soundId: 'ping',
      customSoundPath: '/tmp/tone.mp3',
    );
    expect(base.copyWith(soundsEnabled: false).soundsEnabled, isFalse);
    expect(base.copyWith(soundId: BundledSounds.customId).customSoundPath, '/tmp/tone.mp3');
    expect(base.copyWith(clearCustomPath: true).customSoundPath, isNull);
  });
}
