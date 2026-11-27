import { assertEquals } from "jsr:@std/assert@1.0.14";
import {
  backoffDelayMs,
  claimDecision,
  inspectMediaBytes,
  isCanonicalUuid,
  isOwnerPath,
  MediaValidationError,
  normalizeBearerAuthorization,
  pendingValidationState,
  sha256Hex,
} from "./validation.ts";

const OWNER = "550e8400-e29b-41d4-a716-446655440000";
const CONVERSATION = "650e8400-e29b-41d4-a716-446655440000";

function bytes(...values: number[]): Uint8Array {
  return new Uint8Array(values);
}

function ascii(value: string): Uint8Array {
  return new TextEncoder().encode(value);
}

function webp(): Uint8Array {
  const result = new Uint8Array(16);
  result.set(ascii("RIFF"), 0);
  result.set(ascii("WEBP"), 8);
  return result;
}

function mp4(): Uint8Array {
  const result = new Uint8Array(16);
  result.set(ascii("ftyp"), 4);
  return result;
}

Deno.test("canonical owner paths match the shapes created by the app", () => {
  assertEquals(
    isOwnerPath("avatars", `${OWNER}/avatar_1700000000123456.jpg`, OWNER),
    true,
  );
  assertEquals(
    isOwnerPath("posts", `${OWNER}/1700000000123456.png`, OWNER),
    true,
  );
  assertEquals(
    isOwnerPath("statuses", `${OWNER}/1700000000123456.mp4`, OWNER),
    true,
  );
  assertEquals(
    isOwnerPath("shorts", `${OWNER}/1700000000123456.mp4`, OWNER),
    true,
  );
  assertEquals(
    isOwnerPath(
      "chat-media",
      `${CONVERSATION}/${OWNER}/1700000000123456.webp`,
      OWNER,
    ),
    true,
  );
});

Deno.test("owner paths reject foreign prefixes and non-canonical keys", () => {
  const other = "750e8400-e29b-41d4-a716-446655440000";
  assertEquals(
    isOwnerPath("posts", `${other}/1700000000123456.jpg`, OWNER),
    false,
  );
  assertEquals(
    isOwnerPath("posts", `${OWNER}/1700000000123456.gif`, OWNER),
    false,
  );
  assertEquals(
    isOwnerPath("posts", `${OWNER}/nested/1700000000123456.jpg`, OWNER),
    false,
  );
  assertEquals(
    isOwnerPath("avatars", `${OWNER}/1700000000123456.jpg`, OWNER),
    false,
  );
  assertEquals(
    isOwnerPath("shorts", `${OWNER}/1700000000123456.mov`, OWNER),
    false,
  );
  assertEquals(
    isOwnerPath(
      "chat-media",
      `not-a-uuid/${OWNER}/1700000000123456.jpg`,
      OWNER,
    ),
    false,
  );
  assertEquals(
    isOwnerPath("unknown", `${OWNER}/1700000000123456.jpg`, OWNER),
    false,
  );
});

Deno.test("magic bytes verify declared image and video types", async () => {
  const jpeg = bytes(0xff, 0xd8, 0xff, 0xe0, 0, 16, 0, 0, 0, 0, 0, 0);
  const png = bytes(0x89, ...ascii("PNG"), 0x0d, 0x0a, 0x1a, 0x0a, 0, 0, 0, 0);
  assertEquals((await inspectMediaBytes(jpeg, "image/jpeg", "posts")).size, 12);
  assertEquals(
    (await inspectMediaBytes(png, "image/png", "avatars")).mime,
    "image/png",
  );
  assertEquals(
    (await inspectMediaBytes(webp(), "image/webp", "statuses")).mime,
    "image/webp",
  );
  assertEquals(
    (await inspectMediaBytes(mp4(), "video/mp4", "shorts")).mime,
    "video/mp4",
  );
});

Deno.test("magic byte mismatches are rejected, never reported as clean", async () => {
  const mismatch = await inspectMediaBytes(mp4(), "image/jpeg", "posts")
    .then(() => null)
    .catch((error: unknown) => error);
  assertEquals(mismatch instanceof MediaValidationError, true);
  assertEquals((mismatch as MediaValidationError).code, "magic_mismatch");

  const tooShort = await inspectMediaBytes(
    bytes(0xff, 0xd8),
    "image/jpeg",
    "posts",
  )
    .then(() => null)
    .catch((error: unknown) => error);
  assertEquals((tooShort as MediaValidationError).code, "magic_mismatch");

  const notAllowed = await inspectMediaBytes(webp(), "image/gif", "posts")
    .then(() => null)
    .catch((error: unknown) => error);
  assertEquals((notAllowed as MediaValidationError).code, "mime_not_allowed");

  const empty = await inspectMediaBytes(new Uint8Array(), "video/mp4", "shorts")
    .then(() => null)
    .catch((error: unknown) => error);
  assertEquals((empty as MediaValidationError).code, "empty_media");
});

Deno.test("sha256 is computed over the downloaded bytes", async () => {
  const digest = await sha256Hex(ascii("nipto"));
  assertEquals(
    digest,
    "d86d808dfaf22aa2c135f78bd34c16bf07ad756e5ada780d46e90610e005e992",
  );
});

Deno.test("unconfigured pipeline only produces honest pending states", () => {
  assertEquals(pendingValidationState("image/jpeg"), "needs_review");
  assertEquals(pendingValidationState("image/png"), "needs_review");
  assertEquals(pendingValidationState("image/webp"), "needs_review");
  assertEquals(pendingValidationState("video/mp4"), "processing");
});

Deno.test("idempotent claims skip previously validated bytes", () => {
  const sha = "a".repeat(64);
  assertEquals(
    claimDecision({ state: "needs_review", sha256: sha, attempts: 1 }, sha),
    { claim: false, reason: "already_validated" },
  );
  assertEquals(
    claimDecision({ state: "processing", sha256: sha, attempts: 1 }, sha),
    { claim: false, reason: "already_validated" },
  );
  assertEquals(
    claimDecision({ state: "rejected", sha256: sha, attempts: 1 }, sha),
    { claim: false, reason: "already_validated" },
  );
  assertEquals(claimDecision(null, sha), {
    claim: false,
    reason: "not_enqueued",
  });
});

Deno.test("changed bytes or failed states can be reclaimed within bounded attempts", () => {
  const sha = "b".repeat(64);
  assertEquals(
    claimDecision({
      state: "failed",
      sha256: "c".repeat(64),
      attempts: 2,
      next_attempt_at: null,
    }, sha),
    { claim: true, reason: "claimed" },
  );
  assertEquals(
    claimDecision({ state: "queued", sha256: null, attempts: 5 }, sha),
    { claim: false, reason: "attempt_limit_exceeded" },
  );
  const future = new Date(Date.now() + 60_000).toISOString();
  assertEquals(
    claimDecision({
      state: "queued",
      sha256: null,
      attempts: 1,
      next_attempt_at: future,
    }, sha),
    { claim: false, reason: "backoff" },
  );
  assertEquals(backoffDelayMs(3), 180_000);
  assertEquals(backoffDelayMs(99), 300_000);
});

Deno.test("authorization and UUID helpers reject ambiguous values", () => {
  assertEquals(isCanonicalUuid(OWNER), true);
  assertEquals(isCanonicalUuid("550e8400e29b41d4a716446655440000"), false);
  assertEquals(
    normalizeBearerAuthorization("bearer abc.def-ghi_xyz"),
    "Bearer abc.def-ghi_xyz",
  );
  assertEquals(normalizeBearerAuthorization("Bearer token extra"), null);
});
