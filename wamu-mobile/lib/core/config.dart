import 'package:flutter/foundation.dart';

/// Compile-time defaults and app constants.
///
/// Runtime PC/tunnel URL is owned by [ServerConfig] (one APK, no rebuild).
class AppConfig {
  AppConfig._();

  static const String appName = 'WAMU';
  static const String tagline = "Uganda's Digital Home";
  static const String supportLine = 'Connect. Discover. Shop. Move. Grow.';
  static const String mockOtp = '123456';

  static const String androidEmulatorHost = '10.0.2.2';
  static const String localhostHost = 'localhost';

  static const String apiHostOverride = String.fromEnvironment('API_HOST');
  static const String apiBaseUrlOverride = String.fromEnvironment('API_BASE_URL');

  static const int apiPort = 8000;
  static const String apiPath = '/api/v1';

  static String get compileTimeApiBaseUrl {
    if (apiBaseUrlOverride.isNotEmpty) {
      return apiBaseUrlOverride.replaceAll(RegExp(r'/+$'), '');
    }
    if (kIsWeb) {
      final origin = Uri.base.origin;
      final u = Uri.tryParse(origin);
      // flutter run -d chrome serves UI on e.g. :5188; API stays on :8000.
      // Phone demo serves UI+API from the same origin — keep that path.
      if (u != null &&
          (u.host == 'localhost' || u.host == '127.0.0.1') &&
          u.hasPort &&
          u.port != apiPort &&
          u.port != 80 &&
          u.port != 443) {
        return 'http://${u.host}:$apiPort$apiPath';
      }
      return '$origin$apiPath';
    }
    return 'http://$host:$apiPort$apiPath';
  }

  static String get host {
    if (apiHostOverride.isNotEmpty) return apiHostOverride;
    if (kIsWeb) return localhostHost;
    switch (defaultTargetPlatform) {
      case TargetPlatform.android:
        return androidEmulatorHost;
      default:
        return localhostHost;
    }
  }
}
