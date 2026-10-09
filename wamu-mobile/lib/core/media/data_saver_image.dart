import 'dart:typed_data';

import 'package:image/image.dart' as img;

/// Shrink outgoing chat photos when Data saver is on (Uganda MTN/Airtel).
///
/// Targets ~1280px long edge and JPEG quality ~55 so uploads stay small
/// without adding another package beyond `image`.
Uint8List compressForDataSaver(
  Uint8List bytes, {
  int maxEdge = 1280,
  int quality = 55,
}) {
  img.Image? decoded;
  try {
    decoded = img.decodeImage(bytes);
  } catch (_) {
    return bytes;
  }
  if (decoded == null) return bytes;

  img.Image out = decoded;
  final longEdge = decoded.width > decoded.height ? decoded.width : decoded.height;
  if (longEdge > maxEdge) {
    out = img.copyResize(
      decoded,
      width: decoded.width >= decoded.height ? maxEdge : null,
      height: decoded.height > decoded.width ? maxEdge : null,
      interpolation: img.Interpolation.average,
    );
  }

  try {
    final encoded = img.encodeJpg(out, quality: quality);
    if (encoded.isEmpty) return bytes;
    // Prefer smaller output; if encode somehow grew, keep original.
    return encoded.length < bytes.length ? Uint8List.fromList(encoded) : bytes;
  } catch (_) {
    return bytes;
  }
}