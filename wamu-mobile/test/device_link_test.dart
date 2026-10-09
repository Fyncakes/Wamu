import 'package:flutter_test/flutter_test.dart';
import 'package:wamu_mobile/core/device_link.dart';
import 'package:wamu_mobile/core/server_config.dart';

void main() {
  group('parseWamuQr', () {
    test('extracts one-time token without treating it as a password', () {
      final parsed = parseWamuQr('https://demo.lhr.life/link?k=abc_secret_token');
      expect(parsed.isAccountLink, isTrue);
      expect(parsed.accountToken, 'abc_secret_token');
      expect(parsed.apiBaseUrl, 'https://demo.lhr.life/api/v1');
    });

    test('parses compact JSON payload', () {
      final parsed = parseWamuQr('{"v":1,"k":"tok","api":"https://x/api/v1"}');
      expect(parsed.accountToken, 'tok');
      expect(parsed.apiBaseUrl, 'https://x/api/v1');
    });

    test('server-only connect URL has no account token', () {
      final parsed = parseWamuQr('https://abc123.lhr.life/api/v1');
      expect(parsed.isAccountLink, isFalse);
      expect(parsed.apiBaseUrl, contains('abc123.lhr.life'));
    });
  });

  group('normalizeApiBaseUrl', () {
    test('strips /link paste', () {
      expect(
        normalizeApiBaseUrl('https://abc123.lhr.life/link'),
        'https://abc123.lhr.life/api/v1',
      );
    });
  });
}
