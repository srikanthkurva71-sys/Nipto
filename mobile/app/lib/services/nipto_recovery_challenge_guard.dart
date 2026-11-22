/// Client-side guard for cached Nipto recovery challenges.
/// The recovery server remains authoritative and must enforce its own expiry.
class NiptoRecoveryChallengeGuard {
  static const defaultMaxAge = Duration(minutes: 15);

  static bool isFresh({
    required int? startedAtEpochMs,
    required int nowEpochMs,
    Duration maxAge = defaultMaxAge,
  }) {
    if (startedAtEpochMs == null ||
        startedAtEpochMs <= 0 ||
        nowEpochMs <= 0 ||
        maxAge <= Duration.zero) {
      return false;
    }
    final ageMs = nowEpochMs - startedAtEpochMs;
    if (ageMs < 0) return false; // reject future-dated local timestamps
    return ageMs <= maxAge.inMilliseconds;
  }
}
