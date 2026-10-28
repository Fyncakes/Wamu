import 'dart:async';
import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

import '../../core/network/api_client.dart';
import '../../core/server_config.dart';

class CallModel {
  const CallModel({
    required this.id,
    required this.callerId,
    required this.calleeId,
    required this.callType,
    required this.status,
    this.conversationId,
    this.peerName,
    this.direction,
    this.createdAt,
    this.iceServers = const [],
  });

  factory CallModel.fromJson(Map<String, dynamic> json) {
    final rawIce = json['ice_servers'];
    final ice = <Map<String, dynamic>>[];
    if (rawIce is List) {
      for (final item in rawIce) {
        if (item is! Map) continue;
        final m = Map<String, dynamic>.from(item);
        final rawUrls = m['urls'];
        // Backend may send a string or a list of URLs.
        final List<String> urlList;
        if (rawUrls is List) {
          urlList = rawUrls.map((e) => e.toString()).where((u) => u.isNotEmpty).toList();
        } else {
          final one = rawUrls?.toString() ?? '';
          urlList = one.isEmpty ? const <String>[] : <String>[one];
        }
        if (urlList.isEmpty) continue;
        final entry = <String, dynamic>{
          'urls': urlList.length == 1 ? urlList.first : urlList,
        };
        final user = m['username']?.toString();
        final cred = m['credential']?.toString();
        if (user != null && user.isNotEmpty) {
          entry['username'] = user;
        }
        if (cred != null && cred.isNotEmpty) {
          entry['credential'] = cred;
        }
        ice.add(entry);
      }
    }
    return CallModel(
      id: json['id']?.toString() ?? '',
      callerId: json['caller_id']?.toString() ?? '',
      calleeId: json['callee_id']?.toString() ?? '',
      conversationId: json['conversation_id']?.toString(),
      callType: json['call_type']?.toString() ?? 'VOICE',
      status: json['status']?.toString() ?? 'RINGING',
      peerName: json['peer_name']?.toString() ?? json['caller_name']?.toString(),
      direction: json['direction']?.toString(),
      createdAt: json['created_at']?.toString(),
      iceServers: ice,
    );
  }

  final String id;
  final String callerId;
  final String calleeId;
  final String? conversationId;
  final String callType;
  final String status;
  final String? peerName;
  final String? direction;
  final String? createdAt;
  final List<Map<String, dynamic>> iceServers;

  bool get isVideo => callType == 'VIDEO';
  bool get isIncoming => direction == 'INCOMING';

  /// WebRTC peer-connection config (API TURN when present, else Google STUN).
  Map<String, dynamic> get peerConnectionConfig {
    final servers = iceServers.isNotEmpty
        ? iceServers
        : const [
            {'urls': 'stun:stun.l.google.com:19302'},
            {'urls': 'stun:stun1.l.google.com:19302'},
            {
              'urls': 'turn:openrelay.metered.ca:80',
              'username': 'openrelayproject',
              'credential': 'openrelayproject',
            },
            {
              'urls': 'turns:openrelay.metered.ca:443',
              'username': 'openrelayproject',
              'credential': 'openrelayproject',
            },
          ];
    return {
      'iceServers': servers,
      'sdpSemantics': 'unified-plan',
      'iceCandidatePoolSize': 4,
    };
  }
}

class CallsRepository {
  CallsRepository(this._client);

  final ApiClient _client;

  Future<List<CallModel>> history() async {
    final res = await _client.get('/calls/history');
    final data = res.data;
    if (data is List) {
      return data.cast<Map<String, dynamic>>().map(CallModel.fromJson).toList();
    }
    return [];
  }

  Future<CallModel> start({
    String? conversationId,
    String? calleeId,
    required String callType,
  }) async {
    final res = await _client.post('/calls', data: {
      if (conversationId != null) 'conversation_id': conversationId,
      if (calleeId != null) 'callee_id': calleeId,
      'call_type': callType,
    });
    return CallModel.fromJson(res.data as Map<String, dynamic>);
  }

  Future<CallModel> accept(String callId) async {
    final res = await _client.post('/calls/$callId/accept');
    return CallModel.fromJson(res.data as Map<String, dynamic>);
  }

  Future<CallModel> reject(String callId) async {
    final res = await _client.post('/calls/$callId/reject');
    return CallModel.fromJson(res.data as Map<String, dynamic>);
  }

  Future<CallModel> end(String callId) async {
    final res = await _client.post('/calls/$callId/end');
    return CallModel.fromJson(res.data as Map<String, dynamic>);
  }

  Future<CallModel> get(String callId) async {
    final res = await _client.get('/calls/$callId');
    return CallModel.fromJson(res.data as Map<String, dynamic>);
  }

  Future<WebSocketChannel> connectSignal() async {
    final ticketRes = await _client.post('/calls/ws-ticket');
    final ticket = (ticketRes.data as Map)['ticket']?.toString() ?? '';
    if (ticket.isEmpty) {
      throw StateError('Could not obtain calls WS ticket');
    }
    final uri = Uri.parse(
      '${ServerConfig.wsBaseUrl}/calls/ws?ticket=${Uri.encodeComponent(ticket)}',
    );
    return WebSocketChannel.connect(uri);
  }

  Future<void> sendSignal({
    required WebSocketChannel channel,
    required String callId,
    required String toUserId,
    required Map<String, dynamic> data,
  }) async {
    channel.sink.add(jsonEncode({
      'event': 'signal',
      'call_id': callId,
      'to_user_id': toUserId,
      'data': data,
    }));
  }
}

final callsRepositoryProvider = Provider<CallsRepository>((ref) {
  return CallsRepository(ref.watch(apiClientProvider));
});
