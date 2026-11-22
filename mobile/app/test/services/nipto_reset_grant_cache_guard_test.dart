import 'package:flutter_test/flutter_test.dart';
import 'package:nipto/services/nipto_reset_grant_cache_guard.dart';

void main() {
  group('NiptoResetGrantCacheGuard', () {
    const now = 2000000;

    test('accepts non-empty grant within cache window', () {
      expect(NiptoResetGrantCacheGuard.isUsable(
        grant: 'grant',
        issuedAtEpochMs: (now - 1000).toString(),
        nowEpochMs: now,
      ), isTrue);
    });

    test('accepts grant at exact cache-window boundary', () {
      expect(NiptoResetGrantCacheGuard.isUsable(
        grant: 'grant',
        issuedAtEpochMs: (now - NiptoResetGrantCacheGuard.cacheWindow.inMilliseconds).toString(),
        nowEpochMs: now,
      ), isTrue);
    });

    test('rejects expired local cache', () {
      expect(NiptoResetGrantCacheGuard.isUsable(
        grant: 'grant',
        issuedAtEpochMs: (now - NiptoResetGrantCacheGuard.cacheWindow.inMilliseconds - 1).toString(),
        nowEpochMs: now,
      ), isFalse);
    });

    test('rejects empty grant, missing/malformed timestamp and future timestamp', () {
      expect(NiptoResetGrantCacheGuard.isUsable(grant: ' ', issuedAtEpochMs: now.toString(), nowEpochMs: now), isFalse);
      expect(NiptoResetGrantCacheGuard.isUsable(grant: 'grant', issuedAtEpochMs: null, nowEpochMs: now), isFalse);
      expect(NiptoResetGrantCacheGuard.isUsable(grant: 'grant', issuedAtEpochMs: 'bad', nowEpochMs: now), isFalse);
      expect(NiptoResetGrantCacheGuard.isUsable(grant: 'grant', issuedAtEpochMs: (now + 1).toString(), nowEpochMs: now), isFalse);
    });
  });
}
