import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';

import '../services/nipto_call_service.dart';
import '../theme/nipto_theme.dart';

class CallScreen extends StatefulWidget {
  const CallScreen({
    super.key,
    required this.callId,
    required this.mediaType,
    required this.isCaller,
    required this.peerTitle,
  });

  final String callId;
  final String mediaType;
  final bool isCaller;
  final String peerTitle;

  @override
  State<CallScreen> createState() => _CallScreenState();
}

class _CallScreenState extends State<CallScreen> {
  final RTCVideoRenderer _localRenderer = RTCVideoRenderer();
  final RTCVideoRenderer _remoteRenderer = RTCVideoRenderer();
  late final NiptoCallService _service;
  NiptoCallPhase _phase = NiptoCallPhase.preparing;
  bool _microphoneEnabled = true;
  bool _cameraEnabled = true;
  bool _speakerEnabled = false;
  bool _renderersReady = false;
  String? _error;
  bool _ending = false;
  bool _allowPop = false;
  Timer? _durationTicker;
  DateTime? _connectedAt;
  Duration _callDuration = Duration.zero;

  @override
  void initState() {
    super.initState();
    _speakerEnabled = widget.mediaType == 'video';
    _service = NiptoCallService(
      callId: widget.callId,
      mediaType: widget.mediaType,
      isCaller: widget.isCaller,
      onPhaseChanged: (phase) {
        if (!mounted) return;
        if (phase == NiptoCallPhase.connected && _connectedAt == null) {
          _connectedAt = DateTime.now();
          _durationTicker = Timer.periodic(const Duration(seconds: 1), (_) {
            if (!mounted || _connectedAt == null) return;
            setState(() => _callDuration = DateTime.now().difference(_connectedAt!));
          });
        }
        if (phase == NiptoCallPhase.ended || phase == NiptoCallPhase.failed) {
          _durationTicker?.cancel();
        }
        setState(() => _phase = phase);
      },
      onRemoteStream: (stream) {
        _remoteRenderer.srcObject = stream;
        if (mounted) setState(() {});
      },
      onLocalStream: (stream) {
        _localRenderer.srcObject = stream;
        if (mounted) setState(() {});
      },
      onError: (message) {
        if (mounted) setState(() => _error = message);
      },
    );
    unawaited(_initializeAndConnect());
  }

  Future<void> _initializeAndConnect() async {
    try {
      await _localRenderer.initialize();
      await _remoteRenderer.initialize();
      if (!mounted) return;
      setState(() => _renderersReady = true);
      if (_speakerEnabled) await _service.setSpeakerphoneEnabled(true);
      if (widget.isCaller) {
        await _service.startOutgoing();
      } else {
        await _service.acceptIncoming();
      }
    } catch (_) {
      if (mounted) {
        setState(() {
          _error = 'Camera or microphone could not be initialized.';
          _phase = NiptoCallPhase.failed;
        });
      }
      await _service.end(reason: 'failed');
    }
  }

  String get _durationLabel {
    final minutes = _callDuration.inMinutes.toString().padLeft(2, '0');
    final seconds = (_callDuration.inSeconds % 60).toString().padLeft(2, '0');
    return '$minutes:$seconds';
  }

  String get _phaseLabel {
    switch (_phase) {
      case NiptoCallPhase.preparing:
        return 'Preparing secure call…';
      case NiptoCallPhase.ringing:
        return 'Calling…';
      case NiptoCallPhase.connecting:
        return 'Connecting…';
      case NiptoCallPhase.connected:
        return 'Connected';
      case NiptoCallPhase.ended:
        return 'Call ended';
      case NiptoCallPhase.failed:
        return 'Call unavailable';
    }
  }

  Future<void> _toggleMicrophone() async {
    final next = !_microphoneEnabled;
    await _service.setMicrophoneEnabled(next);
    if (mounted) setState(() => _microphoneEnabled = next);
  }

  Future<void> _toggleSpeaker() async {
    final next = !_speakerEnabled;
    await _service.setSpeakerphoneEnabled(next);
    if (mounted) setState(() => _speakerEnabled = next);
  }

  Future<void> _toggleCamera() async {
    final next = !_cameraEnabled;
    await _service.setCameraEnabled(next);
    if (mounted) setState(() => _cameraEnabled = next);
  }

  Future<void> _endCall() async {
    if (_ending) return;
    _ending = true;
    await _service.end(
      reason: _phase == NiptoCallPhase.failed ? 'failed' : 'hangup',
    );
    if (mounted) {
      setState(() => _allowPop = true);
      await WidgetsBinding.instance.endOfFrame;
      if (mounted) Navigator.of(context).pop();
    }
  }

