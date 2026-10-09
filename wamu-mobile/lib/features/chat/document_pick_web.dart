// ignore_for_file: avoid_web_libraries_in_flutter, deprecated_member_use

import 'dart:async';
import 'dart:html' as html;
import 'dart:typed_data';

import 'document_pick.dart';

Future<PickedDocument?> pickPdfDocument() async {
  final input = html.FileUploadInputElement()
    ..accept = 'application/pdf,.pdf'
    ..multiple = false;
  final completer = Completer<PickedDocument?>();

  void cleanup() {
    input.remove();
  }

  input.onChange.listen((_) async {
    final files = input.files;
    if (files == null || files.isEmpty) {
      if (!completer.isCompleted) completer.complete(null);
      cleanup();
      return;
    }
    final file = files.first;
    final reader = html.FileReader();
    reader.onLoadEnd.listen((_) {
      try {
        final result = reader.result;
        Uint8List? bytes;
        if (result is Uint8List) {
          bytes = result;
        } else if (result is ByteBuffer) {
          bytes = result.asUint8List();
        } else if (result is List<int>) {
          bytes = Uint8List.fromList(result);
        }
        if (bytes == null) {
          if (!completer.isCompleted) completer.complete(null);
          cleanup();
          return;
        }
        if (!completer.isCompleted) {
          completer.complete(
            PickedDocument(
              bytes: bytes,
              filename: file.name.isNotEmpty ? file.name : 'document.pdf',
              mimeType: file.type.isNotEmpty ? file.type : 'application/pdf',
            ),
          );
        }
      } catch (_) {
        if (!completer.isCompleted) completer.complete(null);
      }
      cleanup();
    });
    reader.onError.listen((_) {
      if (!completer.isCompleted) completer.complete(null);
      cleanup();
    });
    reader.readAsArrayBuffer(file);
  });

  html.document.body?.append(input);
  input.click();

  return completer.future.timeout(
    const Duration(minutes: 2),
    onTimeout: () {
      cleanup();
      return null;
    },
  );
}
