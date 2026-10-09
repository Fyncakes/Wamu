/// Bundled notification / ringtone assets (see assets/sounds/).
class BundledSound {
  const BundledSound({
    required this.id,
    required this.label,
    required this.assetPath,
  });

  final String id;
  final String label;
  /// Path relative to Flutter assets (no `assets/` prefix for [AssetSource]).
  final String assetPath;
}

class BundledSounds {
  BundledSounds._();

  static const customId = 'custom';
  static const defaultId = 'chime';

  static const all = <BundledSound>[
    BundledSound(
      id: 'chime',
      label: 'Wamu chime',
      assetPath: 'sounds/wamu_chime.wav',
    ),
    BundledSound(
      id: 'ping',
      label: 'Ping',
      assetPath: 'sounds/wamu_ping.wav',
    ),
    BundledSound(
      id: 'drop',
      label: 'Drop',
      assetPath: 'sounds/wamu_drop.wav',
    ),
    BundledSound(
      id: 'pulse',
      label: 'Pulse',
      assetPath: 'sounds/wamu_pulse.wav',
    ),
    BundledSound(
      id: 'bell',
      label: 'Bell',
      assetPath: 'sounds/wamu_bell.wav',
    ),
  ];

  static const ringtoneAsset = 'sounds/wamu_ringtone.wav';

  static BundledSound? byId(String id) {
    for (final s in all) {
      if (s.id == id) return s;
    }
    return null;
  }

  static bool isBundledId(String id) => byId(id) != null;
}
