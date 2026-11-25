import { assertEquals } from "jsr:@std/assert@1.0.14";
import {
  areJwtTemporalClaimsValid,
  isAllowedOidcScope,
  isRecoveryChallengeFresh,
  isValidNiptoId,
  isValidPassword,
  isValidRecoveryNiptoId,
  normalizeNiptoId,
  passwordsMatch,
  suggestNiptoIds,
} from "./validation.ts";

Deno.test("Nipto ID accepts canonical handles", () => {
  assertEquals(isValidNiptoId("nipto_user7"), true);
  assertEquals(isValidNiptoId("abc"), true);
  assertEquals(isValidNiptoId("a".repeat(24)), true);
});

Deno.test("Nipto ID rejects invalid and reserved handles", () => {
  assertEquals(isValidNiptoId("ab"), false);
  assertEquals(isValidNiptoId("a".repeat(25)), false);
  assertEquals(isValidNiptoId("Admin"), false);
  assertEquals(isValidNiptoId("admin"), false);
  assertEquals(isValidNiptoId("with space"), false);
  assertEquals(isValidNiptoId("dot.name"), false);
  assertEquals(isValidNiptoId("_abc"), false);
  assertEquals(isValidNiptoId("abc_"), false);
  assertEquals(isValidNiptoId("abc__def"), false);
  assertEquals(isValidNiptoId("abc_def"), true);
});

Deno.test("Nipto ID length and separator boundaries are explicit", () => {
  assertEquals(isValidNiptoId("a".repeat(3)), true);
  assertEquals(isValidNiptoId("a".repeat(24)), true);
  assertEquals(isValidNiptoId("a".repeat(2)), false);
  assertEquals(isValidNiptoId("a".repeat(25)), false);
  assertEquals(isValidNiptoId("a_b"), true);
  assertEquals(isValidNiptoId("a_1"), true);
  assertEquals(isValidNiptoId("a-1"), false);
  assertEquals(isValidNiptoId("a__1"), false);
  assertEquals(isValidNiptoId("1_a"), true);
});

Deno.test("all reserved IDs remain unavailable", () => {
  for (const reserved of [
    "admin", "administrator", "support", "help", "nipto", "official",
    "security", "moderator", "root", "owner", "staff", "system", "api",
    "app", "bot", "developer", "dev", "test", "tester", "abuse", "legal",
    "billing", "contact", "privacy", "status", "service", "null", "undefined",
    "nipto_admin", "nipto_support", "nipto_help", "nipto_security",
    "nipto_staff", "nipto_system", "nipto_service", "nipto_official",
    "nipto_verified", "nipto_updates", "nipto_news", "nipto_team",
    "nipto_app", "nipto_api", "nipto_bot",
  ]) {
    assertEquals(isValidNiptoId(reserved), false, reserved);
  }
});

Deno.test("Nipto ID normalization removes optional @ and canonicalizes case", () => {
  assertEquals(normalizeNiptoId("  @Nipto_User7  "), "nipto_user7");
  assertEquals(normalizeNiptoId("@ADMIN"), "admin");
  assertEquals(normalizeNiptoId(" user "), "user");
});

Deno.test("Nipto password length policy is bounded", () => {
  assertEquals(isValidPassword("12345678901"), false);
  assertEquals(isValidPassword("123456789012"), true);
  assertEquals(isValidPassword("x".repeat(128)), true);
  assertEquals(isValidPassword("x".repeat(129)), false);
  assertEquals(isValidPassword(""), false);
});

Deno.test("optional recovery Nipto ID accepts empty and valid non-self IDs", () => {
  assertEquals(isValidRecoveryNiptoId(""), true);
  assertEquals(isValidRecoveryNiptoId("   "), true);
  assertEquals(isValidRecoveryNiptoId("\t\n"), true);
  assertEquals(isValidRecoveryNiptoId("trusted_friend"), true);
  assertEquals(isValidRecoveryNiptoId("trusted_friend", "owner"), true);
});

Deno.test("recovery Nipto ID rejects malformed, reserved and normalized self IDs", () => {
  assertEquals(isValidRecoveryNiptoId("ab"), false);
  assertEquals(isValidRecoveryNiptoId("admin"), false);
  assertEquals(isValidRecoveryNiptoId("with space"), false);
  assertEquals(isValidRecoveryNiptoId("owner", "owner"), false);
  assertEquals(isValidRecoveryNiptoId("@Owner", "owner"), false);
  assertEquals(isValidRecoveryNiptoId("@ADMIN"), false);
});

Deno.test("password confirmation must match exactly", () => {
  assertEquals(passwordsMatch("secure-password-123", "secure-password-123"), true);
  assertEquals(passwordsMatch("secure-password-123", "secure-password-124"), false);
  assertEquals(passwordsMatch("secure-password-123", "secure-password-123 "), false);
});

Deno.test("OIDC accepts only the required openid and optional profile scopes", () => {
  assertEquals(isAllowedOidcScope("openid"), true);
  assertEquals(isAllowedOidcScope("openid profile"), true);
  assertEquals(isAllowedOidcScope("profile openid"), true);
  assertEquals(isAllowedOidcScope("openid email"), false);
  assertEquals(isAllowedOidcScope("openid offline_access"), false);
  assertEquals(isAllowedOidcScope("openid openid"), false);
  assertEquals(isAllowedOidcScope("profile"), false);
  assertEquals(isAllowedOidcScope(""), false);
  assertEquals(isAllowedOidcScope("openid\tprofile"), true);
  assertEquals(isAllowedOidcScope("openid\nprofile"), true);
  assertEquals(isAllowedOidcScope("OPENID"), false);
});

