import 'package:flutter_test/flutter_test.dart';
import 'package:wamu_mobile/firebase_options.dart';

void main() {
  test('placeholder Firebase options keep FCM off until flutterfire configure', () {
    expect(DefaultFirebaseOptions.isConfigured, isFalse);
    expect(DefaultFirebaseOptions.android.projectId, 'wamu-unconfigured');
  });
}
