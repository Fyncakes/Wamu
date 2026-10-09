import 'package:flutter_test/flutter_test.dart';
import 'package:wamu_mobile/shared/utils/inbox_preview.dart';

void main() {
  test('formats album photo count', () {
    final p = formatInboxPreview('📷 3 photos');
    expect(p.kind, InboxPreviewKind.photo);
    expect(p.text, '3 photos');
  });

  test('formats single photo and strips data saver', () {
    final p = formatInboxPreview('📷 Photo (data saver)');
    expect(p.kind, InboxPreviewKind.photo);
    expect(p.text, 'Photo');
  });

  test('formats voice note as Voice message', () {
    final p = formatInboxPreview('🎤 Voice note');
    expect(p.kind, InboxPreviewKind.voice);
    expect(p.text, 'Voice message');
  });

  test('formats document', () {
    final p = formatInboxPreview('📄 report.pdf');
    expect(p.kind, InboxPreviewKind.document);
    expect(p.text, 'Document');
  });

  test('formats reaction preview', () {
    final p = formatInboxPreview('You reacted 👍 to "Hello"');
    expect(p.kind, InboxPreviewKind.reaction);
    expect(p.text, contains('You reacted'));
  });

  test('empty becomes Tap to open', () {
    expect(formatInboxPreview('').text, 'Tap to open');
  });
}
