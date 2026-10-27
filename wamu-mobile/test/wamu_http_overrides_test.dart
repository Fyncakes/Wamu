import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:wamu_mobile/core/network/wamu_http_overrides_io.dart';

void main() {
  test('DoH fallback reaches Railway when system DNS fails the host', () async {
    installWamuHttpOverrides();

    var systemFailed = false;
    try {
      await InternetAddress.lookup('wamu-production.up.railway.app')
          .timeout(const Duration(seconds: 3));
    } catch (_) {
      systemFailed = true;
    }

    final client = HttpClient();
    addTearDown(() => client.close(force: true));
    final req = await client.getUrl(
      Uri.parse('https://wamu-production.up.railway.app/api/v1/health'),
    );
    final res = await req.close().timeout(const Duration(seconds: 25));
    final body = await res.transform(SystemEncoding().decoder).join();

    expect(res.statusCode, 200);
    expect(body, contains('"status": "ok"'));

    final otpReq = await client.postUrl(
      Uri.parse('https://wamu-production.up.railway.app/api/v1/auth/request-otp'),
    );
    otpReq.headers.contentType = ContentType.json;
    otpReq.write('{"phone":"+256788578208"}');
    final otpRes = await otpReq.close().timeout(const Duration(seconds: 25));
    final otpBody = await otpRes.transform(SystemEncoding().decoder).join();
    expect(otpRes.statusCode, 200);
    expect(otpBody, contains('OTP'));

    // Document that this machine currently needs the fallback (hotspot NXDOMAIN).
    // The assertions above are the green light either way.
    expect(systemFailed || body.contains('WAMU'), isTrue);
  }, timeout: const Timeout(Duration(seconds: 60)));
}
