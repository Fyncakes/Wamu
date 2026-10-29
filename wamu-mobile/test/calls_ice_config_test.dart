import 'package:flutter_test/flutter_test.dart';
import 'package:wamu_mobile/features/calls/calls_repository.dart';

void main() {
  test('peerConnectionConfig adds TURN when API only returns STUN', () {
    final call = CallModel(
      id: '1',
      callerId: 'a',
      calleeId: 'b',
      callType: 'VOICE',
      status: 'RINGING',
      iceServers: const [
        {'urls': 'stun:stun.l.google.com:19302'},
        {'urls': 'stun:stun1.l.google.com:19302'},
      ],
    );
    final cfg = call.peerConnectionConfig;
    final servers = cfg['iceServers'] as List;
    final text = servers.map((s) => s.toString().toLowerCase()).join(' ');
    expect(text.contains('stun:'), isTrue);
    expect(text.contains('turn:'), isTrue);
  });

  test('peerConnectionConfig keeps API TURN without duplicating fallback needlessly', () {
    final call = CallModel(
      id: '1',
      callerId: 'a',
      calleeId: 'b',
      callType: 'VIDEO',
      status: 'RINGING',
      iceServers: const [
        {'urls': 'stun:stun.l.google.com:19302'},
        {
          'urls': 'turn:turn.example.com:3478',
          'username': 'u',
          'credential': 'c',
        },
      ],
    );
    final cfg = call.peerConnectionConfig;
    final servers = cfg['iceServers'] as List;
    expect(servers.length, 2);
    expect(servers.last['urls'], 'turn:turn.example.com:3478');
  });
}
