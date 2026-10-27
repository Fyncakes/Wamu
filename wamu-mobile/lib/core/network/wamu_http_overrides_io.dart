import 'dart:async';
import 'dart:convert';
import 'dart:io';

/// Some phone networks answer "no such name" for the Railway host while
/// Chrome still opens the site. Look the name up over HTTPS (by hostname,
/// not a blocked DNS IP), then connect with the Railway name on the cert.
void installWamuHttpOverrides() {
  HttpOverrides.global = _WamuHttpOverrides();
}

class _WamuHttpOverrides extends HttpOverrides {
  @override
  HttpClient createHttpClient(SecurityContext? context) {
    final client = super.createHttpClient(context);
    client.connectionFactory = (uri, proxyHost, proxyPort) {
      if (proxyHost != null && proxyPort != null) {
        return Socket.startConnect(proxyHost, proxyPort);
      }
      return _connect(uri);
    };
    return client;
  }
}

final Map<String, ({InternetAddress address, DateTime until})> _cache = {};

bool _needsPublicLookup(String host) {
  final h = host.toLowerCase();
  return h.endsWith('railway.app') ||
      h.endsWith('wamu.ug') ||
      h == 'wamu.ug';
}

bool _isDohHost(String host) {
  final h = host.toLowerCase();
  return h == 'dns.google' ||
      h == 'cloudflare-dns.com' ||
      h == 'dns.cloudflare.com' ||
      h == 'mozilla.cloudflare-dns.com';
}

Future<ConnectionTask<Socket>> _connect(Uri uri) async {
  // Never recurse DoH through DoH — those names resolve on carrier DNS.
  if (_isDohHost(uri.host)) {
    return _start(uri, uri.host);
  }

  InternetAddress? address;
  Object? systemError;

  if (!_needsPublicLookup(uri.host)) {
    try {
      address = await _systemLookup(uri.host);
    } catch (e) {
      systemError = e;
    }
  }

  address ??= await _resolveViaDoh(uri.host);

  if (address == null) {
    try {
      address = await _systemLookup(uri.host);
    } catch (e) {
      systemError ??= e;
      throw SocketException('Failed host lookup: ${uri.host} ($systemError)');
    }
  }

  return _start(uri, address);
}

Future<InternetAddress> _systemLookup(String host) async {
  final addrs = await InternetAddress.lookup(host).timeout(const Duration(seconds: 4));
  for (final a in addrs) {
    if (a.type == InternetAddressType.IPv4) return a;
  }
  if (addrs.isNotEmpty) return addrs.first;
  throw const SocketException('Empty DNS answer');
}

Future<ConnectionTask<Socket>> _start(Uri uri, Object host) async {
  if (uri.scheme == 'https') {
    if (host is InternetAddress) {
      final raw = await Socket.startConnect(host, uri.port);
      final secure = raw.socket.then(
        (sock) => SecureSocket.secure(
          sock,
          host: uri.host,
          supportedProtocols: const ['http/1.1'],
        ),
      );
      return ConnectionTask.fromSocket<Socket>(secure, raw.cancel);
    }
    return SecureSocket.startConnect(
      host,
      uri.port,
      supportedProtocols: const ['http/1.1'],
    );
  }
  return Socket.startConnect(host, uri.port);
}

Future<InternetAddress?> _resolveViaDoh(String host) async {
  final hit = _cache[host];
  if (hit != null && hit.until.isAfter(DateTime.now())) return hit.address;

  Object? last;
  for (final resolver in _resolvers) {
    try {
      final body = await _dohQuery(resolver, host);
      final data = jsonDecode(body);
      if (data is! Map) continue;
      final answers = data['Answer'];
      if (answers is! List) continue;
      for (final item in answers) {
        if (item is Map && item['type'] == 1 && item['data'] is String) {
          final address = InternetAddress(item['data'] as String);
          final ttl = (item['TTL'] is int) ? item['TTL'] as int : 45;
          _cache[host] = (
            address: address,
            until: DateTime.now().add(Duration(seconds: ttl.clamp(15, 120))),
          );
          return address;
        }
      }
    } catch (e) {
      last = e;
    }
  }
  assert(() {
    // ignore: avoid_print
    print('Wamu DoH failed for $host: $last');
    return true;
  }());
  return null;
}

const _resolvers = [
  (host: 'dns.google', path: '/resolve'),
  (host: 'cloudflare-dns.com', path: '/dns-query'),
  (host: 'mozilla.cloudflare-dns.com', path: '/dns-query'),
];

/// Use a plain HttpClient so DoH goes through normal hostname connect,
/// not a raw IP that many mobile networks block (8.8.8.8 / 1.1.1.1).
Future<String> _dohQuery(
  ({String host, String path}) resolver,
  String name,
) async {
  final client = HttpClient();
  client.connectionTimeout = const Duration(seconds: 8);
  client.idleTimeout = const Duration(seconds: 8);
  try {
    final uri = Uri.https(
      resolver.host,
      resolver.path,
      {'name': name, 'type': 'A'},
    );
    final req = await client.getUrl(uri).timeout(const Duration(seconds: 8));
    req.headers.set(HttpHeaders.acceptHeader, 'application/dns-json');
    final res = await req.close().timeout(const Duration(seconds: 8));
    final body = await res.transform(utf8.decoder).join();
    if (res.statusCode != 200) {
      throw SocketException('DoH ${resolver.host} HTTP ${res.statusCode}');
    }
    return body;
  } finally {
    client.close(force: true);
  }
}
