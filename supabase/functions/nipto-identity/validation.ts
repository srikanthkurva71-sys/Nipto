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

export function isValidPassword(value: string): boolean {
  return value.length >= 12 && value.length <= 128;
}
