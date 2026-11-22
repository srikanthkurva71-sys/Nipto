/// Client-side guard for cached Nipto recovery challenges.
/// The recovery server remains authoritative and must enforce its own expiry.
class NiptoRecoveryChallengeGuard {
  static const defaultMaxAge = Duration(minutes: 15);

  /// Validates a cached timestamp string from secure storage.
  /// Invalid or missing values are treated as stale, never as fresh.
  static bool isFreshTimestamp({
    required String? startedAtEpochMs,
    required int nowEpochMs,
    Duration maxAge = defaultMaxAge,
  }) {
    final parsed = int.tryParse(startedAtEpochMs ?? '');
    return isFresh(
      startedAtEpochMs: parsed,
      nowEpochMs: nowEpochMs,
      maxAge: maxAge,
    );
  }

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
