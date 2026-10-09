import 'package:flutter_test/flutter_test.dart';

/// Mirrors Discover resume rule: only seek when player jumped backwards.
bool shouldSeekToResume(Duration current, Duration resumeAt) {
  if (resumeAt <= Duration.zero) return false;
  return current < resumeAt - const Duration(milliseconds: 400);
}

void main() {
  test('resume keeps position after pause — no seek when near resumeAt', () {
    final resumeAt = const Duration(seconds: 12);
    expect(shouldSeekToResume(const Duration(seconds: 12), resumeAt), isFalse);
    expect(shouldSeekToResume(const Duration(milliseconds: 11800), resumeAt), isFalse);
  });

  test('resume seeks when player restarted near zero', () {
    final resumeAt = const Duration(seconds: 12);
    expect(shouldSeekToResume(Duration.zero, resumeAt), isTrue);
    expect(shouldSeekToResume(const Duration(milliseconds: 200), resumeAt), isTrue);
  });
}
