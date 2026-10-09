import 'package:flutter_test/flutter_test.dart';
import 'package:wamu_mobile/features/calls/calls_repository.dart';

void main() {
  test('CallModel parses ice_servers with TURN credentials', () {
    final call = CallModel.fromJson({
      'id': 'c1',
      'caller_id': 'a',
      'callee_id': 'b',
      'call_type': 'VOICE',
      'status': 'RINGING',
      'ice_servers': [
        {'urls': 'stun:stun.l.google.com:19302'},
        {
          'urls': 'turn:turn.wamu.local:3478?transport=udp',
          'username': 'wamu',
          'credential': 'secret',
        },
      ],
    });
    expect(call.iceServers.length, 2);
    expect(call.peerConnectionConfig['iceServers'], call.iceServers);
    final turn = call.iceServers[1];
    expect(turn['username'], 'wamu');
    expect(turn['credential'], 'secret');
  });

  test('CallModel falls back to Google STUN when ice_servers empty', () {
    final call = CallModel.fromJson({
      'id': 'c1',
      'caller_id': 'a',
      'callee_id': 'b',
      'call_type': 'VOICE',
      'status': 'RINGING',
    });
    final servers = call.peerConnectionConfig['iceServers'] as List;
    expect(servers.length, 2);
    expect(servers.first['urls'], contains('stun:'));
  });
}
