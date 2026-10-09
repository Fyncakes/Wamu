import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'config.dart';
import 'storage/secure_storage.dart';

/// Runtime PC / tunnel server — one APK; change URL without rebuilding.
class ServerConfig {
  ServerConfig._();

  static const _storageKey = 'wamu_api_base_url';

  static String apiBaseUrl = AppConfig.compileTimeApiBaseUrl;
  static bool _userConfigured = false;

  static String get mediaOrigin {
    final u = Uri.parse(apiBaseUrl);
    final port = u.hasPort ? ':${u.port}' : '';
    return '${u.scheme}://${u.host}$port';
  }

  static String get wsBaseUrl {
    final u = Uri.parse(apiBaseUrl);
    final scheme = u.scheme == 'https' ? 'wss' : 'ws';
    final port = u.hasPort ? ':${u.port}' : '';
    return '$scheme://${u.host}$port${u.path}';
  }

  static bool get needsSetup {
    if (kIsWeb) return false;
    if (_userConfigured) return false;
    if (AppConfig.apiBaseUrlOverride.isNotEmpty) return false;
    if (AppConfig.apiHostOverride.isNotEmpty) return false;
    return defaultTargetPlatform == TargetPlatform.android;
  }

  static Future<void> hydrate(SecureStorageService storage) async {
    final saved = await storage.read(_storageKey);
    if (saved != null && saved.trim().isNotEmpty) {
      apiBaseUrl = normalizeApiBaseUrl(saved);
      _userConfigured = true;
    } else {
      apiBaseUrl = AppConfig.compileTimeApiBaseUrl;
      _userConfigured = AppConfig.apiBaseUrlOverride.isNotEmpty ||
          AppConfig.apiHostOverride.isNotEmpty;
    }
    // flutter run -d chrome: never call the UI port for API (404).
    correctWebDevServerUrl();
  }

  /// Keep web API origin aligned with the page (tunnel / localhost).
  static void correctWebDevServerUrl() {
    if (!kIsWeb) return;
    final page = Uri.base;
    final api = Uri.tryParse(apiBaseUrl);
    if (api == null) return;

    // Phone Chrome via Cloudflare / localhost.run — never keep a stale saved tunnel.
    final tunnelPage = page.host.endsWith('.trycloudflare.com') ||
        page.host.endsWith('.lhr.life') ||
        page.host.endsWith('.loca.lt');
    if (tunnelPage) {
      final scheme = page.scheme == 'https' ? 'https' : 'http';
      final next = '$scheme://${page.host}${AppConfig.apiPath}';
      if (apiBaseUrl != next) {
        apiBaseUrl = next;
      }
      return;
    }

    final pagePort = page.hasPort ? page.port : (page.scheme == 'https' ? 443 : 80);
    final apiPort = api.hasPort ? api.port : (api.scheme == 'https' ? 443 : 80);
    final localPage = page.host == 'localhost' || page.host == '127.0.0.1';
    if (!localPage) return;
    if (pagePort == AppConfig.apiPort) return; // same-origin phone/local API
    if (apiPort == pagePort || api.host == page.host && apiPort == pagePort) {
      apiBaseUrl = 'http://${page.host}:${AppConfig.apiPort}${AppConfig.apiPath}';
      _userConfigured = false;
    }
  }

  static Future<void> save(SecureStorageService storage, String raw) async {
    final normalized = normalizeApiBaseUrl(raw);
    await storage.write(_storageKey, normalized);
    apiBaseUrl = normalized;
    _userConfigured = true;
    correctWebDevServerUrl();
  }

  static Future<void> clear(SecureStorageService storage) async {
    await storage.delete(_storageKey);
    apiBaseUrl = AppConfig.compileTimeApiBaseUrl;
    _userConfigured = AppConfig.apiBaseUrlOverride.isNotEmpty ||
        AppConfig.apiHostOverride.isNotEmpty;
    correctWebDevServerUrl();
  }
}
/// Accepts host, origin, or full `/api/v1` (also `/connect` page paste).
String normalizeApiBaseUrl(String input) {
  var s = input.trim();
  if (s.isEmpty) {
    throw const FormatException('Server URL is required');
  }
  s = s.replaceFirst(RegExp(r'/api/v1/health/?$'), '/api/v1');
  s = s.replaceFirst(RegExp(r'/connect/?$'), '');
  s = s.replaceFirst(RegExp(r'/link/?$'), '');
  s = s.replaceFirst(RegExp(r'/health/?$'), '');

  if (!s.contains('://')) {
    final looksLocal = s.startsWith('localhost') ||
        s.startsWith('127.') ||
        RegExp(r'^\d{1,3}(\.\d{1,3}){3}').hasMatch(s);
    final looksPublicTunnel = s.contains('lhr.life') ||
        s.contains('trycloudflare.com') ||
        s.contains('.loca.lt');
    if (looksLocal) {
      s = 'http://$s';
    } else if (looksPublicTunnel) {
      s = 'https://$s';
    } else {
      s = 'http://$s';
    }
  }

  final u = Uri.parse(s);
  if (!u.hasScheme || u.host.isEmpty) {
    throw const FormatException('Invalid server URL');
  }
  final origin = '${u.scheme}://${u.host}${u.hasPort ? ':${u.port}' : ''}';
  return '$origin/api/v1';
}

class ServerConfigState {
  const ServerConfigState({
    required this.apiBaseUrl,
    required this.configured,
  });

  final String apiBaseUrl;
  final bool configured;
}

class ServerConfigNotifier extends StateNotifier<ServerConfigState> {
  ServerConfigNotifier(this._storage)
      : super(ServerConfigState(
          apiBaseUrl: ServerConfig.apiBaseUrl,
          configured: !ServerConfig.needsSetup,
        ));

  final SecureStorageService _storage;

  Future<void> setServerUrl(String raw) async {
    await ServerConfig.save(_storage, raw);
    state = ServerConfigState(
      apiBaseUrl: ServerConfig.apiBaseUrl,
      configured: true,
    );
  }

  Future<void> clearServerUrl() async {
    await ServerConfig.clear(_storage);
    state = ServerConfigState(
      apiBaseUrl: ServerConfig.apiBaseUrl,
      configured: !ServerConfig.needsSetup,
    );
  }
}

final serverConfigProvider =
    StateNotifierProvider<ServerConfigNotifier, ServerConfigState>((ref) {
  return ServerConfigNotifier(ref.watch(secureStorageProvider));
});
