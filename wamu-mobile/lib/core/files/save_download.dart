import 'dart:typed_data';

import 'save_download_stub.dart'
    if (dart.library.html) 'save_download_web.dart'
    if (dart.library.io) 'save_download_io.dart' as impl;

/// Save report bytes and open the platform share/download UI.
///
/// Web: browser download via Blob. Mobile/desktop: temp file + share sheet.
Future<void> saveAndShareBytes({
  required List<int> bytes,
  required String filename,
  required String mimeType,
  String? subject,
}) =>
    impl.saveAndShareBytes(
      bytes: bytes is Uint8List ? bytes : Uint8List.fromList(bytes),
      filename: filename,
      mimeType: mimeType,
      subject: subject,
    );
