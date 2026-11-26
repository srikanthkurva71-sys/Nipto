import 'dart:async';

import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'nipto_call_signal_validator.dart';
import 'nipto_session_manager.dart';

enum NiptoCallPhase { preparing, ringing, connecting, connected, ended, failed }

class NiptoCallService {
  NiptoCallService({
    required this.callId,
    required this.mediaType,
    required this.isCaller,
    required this.onPhaseChanged,
    required this.onRemoteStream,
    required this.onLocalStream,
    required this.onError,
  });

  final String callId;
  final String mediaType;
  final bool isCaller;
  final void Function(NiptoCallPhase phase) onPhaseChanged;
  final void Function(MediaStream stream) onRemoteStream;
  final void Function(MediaStream stream) onLocalStream;
  final void Function(String message) onError;

  final SupabaseClient _client = Supabase.instance.client;
  final List<RTCIceCandidate> _pendingCandidates = [];
  RealtimeChannel? _channel;
  RTCPeerConnection? _peer;
  MediaStream? _localStream;
  bool _closed = false;
  bool _remoteDescriptionSet = false;
  Future<void> _signalQueue = Future<void>.value();
  Timer? _ringTimeout;
  Timer? _connectTimeout;
  Timer? _disconnectTimeout;
  Timer? _readyRetryTimer;
  Completer<void>? _remoteReady;

  Future<void> startOutgoing() async {
    try {
      onPhaseChanged(NiptoCallPhase.preparing);
      _remoteReady = Completer<void>();
      await _prepareMediaAndChannel();
      if (_closed) return;
      await _remoteReady!.future.timeout(const Duration(seconds: 20));
      if (_closed) return;
      final offer = await _peer!.createOffer({
        'offerToReceiveAudio': true,
        'offerToReceiveVideo': mediaType == 'video',
      });
      await _peer!.setLocalDescription(offer);
      await _sendSignal({
        'type': 'offer',
        'sdp': offer.sdp,
        'sdpType': offer.type,
      });
      onPhaseChanged(NiptoCallPhase.ringing);
      _ringTimeout = Timer(const Duration(seconds: 45), () {
        if (!_closed && !isConnected) unawaited(end(reason: 'failed'));
      });
    } catch (error) {
      onError(_safeMessage(error));
      onPhaseChanged(NiptoCallPhase.failed);
      await end(reason: 'failed');
    }
  }

  Future<void> acceptIncoming() async {
    try {
      onPhaseChanged(NiptoCallPhase.preparing);
      await _client.rpc('accept_nipto_call', params: {'p_call_id': callId});
      if (_closed) return;
      await _prepareMediaAndChannel();
      if (_closed) return;
      await _sendSignal({'type': 'ready'});
      // Re-broadcast readiness briefly: private Realtime broadcasts are not
      // durable, so the caller may not have subscribed when the first signal lands.
      _readyRetryTimer?.cancel();
      var readyAttempts = 0;
      _readyRetryTimer = Timer.periodic(const Duration(seconds: 1), (timer) {
        if (_closed || _remoteDescriptionSet || readyAttempts >= 15) {
          timer.cancel();
          return;
        }
        readyAttempts += 1;
        unawaited(_sendSignal({'type': 'ready'}).catchError((Object _) {}));
      });
      onPhaseChanged(NiptoCallPhase.connecting);
    } catch (error) {
      onError(_safeMessage(error));
      onPhaseChanged(NiptoCallPhase.failed);
      try {
        await _client.rpc(
          'end_nipto_call',
          params: {
            'p_call_id': callId,
            'p_reason': error.toString().toLowerCase().contains('permission')
                ? 'permission_denied'
                : 'failed',
          },
        );
      } catch (_) {
        // The call may already have expired or been ended by the caller.
      }
      await dispose();
    }
  }

