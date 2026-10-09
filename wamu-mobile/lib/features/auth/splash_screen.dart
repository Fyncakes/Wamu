import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/config.dart';
import '../../core/theme/app_theme.dart';
import '../../shared/widgets/wamu_logo.dart';

/// Branded splash while auth state bootstraps from secure storage.
class SplashScreen extends ConsumerWidget {
  const SplashScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Scaffold(
      body: Container(
        width: double.infinity,
        decoration: const BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [Color(0xFF0B141A), Color(0xFF0D3B2E), Color(0xFF0B141A)],
          ),
        ),
        child: Center(
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              const WamuLogo(size: 108),
              const SizedBox(height: 22),
              Text(
                AppConfig.appName,
                style: AppTheme.brandHero.copyWith(fontSize: 44, color: Colors.white),
              ),
              const SizedBox(height: 10),
              Text(
                AppConfig.tagline,
                style: AppTheme.tagline.copyWith(color: AppTheme.messengerMuted, fontSize: 16),
              ),
              const SizedBox(height: 40),
              const SizedBox(
                width: 28,
                height: 28,
                child: CircularProgressIndicator(
                  strokeWidth: 2.5,
                  color: AppTheme.accentGreen,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
