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
  return /^[a-z0-9_]{3,24}$/.test(value) && !RESERVED_IDS.has(value);
}

export function isValidPassword(value: string): boolean {
  return value.length >= 12 && value.length <= 128;
}