  @override
  void dispose() {
    _durationTicker?.cancel();
    unawaited(_service.dispose());
    _localRenderer.dispose();
    _remoteRenderer.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final isVideo = widget.mediaType == 'video';
    final connected = _phase == NiptoCallPhase.connected;
    return PopScope<void>(
      canPop: _allowPop,
      onPopInvokedWithResult: (didPop, result) {
        if (!didPop) unawaited(_endCall());
      },
      child: Scaffold(
      backgroundColor: const Color(0xFF101323),
      appBar: AppBar(
        backgroundColor: const Color(0xFF101323),
        foregroundColor: Colors.white,
        title: Text(widget.peerTitle),
        actions: [
          if (isVideo)
            IconButton(
              tooltip: 'Switch camera',
              onPressed: _renderersReady ? _service.switchCamera : null,
              icon: const Icon(Icons.cameraswitch_outlined),
            ),
        ],
      ),
      body: SafeArea(
        child: Column(
          children: [
            Expanded(
              child: Stack(
                fit: StackFit.expand,
                children: [
                  if (isVideo && _remoteRenderer.srcObject != null)
                    RTCVideoView(
                      _remoteRenderer,
                      objectFit: RTCVideoViewObjectFit.RTCVideoViewObjectFitCover,
                    )
                  else
                    Center(
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          CircleAvatar(
                            radius: 48,
                            backgroundColor: NiptoColors.violet,
                            child: Text(
                              widget.peerTitle.isEmpty
                                  ? 'N'
                                  : widget.peerTitle.characters.first.toUpperCase(),
                              style: const TextStyle(
                                color: Colors.white,
                                fontSize: 34,
                                fontWeight: FontWeight.w800,
                              ),
                            ),
                          ),
                          const SizedBox(height: 22),
                          Text(
                            _phaseLabel,
                            style: const TextStyle(color: Colors.white, fontSize: 17),
                          ),
                        ],
                      ),
                    ),
                  if (isVideo && _localRenderer.srcObject != null)
                    Positioned(
                      right: 16,
                      top: 16,
                      width: 112,
                      height: 158,
                      child: ClipRRect(
                        borderRadius: BorderRadius.circular(16),
                        child: RTCVideoView(
                          _localRenderer,
                          mirror: true,
                          objectFit: RTCVideoViewObjectFit.RTCVideoViewObjectFitCover,
                        ),
                      ),
                    ),
                  if (_error != null)
                    Positioned(
                      left: 20,
                      right: 20,
                      bottom: 20,
                      child: DecoratedBox(
                        decoration: BoxDecoration(
                          color: Colors.red.shade900.withValues(alpha: 0.9),
                          borderRadius: BorderRadius.circular(12),
                        ),
                        child: Padding(
                          padding: const EdgeInsets.all(12),
                          child: Text(
                            _error!,
                            textAlign: TextAlign.center,
                            style: const TextStyle(color: Colors.white),
                          ),
                        ),
                      ),
                    ),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(22, 20, 22, 24),
              child: Column(
                children: [
                  Text(
                    connected ? _durationLabel : _phaseLabel,
                    style: const TextStyle(color: Colors.white70, fontSize: 14),
                  ),
                  const SizedBox(height: 22),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                    children: [
                      _CallControl(
                        icon: _microphoneEnabled ? Icons.mic_rounded : Icons.mic_off_rounded,
                        label: _microphoneEnabled ? 'Mute' : 'Unmute',
                        onPressed: _toggleMicrophone,
                      ),
                      if (isVideo)
                        _CallControl(
                          icon: _cameraEnabled
                              ? Icons.videocam_rounded
                              : Icons.videocam_off_rounded,
                          label: _cameraEnabled ? 'Camera off' : 'Camera on',
                          onPressed: _toggleCamera,
                        ),
                      _CallControl(
                        icon: _speakerEnabled ? Icons.volume_up_rounded : Icons.hearing_rounded,
                        label: _speakerEnabled ? 'Speaker' : 'Earpiece',
                        onPressed: _toggleSpeaker,
                      ),
                      _CallControl(
                        icon: Icons.call_end_rounded,
                        label: 'End',
                        background: Colors.red,
                        onPressed: _endCall,
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
      ));
  }
}

class _CallControl extends StatelessWidget {
  const _CallControl({
    required this.icon,
    required this.label,
    required this.onPressed,
    this.background = const Color(0xFF30364A),
  });

  final IconData icon;
  final String label;
  final Future<void> Function() onPressed;
  final Color background;

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Material(
          color: background,
          shape: const CircleBorder(),
          child: IconButton(
            onPressed: onPressed,
            icon: Icon(icon, color: Colors.white),
            iconSize: 27,
            padding: const EdgeInsets.all(17),
          ),
        ),
        const SizedBox(height: 8),
        Text(label, style: const TextStyle(color: Colors.white70, fontSize: 12)),
      ],
    );
  }
}
