import 'dart:typed_data';

Future<void> saveAndShareBytes({
  required Uint8List bytes,
  required String filename,
  required String mimeType,
  String? subject,
}) async {
  throw UnsupportedError('saveAndShareBytes is not available on this platform');
}
