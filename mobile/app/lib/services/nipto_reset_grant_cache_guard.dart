/// Guards only the locally cached reset-grant reuse window.
/// The server remains authoritative for grant expiry and single-use semantics.
class NiptoResetGrantCacheGuard {
  const NiptoResetGrantCacheGuard._();

  static const cacheWindow = Duration(minutes: 1);

  static bool isUsable({
    required String? grant,
    required String? issuedAtEpochMs,
    required int nowEpochMs,
  }) {
    if (grant == null || grant.trim().isEmpty) return false;
    final issuedAt = int.tryParse(issuedAtEpochMs ?? '');
    if (issuedAt == null || issuedAt > nowEpochMs) return false;
    final age = nowEpochMs - issuedAt;
    return age <= cacheWindow.inMilliseconds;
  }
}