Deno.test("recovery challenge freshness accepts age within configured window", () => {
  const now = 2_000_000;
  assertEquals(isRecoveryChallengeFresh(now, now), true);
  assertEquals(isRecoveryChallengeFresh(now - 15 * 60 * 1000, now), true);
  assertEquals(isRecoveryChallengeFresh(now - 15 * 60 * 1000 - 1, now), false);
  assertEquals(isRecoveryChallengeFresh(now + 1, now), false);
});

Deno.test("recovery challenge freshness rejects invalid timestamps and lifetimes", () => {
  assertEquals(isRecoveryChallengeFresh(Number.NaN, 2_000_000), false);
  assertEquals(isRecoveryChallengeFresh(Number.POSITIVE_INFINITY, 2_000_000), false);
  assertEquals(isRecoveryChallengeFresh(0, 2_000_000), false);
  assertEquals(isRecoveryChallengeFresh(1_000, Number.NaN), false);
  assertEquals(isRecoveryChallengeFresh(1_000, 2_000, 0), false);
  assertEquals(isRecoveryChallengeFresh(1_000, 2_000, -1), false);
});
Deno.test("recovery challenge freshness rejects far-future clock skew and overflow-like values", () => {
  const now = 5_000_000;
  assertEquals(isRecoveryChallengeFresh(now + 1, now), false);
  assertEquals(isRecoveryChallengeFresh(now - 900_000, now), true);
  assertEquals(isRecoveryChallengeFresh(now - 900_001, now), false);
  assertEquals(isRecoveryChallengeFresh(now, now, Number.NaN), false);
});

Deno.test("recovery ID validation normalizes case and optional @ consistently", () => {
  assertEquals(isValidRecoveryNiptoId("@Trusted_Friend", "owner"), true);
  assertEquals(isValidRecoveryNiptoId(" @OWNER ", "@owner"), false);
  assertEquals(isValidRecoveryNiptoId(" @NIPTO_SUPPORT "), false);
});

Deno.test("Nipto ID suggestions are valid, unique and bounded", () => {
  const suggestions = suggestNiptoIds("@New_User", 5);
  assertEquals(suggestions[0], "new_user");
  assertEquals(suggestions.length, 5);
  assertEquals(new Set(suggestions).size, suggestions.length);
  for (const candidate of suggestions) assertEquals(isValidNiptoId(candidate), true);
});
Deno.test("Nipto ID suggestions handle reserved and short inputs safely", () => {
  assertEquals(suggestNiptoIds("admin", 3).every(isValidNiptoId), true);
  assertEquals(suggestNiptoIds("ab", 3).every(isValidNiptoId), true);
  assertEquals(suggestNiptoIds("!!", 5), []);
  assertEquals(suggestNiptoIds("name", 0), []);
  assertEquals(suggestNiptoIds("name", -1), []);
});
Deno.test("Nipto ID suggestion requests are capped to protect bounded work", () => {
  const suggestions = suggestNiptoIds("user", 100_000);
  assertEquals(suggestions.length, 20);
  assertEquals(suggestions.every(isValidNiptoId), true);
});

Deno.test("Nipto ID suggestions remain within the 24 character limit", () => {
  const suggestions = suggestNiptoIds("a".repeat(24), 10);
  assertEquals(suggestions.every((candidate) => candidate.length <= 24), true);
  assertEquals(suggestions.every(isValidNiptoId), true);
});

Deno.test("JWT temporal claims accept valid bounded tokens", () => {
  const now = 1_700_000_000;
  assertEquals(areJwtTemporalClaimsValid({ iat: now - 10, exp: now + 60 }, now), true);
  assertEquals(areJwtTemporalClaimsValid({ iat: now + 60, exp: now + 120 }, now), true);
  assertEquals(areJwtTemporalClaimsValid({ iat: now - 10, exp: now + 60, nbf: now }, now), true);
});

Deno.test("JWT temporal claims reject invalid, expired and future claims", () => {
  const now = 1_700_000_000;
  assertEquals(areJwtTemporalClaimsValid({ exp: now + 60 }, now), false);
  assertEquals(areJwtTemporalClaimsValid({ iat: now - 10, exp: now }, now), false);
  assertEquals(areJwtTemporalClaimsValid({ iat: now - 10, exp: now - 1 }, now), false);
  assertEquals(areJwtTemporalClaimsValid({ iat: now + 61, exp: now + 120 }, now), false);
  assertEquals(areJwtTemporalClaimsValid({ iat: now - 10, exp: now + 60, nbf: "later" }, now), false);
  assertEquals(areJwtTemporalClaimsValid({ iat: now - 10, exp: now + 60, nbf: now + 1 }, now), false);
  assertEquals(areJwtTemporalClaimsValid({ iat: Number.NaN, exp: now + 60 }, now), false);
  assertEquals(areJwtTemporalClaimsValid({ iat: now - 10, exp: Number.POSITIVE_INFINITY }, now), false);
});
