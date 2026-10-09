import 'package:flutter/material.dart';

/// Wamu brand mark from the Play Store icon.
class WamuLogo extends StatelessWidget {
  const WamuLogo({super.key, this.size = 72});

  final double size;

  static const assetPath = 'assets/branding/playstore.png';

  @override
  Widget build(BuildContext context) {
    final radius = BorderRadius.circular(size * 0.22);
    return Semantics(
      label: 'Wamu',
      child: Align(
        alignment: Alignment.center,
        child: SizedBox(
          width: size,
          height: size,
          child: DecoratedBox(
            decoration: BoxDecoration(
              borderRadius: radius,
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withValues(alpha: 0.32),
                  blurRadius: 16,
                  offset: const Offset(0, 6),
                ),
              ],
            ),
            child: ClipRRect(
              borderRadius: radius,
              child: Image.asset(
                assetPath,
                fit: BoxFit.cover,
                filterQuality: FilterQuality.high,
              ),
            ),
          ),
        ),
      ),
    );
  }
}
