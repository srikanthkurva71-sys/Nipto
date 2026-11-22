const RESERVED_IDS = new Set([
  "admin", "administrator", "support", "help", "nipto", "official",
  "security", "moderator", "root", "owner", "staff", "system", "api",
  "app", "bot", "developer", "dev", "test", "tester", "abuse", "legal",
  "billing", "contact", "privacy", "status", "service", "null", "undefined",
  "nipto_admin", "nipto_support", "nipto_help", "nipto_security",
  "nipto_staff", "nipto_system", "nipto_service", "nipto_official",
  "nipto_verified", "nipto_updates", "nipto_news", "nipto_team",
  "nipto_app", "nipto_api", "nipto_bot",
]);

/** Canonicalize user-entered Nipto handles consistently before lookup. */
export function normalizeNiptoId(value: string): string {
  return value.trim().replace(/^@/, "").toLowerCase();
}

export function isValidNiptoId(value: string): boolean {
  return value.length >= 3 && value.length <= 24
    && /^[a-z0-9]+(?:_[a-z0-9]+)*$/.test(value)
    && !RESERVED_IDS.has(value);
}

export function isValidRecoveryNiptoId(
  value: string,
  ownerNiptoId?: string,
): boolean {
  if (value === "") return true;
  const normalized = normalizeNiptoId(value);
  const normalizedOwner = ownerNiptoId === undefined
    ? undefined
    : normalizeNiptoId(ownerNiptoId);
  return isValidNiptoId(normalized)
    && (normalizedOwner === undefined || normalized !== normalizedOwner);
}

export function isValidPassword(value: string): boolean {
  return value.length >= 12 && value.length <= 128;
}

export function passwordsMatch(password: string, confirmation: string): boolean {
  return password === confirmation;
}

export function isAllowedOidcScope(value: string): boolean {
  const scopes = value.trim().split(/\\s+/).filter(Boolean);
  return scopes.includes("openid")
    && new Set(scopes).size === scopes.length
    && scopes.every((scope) => scope === "openid" || scope === "profile");
}

/** Recovery challenges are valid only within their lifetime and never from the future. */
export function isRecoveryChallengeFresh(
  startedAtMs: number,
  nowMs = Date.now(),
  maxAgeMs = 15 * 60 * 1000,
): boolean {
  if (!Number.isFinite(startedAtMs) || !Number.isFinite(nowMs) ||
      !Number.isFinite(maxAgeMs) || startedAtMs <= 0 || maxAgeMs <= 0) {
    return false;
  }
  const ageMs = nowMs - startedAtMs;
  return ageMs >= 0 && ageMs <= maxAgeMs;
}
