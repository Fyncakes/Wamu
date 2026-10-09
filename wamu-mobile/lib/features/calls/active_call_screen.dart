import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

import '../auth/auth_provider.dart';
import 'calls_repository.dart';

/// Active 1:1 voice/video call with WebSocket signaling + WebRTC.
class ActiveCallScreen extends ConsumerStatefulWidget {
  const ActiveCallScreen({
    super.key,
    required this.callId,
    required this.isCaller,
    this.peerName,
    this.video = false,
  });

  final String callId;
  final bool isCaller;
  final String? peerName;
  final bool video;

  @override
  ConsumerState<ActiveCallScreen> createState() => _ActiveCallScreenState();
}

class _ActiveCallScreenState extends ConsumerState<ActiveCallScreen> {
  final _localRenderer = RTCVideoRenderer();
  final _remoteRenderer = RTCVideoRenderer();
  RTCPeerConnection? _pc;
  MediaStream? _localStream;
  MediaStream? _remoteStream;
  WebSocketChannel? _channel;
  StreamSubscription? _sub;
  String _status = 'Connecting…';
  bool _muted = false;
  bool _camOff = false;
  bool _renderersReady = false;
  bool _hasRemoteVideo = false;
  String? _peerUserId;
  bool _ending = false;
  bool _remoteDescriptionSet = false;
  final List<RTCIceCandidate> _pendingCandidates = [];

  @override
  void initState() {
    super.initState();
    _bootstrap();
  }

  Future<void> _bindRemoteStream(MediaStream stream) async {
    _remoteStream = stream;
    final hasVideo = stream.getVideoTracks().isNotEmpty;
    // Force re-bind so web picks up video tracks that arrived after audio.
    _remoteRenderer.srcObject = null;
    _remoteRenderer.srcObject = stream;
    if (!mounted) return;
    setState(() {
      _hasRemoteVideo = hasVideo;
      if (_status == 'Connecting…' ||
          _status == 'Calling…' ||
          _status == 'Ring answered…' ||
          _status == 'In call') {
        _status = hasVideo || !widget.video ? 'Connected' : 'Connected · waiting for camera…';
      }
    });
  }

  Future<void> _attachRemoteTrack(RTCTrackEvent event) async {
    try {
      final track = event.track;
      track.enabled = true;

      MediaStream stream;
      if (event.streams.isNotEmpty) {
        stream = event.streams.first;
        // Ensure the track is present on the stream wrapper we keep.
        final already = stream.getTracks().any((t) => t.id == track.id);
        if (!already) {
          try {
            await stream.addTrack(track);
          } catch (_) {}
        }
      } else {
        stream = _remoteStream ?? await createLocalMediaStream('remote');
        final already = stream.getTracks().any((t) => t.id == track.id);
        if (!already) {
          await stream.addTrack(track);
        }
      }

      await _bindRemoteStream(stream);

      // Chrome often delivers muted tracks first; re-bind when frames start.
      try {
        track.onUnMute = () {
          unawaited(_bindRemoteStream(stream));
        };
      } catch (_) {}
    } catch (e) {
      if (kDebugMode) {
        debugPrint('attachRemoteTrack failed: $e');
      }
    }
  }

  Future<void> _flushPendingCandidates() async {
    if (_pc == null || !_remoteDescriptionSet) return;
    final pending = List<RTCIceCandidate>.from(_pendingCandidates);
    _pendingCandidates.clear();
    for (final c in pending) {
      try {
        await _pc!.addCandidate(c);
      } catch (_) {}
    }
  }

