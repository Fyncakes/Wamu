import 'server_config.dart';

/// Point media at the linked API origin (LAN / Cloudflare tunnel).
///
/// DB / API rows often store relative `/media-files/...` paths or absolute URLs
/// from `PUBLIC_MEDIA_BASE` (localhost, a LAN IP, or a dead tunnel). On a phone
/// those hosts are unreachable — rewrite them to [ServerConfig.mediaOrigin].
String? resolveMediaUrl(String? url) {
  if (url == null || url.isEmpty) return url;

  final origin = Uri.tryParse(ServerConfig.mediaOrigin);
  if (origin == null || origin.host.isEmpty) return url;

  final trimmed = url.trim();

  // Relative /media-files/... paths
  if (!trimmed.contains('://')) {
    if (trimmed.contains('media-files') || trimmed.startsWith('/media')) {
      final path = trimmed.startsWith('/') ? trimmed : '/$trimmed';
      return '${_originRoot(origin)}$path';
    }
    return url;
  }

  final parsed = Uri.tryParse(trimmed);
  if (parsed == null || !parsed.hasScheme || parsed.host.isEmpty) return url;

  final isMediaPath =
      parsed.path.contains('/media-files') || parsed.path.startsWith('/media/');

  if (parsed.host != origin.host &&
      (isMediaPath || _isUnreachableDemoHost(parsed.host))) {
    return _retarget(parsed, origin);
  }

  return url;
}

String _originRoot(Uri origin) {
  final port = origin.hasPort ? ':${origin.port}' : '';
  return '${origin.scheme}://${origin.host}$port';
}

String _retarget(Uri parsed, Uri origin) {
  return parsed
      .replace(
        scheme: origin.scheme,
        host: origin.host,
        port: origin.hasPort ? origin.port : null,
      )
      .toString();
}

bool _isUnreachableDemoHost(String host) {
  if (host == 'localhost' || host == '127.0.0.1' || host == '0.0.0.0') {
    return true;
  }
  if (host.endsWith('.trycloudflare.com') ||
      host.endsWith('.loca.lt') ||
      host.endsWith('.lhr.life')) {
    return true;
  }
  return _isPrivateIp(host);
}

bool _isPrivateIp(String host) {
  final parts = host.split('.');
  if (parts.length != 4) return false;
  final nums = <int>[];
  for (final p in parts) {
    final n = int.tryParse(p);
    if (n == null || n < 0 || n > 255) return false;
    nums.add(n);
  }
  if (nums[0] == 10) return true;
  if (nums[0] == 192 && nums[1] == 168) return true;
  if (nums[0] == 172 && nums[1] >= 16 && nums[1] <= 31) return true;
  return false;
}
