import 'dart:io';

import 'package:dio/dio.dart';
import 'package:path_provider/path_provider.dart';
import 'package:video_player/video_player.dart';

import '../../core/network/dio_http_adapter.dart';

/// ExoPlayer does its own DNS. On networks that NXDOMAIN Railway, network
/// playback fails even though Dio (with our HttpOverrides) can download the file.
bool shouldPrefetchDiscoverVideo(Uri uri) {
  final host = uri.host.toLowerCase();
  return host.endsWith('railway.app') ||
      host.endsWith('wamu.ug') ||
      host == 'wamu.ug';
}

Future<File?> _prefetchDiscoverVideo({
  required String url,
  required String videoId,
}) async {
  final uri = Uri.tryParse(url);
  if (uri == null || !uri.hasScheme) return null;

  final dir = await getTemporaryDirectory();
  final cacheDir = Directory('${dir.path}/wamu_discover_videos');
  if (!await cacheDir.exists()) {
    await cacheDir.create(recursive: true);
  }
  final safeId = videoId.replaceAll(RegExp(r'[^a-zA-Z0-9_-]'), '');
  final file = File('${cacheDir.path}/$safeId.mp4');
  if (await file.exists()) {
    final len = await file.length();
    if (len > 1024) return file;
  }

  final dio = Dio(
    BaseOptions(
      connectTimeout: const Duration(seconds: 45),
      receiveTimeout: const Duration(minutes: 3),
      sendTimeout: const Duration(seconds: 45),
      headers: const {
        'Accept': '*/*',
        'Accept-Encoding': 'identity',
      },
    ),
  );
  configureWamuDioAdapter(dio);

  final tmp = File('${file.path}.part');
  if (await tmp.exists()) {
    await tmp.delete();
  }

  try {
    await dio.download(
      url,
      tmp.path,
      options: Options(
        followRedirects: true,
        validateStatus: (c) => c != null && c >= 200 && c < 400,
      ),
    );
    final len = await tmp.length();
    if (len < 1024) {
      await tmp.delete();
      return null;
    }
    if (await file.exists()) await file.delete();
    await tmp.rename(file.path);
    return file;
  } catch (_) {
    if (await tmp.exists()) {
      try {
        await tmp.delete();
      } catch (_) {}
    }
    rethrow;
  } finally {
    dio.close(force: true);
  }
}

Future<VideoPlayerController?> openCachedDiscoverVideo({
  required String url,
  required String videoId,
}) async {
  final file = await _prefetchDiscoverVideo(url: url, videoId: videoId);
  if (file == null) return null;
  return VideoPlayerController.file(
    file,
    videoPlayerOptions: VideoPlayerOptions(mixWithOthers: true),
  );
}
