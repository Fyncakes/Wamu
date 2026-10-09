import 'package:flutter_test/flutter_test.dart';
import 'package:wamu_mobile/core/server_config.dart';

void main() {
  group('normalizeApiBaseUrl', () {
    test('adds /api/v1 to origin', () {
      expect(
        normalizeApiBaseUrl('https://abc123.lhr.life'),
        'https://abc123.lhr.life/api/v1',
      );
    });

    test('strips /connect paste', () {
      expect(
        normalizeApiBaseUrl('https://abc123.lhr.life/connect'),
        'https://abc123.lhr.life/api/v1',
      );
      expect(
        normalizeApiBaseUrl('https://abc123.lhr.life/connect/'),
        'https://abc123.lhr.life/api/v1',
      );
    });

    test('strips /link paste', () {
      expect(
        normalizeApiBaseUrl('https://abc123.lhr.life/link'),
        'https://abc123.lhr.life/api/v1',
      );
    });

    test('strips /health and /api/v1/health', () {
      expect(
        normalizeApiBaseUrl('https://x.lhr.life/health'),
        'https://x.lhr.life/api/v1',
      );
      expect(
        normalizeApiBaseUrl('https://x.lhr.life/api/v1/health'),
        'https://x.lhr.life/api/v1',
      );
    });

    test('prefers https for public tunnels without scheme', () {
      expect(
        normalizeApiBaseUrl('497d92c462b7d0.lhr.life'),
        'https://497d92c462b7d0.lhr.life/api/v1',
      );
      expect(
        normalizeApiBaseUrl('foo.trycloudflare.com'),
        'https://foo.trycloudflare.com/api/v1',
      );
    });

    test('uses http for LAN IPs without scheme', () {
      expect(
        normalizeApiBaseUrl('192.168.43.12:8000'),
        'http://192.168.43.12:8000/api/v1',
      );
      expect(
        normalizeApiBaseUrl('localhost:8000'),
        'http://localhost:8000/api/v1',
      );
    });

    test('rejects empty input', () {
      expect(() => normalizeApiBaseUrl('  '), throwsFormatException);
    });
  });
}
