import 'dart:typed_data';

Future<String> persistNotificationSound({
  required List<int> bytes,
  required String originalName,
}) async {
  throw UnsupportedError('Custom notification sounds need the Android or iOS app');
}

Future<bool> notificationSoundFileExists(String path) async => false;
