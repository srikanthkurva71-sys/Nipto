import 'dart:async';

import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

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
  Completer<void>? _remoteReady;

  static const Map<String, dynamic> _rtcConfiguration = {
    'sdpSemantics': 'unified-plan',
    'iceServers': [
      {'urls': 'stun:stun.l.google.com:19302'},
    ],
  };

  Future<void> startOutgoing() async {
    try {
      onPhaseChanged(NiptoCallPhase.preparing);
      _remoteReady = Completer<void>();
      await _prepareMediaAndChannel();
      await _remoteReady!.future.timeout(const Duration(seconds: 20));
      final offer = await _peer!.createOffer({
        'offerToReceiveAudio': true,
        'offerToReceiveVideo': mediaType == 'video',
      });
      await _peer!.setLocalDescription(offer);
      await _sendSignal({'type': 'offer', 'sdp': offer.sdp, 'sdpType': offer.type});
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
      await _prepareMediaAndChannel();
      await _sendSignal({'type': 'ready'});
      onPhaseChanged(NiptoCallPhase.connecting);
    } catch (error) {
      onError(_safeMessage(error));
      onPhaseChanged(NiptoCallPhase.failed);
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

    _peer = await createPeerConnection(_rtcConfiguration);
    _peer!.onIceCandidate = (candidate) {
      if (_closed || candidate.candidate == null) return;
      unawaited(_sendIceSignal({
        'type': 'ice',
        'candidate': candidate.candidate,
        'sdpMid': candidate.sdpMid,
        'sdpMLineIndex': candidate.sdpMLineIndex,
      }));
    };
    _peer!.onTrack = (event) {
      if (event.streams.isNotEmpty) onRemoteStream(event.streams.first);
      _ringTimeout?.cancel();
      _connectTimeout?.cancel();
      onPhaseChanged(NiptoCallPhase.connected);
    };
    _peer!.onConnectionState = (state) {
      if (_closed) return;
      if (state == RTCPeerConnectionState.RTCPeerConnectionStateConnected) {
        _ringTimeout?.cancel();
        _connectTimeout?.cancel();
        onPhaseChanged(NiptoCallPhase.connected);
      } else if (state == RTCPeerConnectionState.RTCPeerConnectionStateFailed) {
        onError('The call connection failed. Check your network and try again.');
        onPhaseChanged(NiptoCallPhase.failed);
        unawaited(end(reason: 'connection_lost'));
      } else if (state == RTCPeerConnectionState.RTCPeerConnectionStateDisconnected) {
        onPhaseChanged(NiptoCallPhase.connecting);
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
    _localStream = stream;
    onLocalStream(stream);
    for (final track in stream.getTracks()) {
      await _peer!.addTrack(track, stream);
    }
  }

  bool get isConnected => _peer?.connectionState ==
      RTCPeerConnectionState.RTCPeerConnectionStateConnected;

  void _armConnectTimeout() {
    _connectTimeout?.cancel();
    _connectTimeout = Timer(const Duration(seconds: 30), () {
      if (!_closed && !isConnected) {
        onError('The call could not connect. Check your network and try again.');
        onPhaseChanged(NiptoCallPhase.failed);
        unawaited(end(reason: 'connection_lost'));
      }
    });
  }

  void _handleSignal(Map<String, dynamic> message) {
    _signalQueue = _signalQueue.then((_) => _processSignal(message)).catchError((_) {
      onError('A call signaling message could not be processed.');
      onPhaseChanged(NiptoCallPhase.failed);
    });
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
        final sdp = payload['sdp'];
        final sdpType = payload['sdpType'];
        if (sdp is! String || sdpType is! String) return;
        await _peer!.setRemoteDescription(RTCSessionDescription(sdp, sdpType));
        _remoteDescriptionSet = true;
        await _flushCandidates();
        final answer = await _peer!.createAnswer({
          'offerToReceiveAudio': true,
          'offerToReceiveVideo': mediaType == 'video',
        });
        await _peer!.setLocalDescription(answer);
        await _sendSignal({'type': 'answer', 'sdp': answer.sdp, 'sdpType': answer.type});
        _armConnectTimeout();
        onPhaseChanged(NiptoCallPhase.connecting);
      } else if (type == 'answer' && isCaller) {
        final sdp = payload['sdp'];
        final sdpType = payload['sdpType'];
        if (sdp is! String || sdpType is! String) return;
        await _peer!.setRemoteDescription(RTCSessionDescription(sdp, sdpType));
        _remoteDescriptionSet = true;
        await _flushCandidates();
        _ringTimeout?.cancel();
        _armConnectTimeout();
        onPhaseChanged(NiptoCallPhase.connecting);
      } else if (type == 'ice') {
        final candidate = payload['candidate'];
        if (candidate is! String) return;
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
    for (final track in _localStream?.getAudioTracks() ?? <MediaStreamTrack>[]) {
      track.enabled = enabled;
    }
  }

  Future<void> setCameraEnabled(bool enabled) async {
    for (final track in _localStream?.getVideoTracks() ?? <MediaStreamTrack>[]) {
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
    try {
      await _sendSignal({'type': 'hangup'});
      await _client.rpc('end_nipto_call', params: {
        'p_call_id': callId,
        'p_reason': reason,
      });
    } catch (_) {
      // Release local media even if the network is unavailable.
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
    final channel = _channel;
    _channel = null;
    if (channel != null) await _client.removeChannel(channel);
    final peer = _peer;
    _peer = null;
    if (peer != null) await peer.close();
    final stream = _localStream;
    _localStream = null;
    if (stream != null) {
      for (final track in stream.getTracks()) {
        await track.stop();
      }
      await stream.dispose();
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
