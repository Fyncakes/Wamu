import 'dart:typed_data';

/// Web / non-IO stub — no durable disk queue.
Future<String?> writeMediaFile({
  required String id,
  required String filename,
  required Uint8List bytes,
}) async =>
    null;

Future<Uint8List?> readMediaFile(String path) async => null;

Future<void> deleteMediaFile(String path) async {}
