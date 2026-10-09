import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:wamu_mobile/core/media/data_saver_image.dart';

void main() {
  test('compressForDataSaver shrinks a large JPEG', () {
    final src = img.Image(width: 2000, height: 1500);
    img.fill(src, color: img.ColorRgb8(40, 120, 80));
    final raw = Uint8List.fromList(img.encodeJpg(src, quality: 95));

    final out = compressForDataSaver(raw);
    expect(out.length, lessThan(raw.length));

    final decoded = img.decodeImage(out);
    expect(decoded, isNotNull);
    expect(decoded!.width, lessThanOrEqualTo(1280));
    expect(decoded.height, lessThanOrEqualTo(1280));
  });

  test('compressForDataSaver returns original when decode fails', () {
    final junk = Uint8List.fromList([1, 2, 3, 4]);
    expect(compressForDataSaver(junk), same(junk));
  });
}
