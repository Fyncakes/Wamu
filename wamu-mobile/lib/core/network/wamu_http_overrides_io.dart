import 'dart:async';
import 'dart:convert';
import 'dart:io';

/// Some phone networks answer "no such name" for the Railway host.
/// Chrome still opens the site. This looks the name up over HTTPS and
/// connects to that address, with the Railway name kept on the certificate.
void installWamuHttpOverrides() {
  HttpOverrides.global = _WamuHttpOverrides();
}

class _WamuHttpOverrides extends HttpOverrides {
  @override
  HttpClient createHttpClient(SecurityContext? context) {
    final client = super.createHttpClient(context);
    client.connectionFactory = (uri, proxyHost, proxyPort) async {
      if (proxyHost != null && proxyPort != null) {
        return Socket.startConnect(proxyHost, proxyPort);
      }
      var lookupFailed = false;
      try {
        await InternetAddress.lookup(uri.host).timeout(const Duration(seconds: 4));
      } on SocketException {
        lookupFailed = true;
      } on TimeoutException {
        lookupFailed = true;
      }
      if (lookupFailed) return _connectResolved(uri);
      if (uri.scheme == 'https') {
        return SecureSocket.startConnect(uri.host, uri.port);
      }
      return Socket.startConnect(uri.host, uri.port);
    };
    return client;
  }
}

final Map<String, ({InternetAddress address, DateTime until})> _cache = {};

Future<ConnectionTask<Socket>> _connectResolved(Uri uri) async {
  final address = await _resolve(uri.host);
  if (uri.scheme != 'https') {
    return Socket.startConnect(address, uri.port);
  }
  final raw = await Socket.startConnect(address, uri.port);
  final secure = raw.socket.then(
    (sock) => SecureSocket.secure(
      sock,
      host: uri.host,
      supportedProtocols: const ['http/1.1'],
    ),
  );
  return ConnectionTask.fromSocket<Socket>(secure, raw.cancel);
}

Future<InternetAddress> _resolve(String host) async {
  final hit = _cache[host];
  if (hit != null && hit.until.isAfter(DateTime.now())) return hit.address;
  Object? last;
  for (final resolver in _resolvers) {
    try {
      final body = await _httpsGet(
        ip: resolver.ip,
        sni: resolver.sni,
        path: '${resolver.path}?name=${Uri.encodeQueryComponent(host)}&type=A',
      );
      final data = jsonDecode(body);
      if (data is Map && data['Answer'] is List) {
        for (final item in data['Answer'] as List) {
          if (item is Map && item['type'] == 1 && item['data'] is String) {
            final address = InternetAddress(item['data'] as String);
            _cache[host] = (
              address: address,
              until: DateTime.now().add(const Duration(seconds: 45)),
            );
            return address;
          }
        }
      }
    } catch (e) {
      last = e;
    }
  }
  throw SocketException('Failed host lookup: $host ($last)');
}

const _resolvers = [
  (ip: '8.8.8.8', sni: 'dns.google', path: '/resolve'),
  (ip: '1.1.1.1', sni: 'cloudflare-dns.com', path: '/dns-query'),
];

Future<String> _httpsGet({
  required String ip,
  required String sni,
  required String path,
}) async {
  final socket = await Socket.connect(
    InternetAddress(ip),
    443,
    timeout: const Duration(seconds: 8),
  );
  final secure = await SecureSocket.secure(
    socket,
    host: sni,
    supportedProtocols: const ['http/1.1'],
  );
  secure.write(
    'GET $path HTTP/1.1\r\n'
    'Host: $sni\r\n'
    'Accept: application/dns-json\r\n'
    'Connection: close\r\n\r\n',
  );
  final bytes = <int>[];
  try {
    await for (final chunk in secure.timeout(const Duration(seconds: 8))) {
      bytes.addAll(chunk);
      final headerEnd = _indexOfHeader(bytes);
      if (headerEnd < 0) continue;
      final header = utf8.decode(bytes.sublist(0, headerEnd), allowMalformed: true);
      final length = _contentLength(header);
      if (length != null && bytes.length >= headerEnd + 4 + length) break;
    }
  } on TimeoutException {
    // Use whatever arrived.
  } finally {
    secure.destroy();
  }
  final headerEnd = _indexOfHeader(bytes);
  if (headerEnd < 0) throw const SocketException('Bad DNS response');
  final header = utf8.decode(bytes.sublist(0, headerEnd), allowMalformed: true);
  if (!header.startsWith('HTTP/1.1 200') && !header.startsWith('HTTP/1.0 200')) {
    throw const SocketException('DNS lookup failed');
  }
  final length = _contentLength(header);
  final start = headerEnd + 4;
  final end = length == null ? bytes.length : (start + length).clamp(0, bytes.length);
  return utf8.decode(bytes.sublist(start, end), allowMalformed: true);
}

int _indexOfHeader(List<int> bytes) {
  for (var i = 0; i + 3 < bytes.length; i++) {
    if (bytes[i] == 13 && bytes[i + 1] == 10 && bytes[i + 2] == 13 && bytes[i + 3] == 10) {
      return i;
    }
  }
  return -1;
}

int? _contentLength(String header) {
  for (final line in header.split('\r\n')) {
    final lower = line.toLowerCase();
    if (lower.startsWith('content-length:')) {
      return int.tryParse(line.split(':').last.trim());
    }
  }
  return null;
}
