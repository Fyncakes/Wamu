import 'package:flutter_test/flutter_test.dart';
import 'package:wamu_mobile/core/push/call_focus.dart';

void main() {
  test('PendingIncomingCall marks video correctly', () {
    const voice = PendingIncomingCall(callId: '1', callType: 'VOICE');
    const video = PendingIncomingCall(callId: '2', callType: 'video');
    expect(voice.isVideo, isFalse);
    expect(video.isVideo, isTrue);
  });
}
