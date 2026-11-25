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

/** Validates JWT temporal claims with bounded clock-skew tolerance. */
export function areJwtTemporalClaimsValid(
  claims: Record<string, unknown>,
  nowSeconds: number,
  clockSkewSeconds = 60,
): boolean {
  if (!Number.isFinite(nowSeconds) || !Number.isFinite(clockSkewSeconds) || clockSkewSeconds < 0) return false;
  const issuedAt = claims.iat;
  const expiresAt = claims.exp;
  if (typeof issuedAt !== "number" || !Number.isFinite(issuedAt)
    || typeof expiresAt !== "number" || !Number.isFinite(expiresAt)
    || issuedAt > nowSeconds + clockSkewSeconds
    || expiresAt <= nowSeconds || expiresAt <= issuedAt) return false;
  if (Object.prototype.hasOwnProperty.call(claims, "nbf")) {
    const notBefore = claims.nbf;
    if (typeof notBefore !== "number" || !Number.isFinite(notBefore) || notBefore > nowSeconds) return false;
  }
  return true;
}

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
  if (value.trim() === "") return true;
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
  const scopes = value.trim().split(/\s+/).filter(Boolean);
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

/** Suggest deterministic alternative handles for the registration UI.
 * Availability is intentionally not implied; callers must check candidates against the database.
 */
export function suggestNiptoIds(value: string, limit = 5): string[] {
  if (!Number.isInteger(limit) || limit <= 0) return [];
  // Bound caller-requested work even if a future caller passes an untrusted limit.
  const boundedLimit = Math.min(limit, 20);
  const base = normalizeNiptoId(value).replace(/[^a-z0-9_]/g, "_")
    .replace(/_+/g, "_").replace(/^_+|_+$/g, "");
  if (base.length < 3) return [];
  const candidates: string[] = [];
  const add = (candidate: string) => {
    if (candidate.length > 24) candidate = candidate.slice(0, 24).replace(/_+$/g, "");
    if (isValidNiptoId(candidate) && !candidates.includes(candidate)) candidates.push(candidate);
  };
  add(base);
  for (let suffix = 1; candidates.length < boundedLimit && suffix <= 9999; suffix++) {
    const tail = String(suffix);
    const stem = base.slice(0, Math.max(1, 24 - tail.length));
    add(stem.replace(/_+$/g, "") + tail);
  }
  return candidates.slice(0, boundedLimit);
}
