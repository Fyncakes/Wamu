import 'dart:io';

import 'package:video_player/video_player.dart';

/// Read clip length before upload so merchants get a fast client-side error.
Future<int?> probeLocalVideoDurationSeconds(String path) async {
  if (path.isEmpty) return null;
  VideoPlayerController? c;
  try {
    c = VideoPlayerController.file(File(path));
    await c.initialize().timeout(const Duration(seconds: 20));
    final ms = c.value.duration.inMilliseconds;
    if (ms <= 0) return null;
    return (ms / 1000).round();
  } catch (_) {
    return null;
  } finally {
    await c?.dispose();
  }
}
