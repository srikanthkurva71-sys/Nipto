import 'package:flutter_test/flutter.dart';
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

    test('parses valid cached timestamp strings', () {
      expect(NiptoRecoveryChallengeGuard.isFreshTimestamp(
        startedAtEpochMs: (now - 1000).toString(),
        nowEpochMs: now,
      ), isTrue);
    });

    test('rejects missing, malformed, and future cached timestamp strings', () {
      expect(NiptoRecoveryChallengeGuard.isFreshTimestamp(
        startedAtEpochMs: null,
        nowEpochMs: now,
      ), isFalse);
      expect(NiptoRecoveryChallengeGuard.isFreshTimestamp(
        startedAtEpochMs: 'not-a-timestamp',
        nowEpochMs: now,
      ), isFalse);
      expect(NiptoRecoveryChallengeGuard.isFreshTimestamp(
        startedAtEpochMs: (now + 1).toString(),
        nowEpochMs: now,
      ), isFalse);
    });

    test('requires non-empty challenge id and secret', () {
      final validTimestamp = (now - 1000).toString();
      expect(NiptoRecoveryChallengeGuard.isUsableCache(
        challengeId: 'challenge',
        challengeSecret: 'secret',
        startedAtEpochMs: validTimestamp,
        nowEpochMs: now,
      ), isTrue);
      expect(NiptoRecoveryChallengeGuard.isUsableCache(
        challengeId: ' ',
        challengeSecret: 'secret',
        startedAtEpochMs: validTimestamp,
        nowEpochMs: now,
      ), isFalse);
      expect(NiptoRecoveryChallengeGuard.isUsableCache(
        challengeId: 'challenge',
        challengeSecret: '',
        startedAtEpochMs: validTimestamp,
        nowEpochMs: now,
      ), isFalse);
      expect(NiptoRecoveryChallengeGuard.isUsableCache(
        challengeId: 'challenge',
        challengeSecret: 'secret',
        startedAtEpochMs: 'invalid',
        nowEpochMs: now,
      ), isFalse);
    });
  });
}
