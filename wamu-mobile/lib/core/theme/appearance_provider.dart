import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../storage/secure_storage.dart';

/// Theme + chat wallpaper prefs (Phase E).
class AppearanceSettings {
  const AppearanceSettings({
    this.themeMode = ThemeMode.dark,
    this.wallpaperId = 'crest',
  });

  final ThemeMode themeMode;
  final String wallpaperId;

  AppearanceSettings copyWith({ThemeMode? themeMode, String? wallpaperId}) {
    return AppearanceSettings(
      themeMode: themeMode ?? this.themeMode,
      wallpaperId: wallpaperId ?? this.wallpaperId,
    );
  }
}

class AppearanceNotifier extends StateNotifier<AppearanceSettings> {
  AppearanceNotifier(this._storage) : super(const AppearanceSettings()) {
    _restore();
  }

  final SecureStorageService _storage;
  static const _themeKey = 'wamu_theme_mode';
  static const _wallpaperKey = 'wamu_chat_wallpaper';

  Future<void> _restore() async {
    final themeRaw = await _storage.read(_themeKey);
    final wallRaw = await _storage.read(_wallpaperKey);
    ThemeMode mode = ThemeMode.dark;
    if (themeRaw == 'light') mode = ThemeMode.light;
    if (themeRaw == 'system') mode = ThemeMode.system;
    state = AppearanceSettings(
      themeMode: mode,
      wallpaperId: (wallRaw == null || wallRaw.isEmpty) ? 'crest' : wallRaw,
    );
  }

  Future<void> setThemeMode(ThemeMode mode) async {
    state = state.copyWith(themeMode: mode);
    final value = switch (mode) {
      ThemeMode.light => 'light',
      ThemeMode.system => 'system',
      ThemeMode.dark => 'dark',
    };
    await _storage.write(_themeKey, value);
  }

  Future<void> setWallpaper(String id) async {
    state = state.copyWith(wallpaperId: id);
    await _storage.write(_wallpaperKey, id);
  }
}

final appearanceProvider =
    StateNotifierProvider<AppearanceNotifier, AppearanceSettings>((ref) {
  return AppearanceNotifier(ref.watch(secureStorageProvider));
});

/// Wallpaper catalog for picker + ChatWallpaper.
class WallpaperOption {
  const WallpaperOption({
    required this.id,
    required this.label,
    required this.preview,
  });

  final String id;
  final String label;
  final Color preview;
}

const wallpaperOptions = [
  WallpaperOption(id: 'crest', label: 'Crest hills', preview: Color(0xFF0E1A14)),
  WallpaperOption(id: 'lake', label: 'Lakeside dusk', preview: Color(0xFF0A1628)),
  WallpaperOption(id: 'market', label: 'Market warm', preview: Color(0xFF1A140E)),
  WallpaperOption(id: 'day', label: 'Daylight', preview: Color(0xFFE8F0E9)),
  WallpaperOption(id: 'plain', label: 'Plain', preview: Color(0xFFECE5DD)),
];