  Future<void> _prepareMediaAndChannel() async {
    final joined = Completer<void>();
    final channel = _client.channel(
      'nipto-call:$callId',
      opts: const RealtimeChannelConfig(private: true),
    );
    _channel = channel;
    channel.onBroadcast(event: 'signal', callback: _handleSignal);
    channel.subscribe((status, error) {
      if (_closed || joined.isCompleted) return;
      if (status == RealtimeSubscribeStatus.subscribed) {
        joined.complete();
      } else if (status == RealtimeSubscribeStatus.channelError ||
          status == RealtimeSubscribeStatus.timedOut) {
        joined.completeError(StateError('Secure call signaling unavailable.'));
      }
    });
    await joined.future.timeout(const Duration(seconds: 15));
    if (_closed) return;

    final iceServers = await NiptoSessionManager.instance.getIceServers();
    final hasTurnRelay = iceServers.any((server) {
      final urls = server['urls'];
      if (urls is String)
        return urls.startsWith('turn:') || urls.startsWith('turns:');
      if (urls is List) {
        return urls.whereType<String>().any(
          (url) => url.startsWith('turn:') || url.startsWith('turns:'),
        );
      }
      return false;
    });
    if (!hasTurnRelay) {
      throw StateError('Nipto calling relay is not configured yet.');
    }
    final peer = await createPeerConnection({
      'sdpSemantics': 'unified-plan',
      'iceServers': iceServers,
    });
    if (_closed) {
      await peer.close();
      return;
    }
    _peer = peer;
    _peer!.onIceCandidate = (candidate) {
      if (_closed || candidate.candidate == null) return;
      unawaited(
        _sendIceSignal({
          'type': 'ice',
          'candidate': candidate.candidate,
          'sdpMid': candidate.sdpMid,
          'sdpMLineIndex': candidate.sdpMLineIndex,
        }),
      );
    };
    _peer!.onTrack = (event) {
      if (event.streams.isNotEmpty) onRemoteStream(event.streams.first);
    };
    _peer!.onConnectionState = (state) {
      if (_closed) return;
      if (state == RTCPeerConnectionState.RTCPeerConnectionStateConnected) {
        _ringTimeout?.cancel();
        _connectTimeout?.cancel();
        _disconnectTimeout?.cancel();
        onPhaseChanged(NiptoCallPhase.connected);
      } else if (state == RTCPeerConnectionState.RTCPeerConnectionStateFailed) {
        onError(
          'The call connection failed. Check your network and try again.',
        );
        onPhaseChanged(NiptoCallPhase.failed);
        unawaited(end(reason: 'connection_lost'));
      } else if (state ==
          RTCPeerConnectionState.RTCPeerConnectionStateDisconnected) {
        onPhaseChanged(NiptoCallPhase.connecting);
        _disconnectTimeout?.cancel();
        _disconnectTimeout = Timer(const Duration(seconds: 10), () {
          if (!_closed && !isConnected) {
            onError('The call lost its network connection.');
            onPhaseChanged(NiptoCallPhase.failed);
            unawaited(end(reason: 'connection_lost'));
          }
        });
      }
    };

    final stream = await navigator.mediaDevices.getUserMedia({
      'audio': true,
      'video': mediaType == 'video'
          ? {
              'facingMode': 'user',
              'width': {'ideal': 1280},
              'height': {'ideal': 720},
            }
          : false,
    });
    if (_closed) {
      for (final track in stream.getTracks()) {
        await track.stop();
      }
      await stream.dispose();
      return;
    }
    _localStream = stream;
    onLocalStream(stream);
    for (final track in stream.getTracks()) {
      await _peer!.addTrack(track, stream);
    }
  }

  bool get isConnected =>
      _peer?.connectionState ==
      RTCPeerConnectionState.RTCPeerConnectionStateConnected;

  void _armConnectTimeout() {
    _connectTimeout?.cancel();
    _connectTimeout = Timer(const Duration(seconds: 30), () {
      if (!_closed && !isConnected) {
        onError(
          'The call could not connect. Check your network and try again.',
        );
        onPhaseChanged(NiptoCallPhase.failed);
        unawaited(end(reason: 'connection_lost'));
      }
    });
  }

  void _handleSignal(Map<String, dynamic> message) {
    _signalQueue = _signalQueue.then((_) => _processSignal(message)).catchError(
      (_) {
        onError('A call signaling message could not be processed.');
        onPhaseChanged(NiptoCallPhase.failed);
      },
    );
  }

  Future<void> _processSignal(Map<String, dynamic> message) async {
    if (_closed) return;
    final payload = message['payload'];
    if (payload is! Map) return;
    try {
      final type = payload['type'];
      if (type == 'ready' && isCaller) {
        if (!(_remoteReady?.isCompleted ?? true)) _remoteReady!.complete();
      } else if (type == 'offer' && !isCaller) {
        if (!NiptoCallSignalValidator.isDescriptionPayload(payload, 'offer'))
          return;
        final sdp = payload['sdp'] as String;
        await _peer!.setRemoteDescription(RTCSessionDescription(sdp, 'offer'));
        _remoteDescriptionSet = true;
        _readyRetryTimer?.cancel();
        await _flushCandidates();
        final answer = await _peer!.createAnswer({
          'offerToReceiveAudio': true,
          'offerToReceiveVideo': mediaType == 'video',
        });
        await _peer!.setLocalDescription(answer);
        await _sendSignal({
          'type': 'answer',
          'sdp': answer.sdp,
          'sdpType': answer.type,
        });
        _armConnectTimeout();
        onPhaseChanged(NiptoCallPhase.connecting);
      } else if (type == 'answer' && isCaller) {
        if (!NiptoCallSignalValidator.isDescriptionPayload(payload, 'answer'))
          return;
        final sdp = payload['sdp'] as String;
        await _peer!.setRemoteDescription(RTCSessionDescription(sdp, 'answer'));
        _remoteDescriptionSet = true;
        await _flushCandidates();
        _ringTimeout?.cancel();
        _armConnectTimeout();
        onPhaseChanged(NiptoCallPhase.connecting);
      } else if (type == 'ice') {
        if (!NiptoCallSignalValidator.isIceCandidatePayload(payload)) return;
        final candidate = payload['candidate'] as String;
        if (!_remoteDescriptionSet &&
            !NiptoCallSignalValidator.canQueueIceCandidate(
              _pendingCandidates.length,
            ))
          return;
        final index = payload['sdpMLineIndex'];
        final ice = RTCIceCandidate(
          candidate,
          payload['sdpMid'] as String?,
          index is num ? index.toInt() : null,
        );
        if (_remoteDescriptionSet) {
          await _peer!.addCandidate(ice);
        } else {
          _pendingCandidates.add(ice);
        }
      } else if (type == 'hangup' || type == 'decline') {
        onPhaseChanged(NiptoCallPhase.ended);
        await dispose();
      }
    } catch (_) {
      onError('A call signaling message could not be processed.');
      onPhaseChanged(NiptoCallPhase.failed);
    }
  }

