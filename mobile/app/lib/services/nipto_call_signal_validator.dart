/// Validates untrusted WebRTC signaling payloads before passing them to
/// the native WebRTC implementation.
class NiptoCallSignalValidator {
  NiptoCallSignalValidator._();

  static const int maxSdpLength = 65536;
  static const int maxIceCandidateLength = 4096;
  static const int maxSdpMidLength = 128;
  static const int maxQueuedIceCandidates = 256;

  static bool isDescriptionPayload(
    Map<dynamic, dynamic> payload,
    String expectedType,
  ) {
    final sdp = payload['sdp'];
    return sdp is String &&
        sdp.trim().isNotEmpty &&
        sdp.length <= maxSdpLength &&
        payload['sdpType'] == expectedType;
  }

  static bool isIceCandidatePayload(Map payload) {
    final candidate = payload['candidate'];
    if (candidate is! String ||
        candidate.trim().isEmpty ||
        candidate.length > maxIceCandidateLength) {
      return false;
    }

    final sdpMid = payload['sdpMid'];
    if (sdpMid != null &&
        (sdpMid is! String ||
            sdpMid.length > maxSdpMidLength ||
            sdpMid.trim().isEmpty)) {
      return false;
    }

    final lineIndex = payload['sdpMLineIndex'];
    if (lineIndex != null &&
        (lineIndex is! num ||
            !lineIndex.isFinite ||
            lineIndex < 0 ||
            lineIndex > 65535 ||
            lineIndex != lineIndex.roundToDouble())) {
      return false;
    }

    return true;
  }

  static bool canQueueIceCandidate(int currentCount) =>
      currentCount >= 0 && currentCount < maxQueuedIceCandidates;
}
