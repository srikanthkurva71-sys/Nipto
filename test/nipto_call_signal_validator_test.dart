import 'package:flutter_test/flutter_test.dart';
import 'package:nipto/services/nipto_call_signal_validator.dart';

void main() {
  group('NiptoCallSignalValidator', () {
    test('accepts bounded offer and answer descriptions', () {
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

    test('rejects empty, oversized or mismatched SDP descriptions', () {
      expect(
        NiptoCallSignalValidator.isDescriptionPayload(
          {'sdp': '', 'sdpType': 'offer'},
          'offer',
        ),
        isFalse,
      );
      expect(
        NiptoCallSignalValidator.isDescriptionPayload(
          {
            'sdp': List<String>.filled(NiptoCallSignalValidator.maxSdpLength + 1, 'x').join(),
            'sdpType': 'offer',
          },
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

    test('accepts a valid ICE candidate', () {
      expect(
        NiptoCallSignalValidator.isIceCandidatePayload({
          'candidate': 'candidate:1 1 UDP 123 192.0.2.1 5000 typ host',
          'sdpMid': '0',
          'sdpMLineIndex': 0,
        }),
        isTrue,
      );
    });

    test('rejects malformed and oversized ICE candidates', () {
      expect(
        NiptoCallSignalValidator.isIceCandidatePayload({'candidate': ''}),
        isFalse,
      );
      expect(
        NiptoCallSignalValidator.isIceCandidatePayload({
          'candidate': List<String>.filled(NiptoCallSignalValidator.maxIceCandidateLength + 1, 'x').join(),
        }),
        isFalse,
      );
      expect(
        NiptoCallSignalValidator.isIceCandidatePayload({
          'candidate': 'candidate:1',
          'sdpMLineIndex': -1,
        }),
        isFalse,
      );
      expect(
        NiptoCallSignalValidator.isIceCandidatePayload({
          'candidate': 'candidate:1',
          'sdpMid': List<String>.filled(NiptoCallSignalValidator.maxSdpMidLength + 1, 'x').join(),
        }),
        isFalse,
      );
    });

    test('bounds the pending ICE queue', () {
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
