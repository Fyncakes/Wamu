import 'package:flutter_test/flutter_test.dart';
import 'package:wamu_mobile/firebase_options.dart';

void main() {
  test('Firebase options are configured for FCM (wamu-f7877)', () {
    expect(DefaultFirebaseOptions.isConfigured, isTrue);
    expect(DefaultFirebaseOptions.android.projectId, 'wamu-f7877');
  });
}
