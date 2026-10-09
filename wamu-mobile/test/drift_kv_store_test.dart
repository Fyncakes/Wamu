import 'package:flutter_test/flutter_test.dart';
import 'package:wamu_mobile/core/storage/chat_kv_memory.dart';
import 'package:wamu_mobile/features/chat/local_message_cache.dart';
import 'package:wamu_mobile/features/chat/message_outbox.dart';
import 'package:wamu_mobile/shared/models/chat_model.dart';

void main() {
  test('Drift KvStore backs outbox + thread cache', () async {
    final store = openMemoryChatKvStore();
    addTearDown(store.close);

    final outbox = MessageOutbox.fromKv(store);
    final entry = await outbox.enqueue(
      conversationId: 'c1',
      body: 'Jebale from Drift',
    );
    expect((await outbox.pendingFor('c1')).single.id, entry.id);

    final cache = LocalMessageCache.fromKv(store);
    await cache.save('c1', [
      ChatMessageModel(
        id: 'm1',
        content: 'Cached',
        isMine: true,
        createdAt: '2026-01-01T00:00:00Z',
      ),
    ]);
    expect((await cache.load('c1')).single.content, 'Cached');

    await outbox.markSent(entry.id);
    expect(await outbox.pendingFor('c1'), isEmpty);
  });
}
