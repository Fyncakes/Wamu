import 'dart:io';
import 'dart:typed_data';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

const _maxImportBytes = 2 * 1024 * 1024;
const _okExt = {'.mp3', '.wav', '.aac', '.m4a', '.ogg', '.caf'};

Future<String> persistNotificationSound({
  required List<int> bytes,
  required String originalName,
}) async {
  if (bytes.length > _maxImportBytes) {
    throw const FormatException('Audio file is larger than 2 MB');
  }
  final ext = p.extension(originalName).toLowerCase();
  if (!_okExt.contains(ext)) {
    throw const FormatException('Use MP3, WAV, AAC, M4A, or OGG');
  }
  final dir = await getApplicationDocumentsDirectory();
  final dest = File(p.join(dir.path, 'wamu_custom_notify$ext'));
  await dest.writeAsBytes(Uint8List.fromList(bytes), flush: true);
  return dest.path;
}

Future<bool> notificationSoundFileExists(String path) async {
  try {
    return File(path).exists();
  } catch (_) {
    return false;
  }
}
