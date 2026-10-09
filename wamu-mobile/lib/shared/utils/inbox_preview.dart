/// Pure inbox subtitle formatting — keep list rows scannable.
library;

enum InboxPreviewKind { text, photo, voice, document, reaction }

class InboxPreviewParts {
  const InboxPreviewParts({required this.kind, required this.text});

  final InboxPreviewKind kind;
  final String text;
}

final _dataSaver = RegExp(r'\s*\(data saver\)\s*', caseSensitive: false);
final _photoCount = RegExp(r'📷\s*(\d+)\s*photos?', caseSensitive: false);

/// Normalize API / local last-message preview for the chats inbox row.
InboxPreviewParts formatInboxPreview(String? raw) {
  var text = (raw ?? '').trim();
  text = text.replaceAll(_dataSaver, ' ').replaceAll(RegExp(r'\s+'), ' ').trim();

  if (text.isEmpty) {
    return const InboxPreviewParts(kind: InboxPreviewKind.text, text: 'Tap to open');
  }

  final lower = text.toLowerCase();

  if (lower.startsWith('you reacted') || lower.contains(' reacted ')) {
    return InboxPreviewParts(kind: InboxPreviewKind.reaction, text: text);
  }

  if (text.startsWith('{') && text.contains('order_id')) {
    return const InboxPreviewParts(kind: InboxPreviewKind.text, text: '🧾 Order · Pay with MoMo');
  }

  final photos = _photoCount.firstMatch(text);
  if (photos != null) {
    final n = photos.group(1) ?? '1';
    return InboxPreviewParts(kind: InboxPreviewKind.photo, text: '$n photos');
  }

  if (lower.contains('[image]') ||
      lower.startsWith('photo') ||
      text.contains('📷') ||
      lower == 'photo') {
    var caption = text
        .replaceAll(RegExp(r'\[image\]', caseSensitive: false), '')
        .replaceAll('📷', '')
        .trim();
    if (caption.toLowerCase() == 'photo' || caption.isEmpty) {
      caption = 'Photo';
    }
    return InboxPreviewParts(kind: InboxPreviewKind.photo, text: caption);
  }

  if (lower.contains('[voice]') ||
      lower.contains('voice note') ||
      lower.contains('voice message') ||
      text.contains('🎤')) {
    return const InboxPreviewParts(
      kind: InboxPreviewKind.voice,
      text: 'Voice message',
    );
  }

  if (text.contains('📄') || lower.contains('.pdf') || lower.startsWith('document')) {
    return const InboxPreviewParts(
      kind: InboxPreviewKind.document,
      text: 'Document',
    );
  }

  return InboxPreviewParts(kind: InboxPreviewKind.text, text: text);
}
