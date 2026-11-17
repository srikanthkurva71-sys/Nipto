import { assertEquals } from "jsr:@std/assert@1.0.14";
import { isAllowedOidcScope, isValidNiptoId, isValidPassword } from "./validation.ts";

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

Deno.test("Nipto password length policy is bounded", () => {
  assertEquals(isValidPassword("12345678901"), false);
  assertEquals(isValidPassword("123456789012"), true);
  assertEquals(isValidPassword("x".repeat(128)), true);
  assertEquals(isValidPassword("x".repeat(129)), false);
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
});
