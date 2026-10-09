import 'dart:typed_data';

import 'document_pick_stub.dart'
    if (dart.library.html) 'document_pick_web.dart' as impl;

class PickedDocument {
  const PickedDocument({
    required this.bytes,
    required this.filename,
    this.mimeType = 'application/pdf',
  });

  final Uint8List bytes;
  final String filename;
  final String mimeType;
}

/// Pick a PDF (web file input; other platforms return null until native wired).
Future<PickedDocument?> pickPdfDocument() => impl.pickPdfDocument();
