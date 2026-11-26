import { assertEquals } from "jsr:@std/assert@1.0.14";
import {
  exportObjectPath,
  isCanonicalUuid,
  isCronAuthorized,
  isDue,
  isPrivacySafeExport,
  isUserChatMediaPath,
  parseEmptyRequestPayload,
  parseStorageListNames,
  parseWorkerOptions,
  privacyObjectPrefixes,
  sanitizeCancelResult,
  sanitizeClaimedRows,
  sanitizeRequestResult,
  sanitizeStatusResponse,
} from "./validation.ts";

const USER = "11111111-1111-4111-8111-111111111111";
const REQUEST = "22222222-2222-4222-8222-222222222222";

Deno.test("status sanitizer returns only safe request fields", () => {
  const result = sanitizeStatusResponse([{
    id: REQUEST,
    kind: "export",
    status: "completed",
    requested_at: "2026-01-01T00:00:00.000Z",
    execute_after: "2026-01-01T00:00:01.000Z",
    completed_at: "2026-01-01T00:01:00.000Z",
    canceled_at: null,
    attempts: 1,
    export_path: USER + "/" + REQUEST + ".json",
    last_error: "internal detail",
  }]);
  assertEquals(result, {
    requests: [{
      id: REQUEST,
      kind: "export",
      status: "completed",
      requested_at: "2026-01-01T00:00:00.000Z",
      execute_after: "2026-01-01T00:00:01.000Z",
      completed_at: "2026-01-01T00:01:00.000Z",
      canceled_at: null,
      attempts: 1,
    }],
  });
});

Deno.test("status sanitizer rejects malformed and oversized responses", () => {
  const base = {
    id: REQUEST,
    kind: "export",
    status: "pending",
    requested_at: "2026-01-01T00:00:00.000Z",
    execute_after: "2026-01-01T00:00:01.000Z",
    attempts: 0,
  };
  assertEquals(sanitizeStatusResponse([{ ...base, status: "unknown" }]), null);
  assertEquals(sanitizeStatusResponse([{ ...base, id: "not-a-uuid" }]), null);
  assertEquals(sanitizeStatusResponse([{ ...base, attempts: 9 }]), null);
  assertEquals(
    sanitizeStatusResponse(Array.from({ length: 51 }, () => base)),
    null,
  );
  assertEquals(sanitizeStatusResponse({ requests: "not-an-array" }), null);
});

Deno.test("request result and cancel results are strictly parsed", () => {
  assertEquals(sanitizeRequestResult(REQUEST), {
    request_id: REQUEST,
    status: "pending",
  });
  assertEquals(sanitizeRequestResult({ request_id: REQUEST }), {
    request_id: REQUEST,
    status: "pending",
  });
  assertEquals(
    sanitizeRequestResult({ id: REQUEST, status: "completed" }),
    null,
  );
  assertEquals(sanitizeCancelResult({ canceled: false }), false);
  assertEquals(sanitizeCancelResult({ canceled: "false" }), null);
});

Deno.test("worker claim rows require processing state and valid identifiers", () => {
  const row = {
    id: REQUEST,
    user_id: USER,
    kind: "deletion",
    status: "processing",
    attempts: 1,
    execute_after: "2026-01-01T00:00:00.000Z",
    requested_at: "2025-12-18T00:00:00.000Z",
  };
  assertEquals(sanitizeClaimedRows([row])?.[0], row);
  assertEquals(sanitizeClaimedRows([{ ...row, status: "pending" }]), null);
  assertEquals(sanitizeClaimedRows([{ ...row, user_id: "nope" }]), null);
  assertEquals(sanitizeClaimedRows([{ ...row, attempts: 0 }]), null);
});

Deno.test("isDue uses the pending state and execute_after boundary", () => {
  const row = {
    status: "pending" as const,
    execute_after: "2026-01-01T00:00:00.000Z",
  };
  const at = Date.parse(row.execute_after);
  assertEquals(isDue(row, at), true);
  assertEquals(isDue(row, at - 1), false);
  assertEquals(isDue({ ...row, status: "processing" }, at + 1), false);
});

Deno.test("cron authorization requires the exact Bearer secret", () => {
  const secret = "cron-secret_value-123";
  assertEquals(isCronAuthorized("Bearer " + secret, secret), true);
  assertEquals(isCronAuthorized("bearer " + secret, secret), true);
  assertEquals(isCronAuthorized("Bearer wrong-secret", secret), false);
  assertEquals(isCronAuthorized(secret, secret), false);
  assertEquals(isCronAuthorized("Bearer " + secret, undefined), false);
});

Deno.test("payload validators accept only the documented shapes", () => {
  assertEquals(parseEmptyRequestPayload({}), true);
  assertEquals(parseEmptyRequestPayload({ kind: "export" }), false);
  assertEquals(parseWorkerOptions({}), { limit: 5 });
  assertEquals(parseWorkerOptions({ limit: 10 }), { limit: 10 });
  assertEquals(parseWorkerOptions({ limit: 11 }), null);
  assertEquals(parseWorkerOptions({ limit: 1, extra: true }), null);
});

Deno.test("export safety rejects credentials and private table names", () => {
  assertEquals(
    isPrivacySafeExport({
      profile: { nipto_id: "member", is_private: true },
      messages: [{ body: "hello", created_at: "2026-01-01T00:00:00.000Z" }],
    }),
    true,
  );
  assertEquals(
    isPrivacySafeExport({ profile: { password_hash: "argon2" } }),
    false,
  );
  assertEquals(
    isPrivacySafeExport({ nested: { access_token: "secret" } }),
    false,
  );
  assertEquals(isPrivacySafeExport({ device_tokens: [] }), false);
  assertEquals(isPrivacySafeExport({ staff_action_log: [] }), false);
  assertEquals(isPrivacySafeExport({ api_key: "secret" }), false);
});

Deno.test("object paths stay scoped to the requesting user", () => {
  assertEquals(isCanonicalUuid(USER), true);
  assertEquals(exportObjectPath(USER, REQUEST), USER + "/" + REQUEST + ".json");
  assertEquals(exportObjectPath(USER, "bad"), null);
  assertEquals(privacyObjectPrefixes(USER), [
    "avatars/" + USER + "/",
    "statuses/" + USER + "/",
    "posts/" + USER + "/",
    "shorts/" + USER + "/",
  ]);
  assertEquals(
    isUserChatMediaPath(
      "chat-media/" + REQUEST + "/" + USER + "/photo.jpg",
      USER,
    ),
    true,
  );
  assertEquals(
    isUserChatMediaPath(
      "chat-media/" + REQUEST +
        "/33333333-3333-4333-8333-333333333333/photo.jpg",
      USER,
    ),
    false,
  );
  assertEquals(
    isUserChatMediaPath("avatars/" + USER + "/photo.jpg", USER),
    false,
  );
});

Deno.test("storage listings only expose safe relative names", () => {
  const conversation = REQUEST + "/";
  assertEquals(
    parseStorageListNames([{ name: conversation }, { name: "photo.jpg" }]),
    [conversation, "photo.jpg"],
  );
  assertEquals(parseStorageListNames([{ name: "../secret" }]), null);
  assertEquals(parseStorageListNames([{ name: "/absolute" }]), null);
  assertEquals(parseStorageListNames([{ name: 7 }]), null);
});