  Future<void> _bootstrap() async {
    await _localRenderer.initialize();
    await _remoteRenderer.initialize();
    if (mounted) setState(() => _renderersReady = true);
    try {
      final repo = ref.read(callsRepositoryProvider);
      final call = await repo.get(widget.callId);
      final me = ref.read(authProvider).user?.id;
      _peerUserId = call.callerId == me ? call.calleeId : call.callerId;

      _channel = await repo.connectSignal();
      _sub = _channel!.stream.listen(_onSignal, onError: (_) {}, onDone: () {});

      _pc = await createPeerConnection(call.peerConnectionConfig);
      _pc!.onTrack = (event) {
        unawaited(_attachRemoteTrack(event));
      };
      _pc!.onIceConnectionState = (state) {
        if (!mounted) return;
        if (state == RTCIceConnectionState.RTCIceConnectionStateConnected ||
            state == RTCIceConnectionState.RTCIceConnectionStateCompleted) {
          setState(() {
            if (_hasRemoteVideo || !widget.video) {
              _status = 'Connected';
            } else {
              _status = 'Connected · waiting for camera…';
            }
          });
          // Re-apply remote stream after ICE latches — fixes blank remote view on web.
          final remote = _remoteStream;
          if (remote != null) {
            unawaited(_bindRemoteStream(remote));
          }
        } else if (state == RTCIceConnectionState.RTCIceConnectionStateFailed) {
          setState(() => _status = 'Connection failed — try again on Wi‑Fi');
        }
      };
      _pc!.onIceCandidate = (candidate) {
        if (candidate.candidate == null || _peerUserId == null) return;
        repo.sendSignal(
          channel: _channel!,
          callId: widget.callId,
          toUserId: _peerUserId!,
          data: {
            'type': 'candidate',
            'candidate': candidate.toMap(),
          },
        );
      };

      _localStream = await navigator.mediaDevices.getUserMedia({
        'audio': true,
        'video': widget.video
            ? {
                'facingMode': 'user',
                'width': {'ideal': 1280},
                'height': {'ideal': 720},
              }
            : false,
      });
      _localRenderer.srcObject = _localStream;
      for (final track in _localStream!.getTracks()) {
        await _pc!.addTrack(track, _localStream!);
      }

      if (widget.isCaller) {
        setState(() => _status = 'Calling…');
        // Wait for callee accept before SDP offer (avoids race)
      } else {
        setState(() => _status = 'Connecting…');
        await repo.accept(widget.callId);
      }
    } catch (e) {
      if (mounted) {
        final msg = e.toString();
        final friendly = msg.contains('NotAllowedError') ||
                msg.contains('Permission') ||
                msg.contains('NotFoundError') ||
                msg.toLowerCase().contains('camera')
            ? 'Allow Camera and Microphone in phone settings, then try again.'
            : 'Could not start call: $e';
        setState(() => _status = friendly);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(friendly), duration: const Duration(seconds: 6)),
        );
      }
    }
  }

  Future<void> _createAndSendOffer() async {
    if (_pc == null || _peerUserId == null || _channel == null) return;
    final offer = await _pc!.createOffer({
      'offerToReceiveAudio': true,
      'offerToReceiveVideo': widget.video,
    });
    await _pc!.setLocalDescription(offer);
    await ref.read(callsRepositoryProvider).sendSignal(
          channel: _channel!,
          callId: widget.callId,
          toUserId: _peerUserId!,
          data: {'type': 'offer', 'sdp': offer.toMap()},
        );
  }

  Future<void> _onSignal(dynamic raw) async {
    try {
      final data = raw is String ? jsonDecode(raw) as Map<String, dynamic> : raw as Map;
      final event = data['event']?.toString();
      if (event == 'call.ended' || event == 'call.rejected') {
        await _hangup(remote: true);
        return;
      }
      if (event == 'call.accepted') {
        setState(() => _status = 'Ring answered…');
        if (widget.isCaller) await _createAndSendOffer();
        return;
      }
      if (event != 'signal') return;
      if (data['call_id']?.toString() != widget.callId) return;
      final payload = data['data'] as Map<String, dynamic>? ?? {};
      final type = payload['type']?.toString();
      if (type == 'offer') {
        final sdp = payload['sdp'] as Map<String, dynamic>;
        await _pc!.setRemoteDescription(
          RTCSessionDescription(sdp['sdp'], sdp['type']),
        );
        _remoteDescriptionSet = true;
        await _flushPendingCandidates();
        final answer = await _pc!.createAnswer({
          'offerToReceiveAudio': true,
          'offerToReceiveVideo': widget.video,
        });
        await _pc!.setLocalDescription(answer);
        await ref.read(callsRepositoryProvider).sendSignal(
              channel: _channel!,
              callId: widget.callId,
              toUserId: _peerUserId!,
              data: {'type': 'answer', 'sdp': answer.toMap()},
            );
        setState(() => _status = 'In call');
      } else if (type == 'answer') {
        final sdp = payload['sdp'] as Map<String, dynamic>;
        await _pc!.setRemoteDescription(
          RTCSessionDescription(sdp['sdp'], sdp['type']),
        );
        _remoteDescriptionSet = true;
        await _flushPendingCandidates();
        setState(() => _status = 'In call');
      } else if (type == 'candidate') {
        final c = payload['candidate'] as Map<String, dynamic>;
        final ice = RTCIceCandidate(
          c['candidate'],
          c['sdpMid'],
          c['sdpMLineIndex'],
        );
        if (!_remoteDescriptionSet) {
          _pendingCandidates.add(ice);
        } else {
          await _pc!.addCandidate(ice);
        }
      }
    } catch (e) {
      if (kDebugMode) {
        debugPrint('call signal error: $e');
      }
    }
  }

  Future<void> _toggleMute() async {
    final tracks = _localStream?.getAudioTracks() ?? [];
    if (tracks.isEmpty) return;
    final track = tracks.first;
    track.enabled = !track.enabled;
    setState(() => _muted = !track.enabled);
  }

  Future<void> _toggleCam() async {
    final tracks = _localStream?.getVideoTracks() ?? [];
    if (tracks.isEmpty) return;
    final track = tracks.first;
    track.enabled = !track.enabled;
    setState(() => _camOff = !track.enabled);
  }

  Future<void> _hangup({bool remote = false}) async {
    if (_ending) return;
    _ending = true;
    try {
      if (!remote) {
        await ref.read(callsRepositoryProvider).end(widget.callId);
      }
    } catch (_) {}
    await _cleanup();
    if (mounted) Navigator.of(context).pop();
  }

  Future<void> _cleanup() async {
    await _sub?.cancel();
    await _channel?.sink.close();
    await _localStream?.dispose();
    await _remoteStream?.dispose();
    await _pc?.close();
    await _localRenderer.dispose();
    await _remoteRenderer.dispose();
  }

  @override
  void dispose() {
    _sub?.cancel();
    _channel?.sink.close();
    _localStream?.dispose();
    _pc?.close();
    _localRenderer.dispose();
    _remoteRenderer.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final name = widget.peerName ?? 'Wamu call';
    return Scaffold(
      backgroundColor: const Color(0xFF0A1F18),
      body: SafeArea(
        child: Stack(
          children: [
            if (widget.video) ...[
              Positioned.fill(
                child: _renderersReady
                    ? RTCVideoView(
                        _remoteRenderer,
                        objectFit: RTCVideoViewObjectFit.RTCVideoViewObjectFitCover,
                        placeholderBuilder: (_) => const ColoredBox(
                          color: Color(0xFF0A1F18),
                        ),
                      )
                    : const ColoredBox(color: Color(0xFF0A1F18)),
              ),
              if (!_hasRemoteVideo)
                Positioned.fill(
                  child: IgnorePointer(
                    child: Center(
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          CircleAvatar(
                            radius: 40,
                            backgroundColor: Colors.white12,
                            child: Text(
                              name.isNotEmpty ? name[0].toUpperCase() : '?',
                              style: const TextStyle(fontSize: 32, color: Colors.white),
                            ),
                          ),
                          const SizedBox(height: 12),
                          Text(
                            _status.contains('Connected')
                                ? 'Waiting for $name’s camera…'
                                : _status,
                            style: const TextStyle(color: Colors.white70, fontSize: 14),
                            textAlign: TextAlign.center,
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
            ] else
              Center(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    CircleAvatar(
                      radius: 48,
                      backgroundColor: Theme.of(context).colorScheme.primary,
                      child: Text(
                        name.isNotEmpty ? name[0].toUpperCase() : '?',
                        style: const TextStyle(fontSize: 36, color: Colors.white),
                      ),
                    ),
                    const SizedBox(height: 16),
                    Text(
                      name,
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 22,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const SizedBox(height: 8),
                    Text(_status, style: const TextStyle(color: Colors.white70)),
                  ],
                ),
              ),
            if (widget.video)
              Positioned(
                right: 16,
                top: 16,
                width: 110,
                height: 160,
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(12),
                  child: ColoredBox(
                    color: Colors.black26,
                    child: _renderersReady
                        ? RTCVideoView(
                            _localRenderer,
                            mirror: true,
                            objectFit: RTCVideoViewObjectFit.RTCVideoViewObjectFitCover,
                          )
                        : const SizedBox.shrink(),
                  ),
                ),
              ),
            if (widget.video)
              Positioned(
                left: 16,
                top: 16,
                right: 140,
                child: Text(
                  '$name · $_status',
                  style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w600),
                ),
              ),
            Positioned(
              left: 0,
              right: 0,
              bottom: 32,
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                children: [
                  _RoundBtn(
                    icon: _muted ? Icons.mic_off : Icons.mic,
                    label: _muted ? 'Unmute' : 'Mute',
                    onTap: _toggleMute,
                  ),
                  _RoundBtn(
                    icon: Icons.call_end,
                    label: 'End',
                    color: Colors.red,
                    onTap: () => _hangup(),
                  ),
                  if (widget.video)
                    _RoundBtn(
                      icon: _camOff ? Icons.videocam_off : Icons.videocam,
                      label: _camOff ? 'Cam on' : 'Cam off',
                      onTap: _toggleCam,
                    )
                  else
                    _RoundBtn(
                      icon: Icons.volume_up,
                      label: 'Speaker',
                      onTap: () {},
                    ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _RoundBtn extends StatelessWidget {
  const _RoundBtn({
    required this.icon,
    required this.label,
    required this.onTap,
    this.color,
  });

  final IconData icon;
  final String label;
  final VoidCallback onTap;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        InkWell(
          onTap: onTap,
          customBorder: const CircleBorder(),
          child: CircleAvatar(
            radius: 28,
            backgroundColor: color ?? Colors.white24,
            child: Icon(icon, color: Colors.white),
          ),
        ),
        const SizedBox(height: 6),
        Text(label, style: const TextStyle(color: Colors.white70, fontSize: 12)),
      ],
    );
  }
}
