import 'dart:io';
import 'dart:typed_data';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

Future<String?> writeMediaFile({
  required String id,
  required String filename,
  required Uint8List bytes,
}) async {
  try {
    final root = await getApplicationSupportDirectory();
    final dir = Directory(p.join(root.path, 'wamu_media_outbox'));
    if (!await dir.exists()) {
      await dir.create(recursive: true);
    }
    final safe = filename.replaceAll(RegExp(r'[^a-zA-Z0-9._-]'), '_');
    final file = File(p.join(dir.path, '$id-$safe'));
    await file.writeAsBytes(bytes, flush: true);
    return file.path;
  } catch (_) {
    return null;
  }
}

Future<Uint8List?> readMediaFile(String path) async {
  try {
    final file = File(path);
    if (!await file.exists()) return null;
    return file.readAsBytes();
  } catch (_) {
    return null;
  }
}

Future<void> deleteMediaFile(String path) async {
  try {
    final file = File(path);
    if (await file.exists()) await file.delete();
  } catch (_) {}
}