  Future<void> _flushCandidates() async {
    for (final candidate in List<RTCIceCandidate>.from(_pendingCandidates)) {
      await _peer!.addCandidate(candidate);
    }
    _pendingCandidates.clear();
  }

  Future<void> _sendIceSignal(Map<String, dynamic> payload) async {
    try {
      await _sendSignal(payload);
    } catch (_) {
      // A later ICE candidate or connection timeout will surface network failure.
    }
  }

  Future<void> _sendSignal(Map<String, dynamic> payload) async {
    final channel = _channel;
    if (_closed || channel == null) return;
    await channel.sendBroadcastMessage(event: 'signal', payload: payload);
  }

  Future<void> setMicrophoneEnabled(bool enabled) async {
    for (final track
        in _localStream?.getAudioTracks() ?? <MediaStreamTrack>[]) {
      track.enabled = enabled;
    }
  }

  Future<void> setCameraEnabled(bool enabled) async {
    for (final track
        in _localStream?.getVideoTracks() ?? <MediaStreamTrack>[]) {
      track.enabled = enabled;
    }
  }

  Future<void> setSpeakerphoneEnabled(bool enabled) async {
    await Helper.setSpeakerphoneOn(enabled);
  }

  Future<void> switchCamera() async {
    final tracks = _localStream?.getVideoTracks() ?? <MediaStreamTrack>[];
    if (tracks.isNotEmpty) await Helper.switchCamera(tracks.first);
  }

  Future<void> end({String reason = 'hangup'}) async {
    if (_closed) return;
    _ringTimeout?.cancel();
    _connectTimeout?.cancel();
    _disconnectTimeout?.cancel();
    try {
      await _sendSignal({'type': 'hangup'});
    } catch (_) {
      // Backend call control must still run if realtime signaling is unavailable.
    }
    try {
      await _client.rpc(
        'end_nipto_call',
        params: {'p_call_id': callId, 'p_reason': reason},
      );
    } catch (_) {
      // The session may already be terminal or the network may be unavailable.
    } finally {
      onPhaseChanged(NiptoCallPhase.ended);
      await dispose();
    }
  }

  Future<void> dispose() async {
    if (_closed) return;
    _closed = true;
    _ringTimeout?.cancel();
    _connectTimeout?.cancel();
    _disconnectTimeout?.cancel();
    _readyRetryTimer?.cancel();

    final channel = _channel;
    _channel = null;
    if (channel != null) {
      try {
        await _client.removeChannel(channel);
      } catch (_) {
        // Continue releasing local media if realtime teardown fails.
      }
    }

    final peer = _peer;
    _peer = null;
    if (peer != null) {
      try {
        await peer.close();
      } catch (_) {
        // Continue cleanup; native peer teardown can fail during process shutdown.
      }
    }

    final stream = _localStream;
    _localStream = null;
    if (stream != null) {
      for (final track in stream.getTracks()) {
        try {
          await track.stop();
        } catch (_) {
          // Stop remaining tracks even if one native track fails.
        }
      }
      try {
        await stream.dispose();
      } catch (_) {
        // Stream disposal is best-effort after every track has been stopped.
      }
    }

    try {
      await Helper.clearAndroidCommunicationDevice();
    } catch (_) {
      // Audio routing cleanup is best-effort across supported Android versions.
    }
  }

  String _safeMessage(Object error) {
    final text = error.toString().toLowerCase();
    if (text.contains('permission') || text.contains('denied')) {
      return 'Allow microphone access${mediaType == 'video' ? ' and camera access' : ''} to place this call.';
    }
    if (text.contains('already active') || text.contains('call limit')) {
      return error.toString().replaceFirst('Exception: ', '');
    }
    return 'The call could not be connected. Please try again.';
  }
}
