import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/theme/app_theme.dart';
import '../../core/theme/appearance_provider.dart';

/// Chat wallpaper — style from Appearance settings (Phase E).
class ChatWallpaper extends ConsumerWidget {
  const ChatWallpaper({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final id = ref.watch(appearanceProvider).wallpaperId;
    final light = Theme.of(context).brightness == Brightness.light;
    final bg = switch (id) {
      'lake' => light ? const Color(0xFFD6E8F5) : const Color(0xFF0A1628),
      'market' => light ? const Color(0xFFF3E6D8) : const Color(0xFF1A140E),
      'day' => const Color(0xFFE8F0E9),
      'plain' => light ? const Color(0xFFECE5DD) : AppTheme.messengerBg,
      _ => light ? const Color(0xFFDCE8E0) : const Color(0xFF0E1A14),
    };
    return Stack(
      fit: StackFit.expand,
      children: [
        ColoredBox(color: bg),
        if (id != 'plain')
          Positioned.fill(
            child: CustomPaint(painter: _WallpaperPainter(id, light: light)),
          ),
        child,
      ],
    );
  }
}

class _WallpaperPainter extends CustomPainter {
  const _WallpaperPainter(this.id, {required this.light});

  final String id;
  final bool light;

  @override
  void paint(Canvas canvas, Size size) {
    if (id == 'lake') {
      _paintLake(canvas, size);
    } else if (id == 'market') {
      _paintMarket(canvas, size);
    } else if (id == 'day') {
      _paintDay(canvas, size);
    } else {
      _paintCrest(canvas, size);
    }
  }

  void _paintDay(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = AppTheme.primaryGreen.withValues(alpha: light ? 0.06 : 0.05)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.1;
    for (var i = 0; i < 12; i++) {
      canvas.drawCircle(
        Offset(size.width * 0.2 + i * 28, size.height * 0.15 + (i % 3) * 40),
        10 + (i % 4) * 3.0,
        paint,
      );
    }
  }

  void _paintCrest(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = AppTheme.accentGreen.withValues(alpha: light ? 0.08 : 0.045)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.2;
    final fill = Paint()
      ..color = (light ? const Color(0xFFB8D4C4) : const Color(0xFF1A2E24))
          .withValues(alpha: light ? 0.25 : 0.35)
      ..style = PaintingStyle.fill;
    const step = 72.0;
    for (var y = -20.0; y < size.height + 40; y += step) {
      for (var x = -20.0; x < size.width + 40; x += step) {
        final ox = ((y ~/ step) % 2 == 0) ? 0.0 : step / 2;
        _drawCrest(canvas, Offset(x + ox, y), 18, paint, fill);
      }
    }
  }

  void _paintLake(Canvas canvas, Size size) {
    final wave = Paint()
      ..color = const Color(0xFF3D7EA6).withValues(alpha: light ? 0.12 : 0.07)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.4;
    for (var i = 0; i < 18; i++) {
      final y = size.height * 0.35 + i * 28.0;
      final path = Path();
      for (var x = 0.0; x <= size.width; x += 12) {
        final yy = y + math.sin((x / 40) + i) * 6;
        if (x == 0) {
          path.moveTo(x, yy);
        } else {
          path.lineTo(x, yy);
        }
      }
      canvas.drawPath(path, wave);
    }
  }

  void _paintMarket(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = const Color(0xFFC45C26).withValues(alpha: light ? 0.1 : 0.06)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.1;
    const step = 40.0;
    for (var y = 0.0; y < size.height; y += step) {
      for (var x = 0.0; x < size.width; x += step) {
        canvas.drawCircle(Offset(x + 8, y + 8), 3.5, paint);
        canvas.drawRect(Rect.fromLTWH(x + 18, y + 18, 10, 10), paint);
      }
    }
  }

  void _drawCrest(Canvas canvas, Offset c, double r, Paint stroke, Paint fill) {
    final path = Path();
    for (var i = 0; i < 5; i++) {
      final angle = -math.pi / 2 + i * 2 * math.pi / 5;
      final p = Offset(c.dx + math.cos(angle) * r, c.dy + math.sin(angle) * r);
      if (i == 0) {
        path.moveTo(p.dx, p.dy);
      } else {
        path.lineTo(p.dx, p.dy);
      }
    }
    path.close();
    canvas.drawPath(path, fill);
    canvas.drawPath(path, stroke);
    canvas.drawCircle(c, r * 0.28, stroke);
  }

  @override
  bool shouldRepaint(covariant _WallpaperPainter oldDelegate) =>
      oldDelegate.id != id || oldDelegate.light != light;
}
