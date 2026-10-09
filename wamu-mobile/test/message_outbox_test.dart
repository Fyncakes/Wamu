import 'package:flutter_test/flutter_test.dart';
import 'package:wamu_mobile/features/chat/message_outbox.dart';

void main() {
  test('outbox enqueue → send → remove', () async {
    final store = <String, String>{};
    final box = MessageOutbox(
      read: (k) async => store[k],
      write: (k, v) async => store[k] = v,
    );
    final entry = await box.enqueue(
      conversationId: 'c1',
      body: 'Hello Kampala',
    );
    expect(entry.status, OutboxStatus.queued);
    expect((await box.pendingFor('c1')).length, 1);

    await box.markSending(entry.id);
    expect((await box.pendingFor('c1')).first.status, OutboxStatus.sending);
    expect((await box.pendingFor('c1')).first.attempts, 1);

    await box.markSent(entry.id);
    expect((await box.pendingFor('c1')), isEmpty);
  });

  test('failed entries stay pending', () async {
    final store = <String, String>{};
    final box = MessageOutbox(
      read: (k) async => store[k],
      write: (k, v) async => store[k] = v,
    );
    final entry = await box.enqueue(conversationId: 'c1', body: 'x');
    await box.markFailed(entry.id, 'network');
    final pending = await box.pendingFor('c1');
    expect(pending.single.status, OutboxStatus.failed);
    expect(pending.single.lastError, 'network');
  });
}
