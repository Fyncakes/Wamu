import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/theme/app_theme.dart';
import '../../core/theme/appearance_provider.dart';

/// Appearance: visual dark/light theme cards + chat wallpaper.
class AppearanceScreen extends ConsumerWidget {
  const AppearanceScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final appearance = ref.watch(appearanceProvider);
    final notifier = ref.read(appearanceProvider.notifier);
    final isDarkChrome = Theme.of(context).brightness == Brightness.dark;

    return Scaffold(
      appBar: AppBar(title: const Text('Appearance')),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 32),
        children: [
          Text('App theme', style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 4),
          Text(
            'Pick dark or white — previews match the Chats look from modern messengers.',
            style: TextStyle(
              color: isDarkChrome ? AppTheme.messengerMuted : const Color(0xFF667781),
              fontSize: 13,
            ),
          ),
          const SizedBox(height: 14),
          Row(
            children: [
              Expanded(
                child: _ThemePreviewCard(
                  label: 'Dark',
                  asset: 'assets/themes/theme_preview_dark.png',
                  selected: appearance.themeMode == ThemeMode.dark,
                  onTap: () => notifier.setThemeMode(ThemeMode.dark),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: _ThemePreviewCard(
                  label: 'White',
                  asset: 'assets/themes/theme_preview_light.png',
                  selected: appearance.themeMode == ThemeMode.light,
                  onTap: () => notifier.setThemeMode(ThemeMode.light),
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          Material(
            color: isDarkChrome ? AppTheme.messengerElevated : const Color(0xFFF0F2F5),
            borderRadius: BorderRadius.circular(14),
            child: ListTile(
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
              leading: Icon(
                Icons.phone_android,
                color: appearance.themeMode == ThemeMode.system
                    ? AppTheme.accentGreen
                    : null,
              ),
              title: const Text('System default'),
              subtitle: const Text('Follow your phone light / dark setting'),
              trailing: appearance.themeMode == ThemeMode.system
                  ? const Icon(Icons.check_circle, color: AppTheme.accentGreen)
                  : null,
              onTap: () => notifier.setThemeMode(ThemeMode.system),
            ),
          ),
          const SizedBox(height: 28),
          Text('Chat wallpaper', style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 4),
          Text(
            'Own Uganda-inspired patterns — not WhatsApp clones.',
            style: TextStyle(
              color: isDarkChrome ? AppTheme.messengerMuted : const Color(0xFF667781),
              fontSize: 13,
            ),
          ),
          const SizedBox(height: 12),
          Wrap(
            spacing: 10,
            runSpacing: 10,
            children: wallpaperOptions.map((opt) {
              final selected = appearance.wallpaperId == opt.id;
              return InkWell(
                onTap: () => notifier.setWallpaper(opt.id),
                borderRadius: BorderRadius.circular(12),
                child: Container(
                  width: 96,
                  padding: const EdgeInsets.all(8),
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(
                      color: selected ? AppTheme.accentGreen : Colors.transparent,
                      width: 2,
                    ),
                  ),
                  child: Column(
                    children: [
                      Container(
                        height: 64,
                        decoration: BoxDecoration(
                          color: opt.preview,
                          borderRadius: BorderRadius.circular(10),
                        ),
                      ),
                      const SizedBox(height: 6),
                      Text(
                        opt.label,
                        textAlign: TextAlign.center,
                        style: TextStyle(
                          fontSize: 11,
                          fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
                          color: selected ? AppTheme.accentGreen : null,
                        ),
                      ),
                    ],
                  ),
                ),
              );
            }).toList(),
          ),
        ],
      ),
    );
  }
}

class _ThemePreviewCard extends StatelessWidget {
  const _ThemePreviewCard({
    required this.label,
    required this.asset,
    required this.selected,
    required this.onTap,
  });

  final String label;
  final String asset;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(16),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 180),
        padding: const EdgeInsets.all(6),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(16),
          border: Border.all(
            color: selected ? AppTheme.accentGreen : const Color(0xFF2A3942).withValues(alpha: 0.35),
            width: selected ? 2.5 : 1,
          ),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            ClipRRect(
              borderRadius: BorderRadius.circular(12),
              child: AspectRatio(
                aspectRatio: 3 / 4,
                                child: Image.asset(
                  asset,
                  fit: BoxFit.cover,
                  errorBuilder: (context, error, stackTrace) => ColoredBox(
                    color: label == 'Dark' ? AppTheme.messengerBg : Colors.white,
                    child: Icon(
                      label == 'Dark' ? Icons.dark_mode : Icons.light_mode,
                      color: AppTheme.accentGreen,
                      size: 40,
                    ),
                  ),
                ),
              ),
            ),
            const SizedBox(height: 8),
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                if (selected) ...[
                  const Icon(Icons.check_circle, size: 16, color: AppTheme.accentGreen),
                  const SizedBox(width: 4),
                ],
                Text(
                  label,
                  style: TextStyle(
                    fontWeight: FontWeight.w700,
                    color: selected ? AppTheme.accentGreen : null,
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
