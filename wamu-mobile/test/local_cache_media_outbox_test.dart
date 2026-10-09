import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:wamu_mobile/features/chat/local_message_cache.dart';
import 'package:wamu_mobile/features/chat/media_outbox.dart';
import 'package:wamu_mobile/shared/models/chat_model.dart';

void main() {
  test('local message cache round-trip', () async {
    final store = <String, String>{};
    final cache = LocalMessageCache(
      read: (k) async => store[k],
      write: (k, v) async => store[k] = v,
    );
    final msg = ChatMessageModel(
      id: 'm1',
      content: 'Jebale',
      isMine: true,
      createdAt: '2026-01-01T00:00:00Z',
      status: 'SENT',
    );
    await cache.save('c1', [msg]);
    final loaded = await cache.load('c1');
    expect(loaded.single.content, 'Jebale');
    expect(loaded.single.isMine, isTrue);

    await cache.upsert(
      'c1',
      ChatMessageModel(id: 'm2', content: 'Webale', isMine: false),
    );
    expect((await cache.load('c1')).length, 2);
  });

  test('media outbox persists small payloads', () async {
    final store = <String, String>{};
    final box = MediaOutbox(
      read: (k) async => store[k],
      write: (k, v) async => store[k] = v,
    );
    final bytes = Uint8List.fromList(utf8.encode('fake-jpeg'));
    final entry = await box.enqueue(
      conversationId: 'c1',
      bytes: bytes,
      filename: 'a.jpg',
      contentType: 'image/jpeg',
      caption: '📷 Photo',
    );
    expect(entry.persistedBase64, isNotNull);
    expect(box.bytesFor(entry), completion(bytes));
    await box.markDone(entry.id);
    expect(await box.allPending(), isEmpty);
  });
}
