import 'dart:convert';

/// Parsed scan of a Wamu QR (server URL and/or one-time account-link token).
class WamuQrPayload {
  const WamuQrPayload({this.accountToken, this.apiBaseUrl});

  /// Opaque one-time login secret. Never a password or phone number.
  final String? accountToken;
  final String? apiBaseUrl;

  bool get isAccountLink => accountToken != null && accountToken!.isNotEmpty;
}

/// Accepts `/link?k=`, `wamu://account?k=&api=`, or compact JSON `{"v":1,"k":"...","api":"..."}`.
WamuQrPayload parseWamuQr(String raw) {
  final s = raw.trim();
  if (s.isEmpty) return const WamuQrPayload();

  if (s.startsWith('{')) {
    try {
      final map = jsonDecode(s);
      if (map is Map) {
        final k = map['k']?.toString();
        final api = map['api']?.toString();
        return WamuQrPayload(
          accountToken: (k == null || k.isEmpty) ? null : k,
          apiBaseUrl: (api == null || api.isEmpty) ? null : api,
        );
      }
    } catch (_) {}
  }

  final uri = Uri.tryParse(s);
  if (uri == null) {
    return WamuQrPayload(accountToken: s);
  }

  final k = uri.queryParameters['k'];
  var api = uri.queryParameters['api'];
  if ((api == null || api.isEmpty) &&
      (uri.scheme == 'http' || uri.scheme == 'https') &&
      uri.host.isNotEmpty) {
    api = '${uri.scheme}://${uri.host}${uri.hasPort ? ':${uri.port}' : ''}/api/v1';
  }
  if (k != null && k.isNotEmpty) {
    return WamuQrPayload(accountToken: k, apiBaseUrl: api);
  }
  if (uri.scheme == 'wamu') {
    final url = uri.queryParameters['url'] ?? uri.queryParameters['u'];
    return WamuQrPayload(apiBaseUrl: url ?? api);
  }
  return WamuQrPayload(apiBaseUrl: s);
}
