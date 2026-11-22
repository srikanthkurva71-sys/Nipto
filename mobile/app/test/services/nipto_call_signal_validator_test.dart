import 'package:flutter_test/flutter_test.dart';
import 'package:nipto/services/nipto_call_signal_validator.dart';

void main() {
  group('NiptoCallSignalValidator', () {
    test('accepts offer and answer payloads', () {
      expect(
        NiptoCallSignalValidator.isDescriptionPayload(
          {'sdp': 'v=0\\r\\n', 'sdpType': 'offer'},
          'offer',
        ),
        isTrue,
      );
      expect(
        NiptoCallSignalValidator.isDescriptionPayload(
          {'sdp': 'v=0\\r\\n', 'sdpType': 'answer'},
          'answer',
        ),
        isTrue,
      );
    });

    test('rejects empty, oversized, and mismatched SDP descriptions', () {
      expect(
        NiptoCallSignalValidator.isDescriptionPayload(
          {'sdp': '', 'sdpType': 'offer'},
          'offer',
        ),
        isFalse,
      );
      expect(
        NiptoCallSignalValidator.isDescriptionPayload(
          {'sdp': List.filled(NiptoCallSignalValidator.maxSdpLength, 'x').join(), 'sdpType': 'offer'},
          'offer',
        ),
        isTrue,
      );
      expect(
        NiptoCallSignalValidator.isDescriptionPayload(
          {'sdp': List.filled(NiptoCallSignalValidator.maxSdpLength + 1, 'x').join(), 'sdpType': 'offer'},
          'offer',
        ),
        isFalse,
      );
      expect(
        NiptoCallSignalValidator.isDescriptionPayload(
          {'sdp': 'v=0', 'sdpType': 'answer'},
          'offer',
        ),
        isFalse,
      );
    });

    test('validates ICE candidate strings and optional mid', () {
      expect(
        NiptoCallSignalValidator.isIceCandidatePayload(
          {'candidate': 'candidate:1 1 UDP 1 127.0.0.1 9 typ host', 'sdpMid': '0'},
        ),
        isTrue,
      );
      expect(NiptoCallSignalValidator.isIceCandidatePayload({'candidate': ''}), isFalse);
      expect(
        NiptoCallSignalValidator.isIceCandidatePayload(
          {'candidate': List.filled(NiptoCallSignalValidator.maxIceCandidateLength + 1, 'x').join()},
        ),
        isFalse,
      );
      expect(
        NiptoCallSignalValidator.isIceCandidatePayload(
          {'candidate': 'candidate', 'sdpMid': List.filled(NiptoCallSignalValidator.maxSdpMidLength + 1, 'x').join()},
        ),
        isFalse,
      );
    });

    test('validates ICE line indices as bounded non-negative integers', () {
      expect(
        NiptoCallSignalValidator.isIceCandidatePayload(
          {'candidate': 'candidate', 'sdpMLineIndex': 0},
        ),
        isTrue,
      );
      for (final invalid in [-1, 65536, 1.5, double.nan, double.infinity, '2']) {
        expect(
          NiptoCallSignalValidator.isIceCandidatePayload(
            {'candidate': 'candidate', 'sdpMLineIndex': invalid},
          ),
          isFalse,
          reason: 'Expected line index $invalid to be rejected',
        );
      }
    });

    test('limits ICE candidate queue size', () {
      expect(NiptoCallSignalValidator.canQueueIceCandidate(0), isTrue);
      expect(
        NiptoCallSignalValidator.canQueueIceCandidate(
          NiptoCallSignalValidator.maxQueuedIceCandidates - 1,
        ),
        isTrue,
      );
      expect(
        NiptoCallSignalValidator.canQueueIceCandidate(
          NiptoCallSignalValidator.maxQueuedIceCandidates,
        ),
        isFalse,
      );
      expect(NiptoCallSignalValidator.canQueueIceCandidate(-1), isFalse);
    });
  });
}
