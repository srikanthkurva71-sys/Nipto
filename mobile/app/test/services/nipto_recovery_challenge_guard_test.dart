import 'package:flutter_test/flutter_test.dart';
import 'package:nipto/services/nipto_recovery_challenge_guard.dart';

void main() {
  group('NiptoRecoveryChallengeGuard', () {
    const now = 1800000000000;

    test('accepts fresh timestamps', () {
      expect(NiptoRecoveryChallengeGuard.isFresh(
        startedAtEpochMs: now - const Duration(minutes: 2).inMilliseconds,
        nowEpochMs: now,
      ), isTrue);
    });

    test('accepts the exact expiry boundary', () {
      expect(NiptoRecoveryChallengeGuard.isFresh(
        startedAtEpochMs: now - const Duration(minutes: 15).inMilliseconds,
        nowEpochMs: now,
      ), isTrue);
    });

    test('rejects expired timestamps', () {
      expect(NiptoRecoveryChallengeGuard.isFresh(
        startedAtEpochMs: now - const Duration(minutes: 15, milliseconds: 1).inMilliseconds,
        nowEpochMs: now,
      ), isFalse);
    });

    test('rejects future, missing, and invalid timestamps', () {
      expect(NiptoRecoveryChallengeGuard.isFresh(startedAtEpochMs: now + 1, nowEpochMs: now), isFalse);
      expect(NiptoRecoveryChallengeGuard.isFresh(startedAtEpochMs: null, nowEpochMs: now), isFalse);
      expect(NiptoRecoveryChallengeGuard.isFresh(startedAtEpochMs: 0, nowEpochMs: now), isFalse);
      expect(NiptoRecoveryChallengeGuard.isFresh(startedAtEpochMs: now - 1, nowEpochMs: 0), isFalse);
    });

    test('rejects non-positive maximum age', () {
      expect(NiptoRecoveryChallengeGuard.isFresh(
        startedAtEpochMs: now - 1,
        nowEpochMs: now,
        maxAge: Duration.zero,
      ), isFalse);
    });
  });
}
