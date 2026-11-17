const RESERVED_IDS = new Set([
  "admin",
  "administrator",
  "support",
  "help",
  "nipto",
  "official",
  "security",
  "moderator",
]);

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
  return isValidNiptoId(value)
    && (ownerNiptoId === undefined || value !== ownerNiptoId);
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
