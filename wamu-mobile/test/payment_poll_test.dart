import 'package:flutter_test/flutter_test.dart';

/// Pure poll-loop helper mirroring [OrdersRepository.payOrderAndAwait] status logic.
String? nextPollAction(String status) {
  final s = status.toUpperCase();
  if (s == 'SUCCESS' || s == 'FAILED') return 'stop';
  if (s == 'PENDING' || s == 'PROCESSING') return 'refresh';
  return 'refresh';
}

void main() {
  test('payment poll stops on terminal statuses', () {
    expect(nextPollAction('SUCCESS'), 'stop');
    expect(nextPollAction('FAILED'), 'stop');
    expect(nextPollAction('success'), 'stop');
  });

  test('payment poll continues on open statuses', () {
    expect(nextPollAction('PENDING'), 'refresh');
    expect(nextPollAction('PROCESSING'), 'refresh');
    expect(nextPollAction('UNKNOWN'), 'refresh');
  });
}
