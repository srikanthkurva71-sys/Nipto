import { assertEquals, assertThrows } from "jsr:@std/assert@1";
import {
  base64url,
  fcmErrorStatus,
  isInvalidTokenStatus,
  parseServiceAccount,
  pemPrivateKeyToDer,
  pushBodyForJob,
  pushDataForJob,
  type PushJob,
  pushTitleForJob,
  signServiceAccountJwt,
} from "./push_helpers.ts";

Deno.test("push payload contains opaque identifiers only", () => {
  const job: PushJob = {
    id: "11111111-1111-4111-8111-111111111111",
    user_id: "22222222-2222-4222-8222-222222222222",
    delivery_type: "notification",
    payload: {
      notification_id: "33333333-3333-4333-8333-333333333333",
      notification_type: "message",
      entity_id: "44444444-4444-4444-8444-444444444444",
      actor_name: "Ada",
    },
  };
  const data = pushDataForJob(job);
  assertEquals(data.click_action, "FLUTTER_NOTIFICATION_CLICK");
  assertEquals(data.notification_type, "message");
  assertEquals(data.entity_id, "44444444-4444-4444-8444-444444444444");
  assertEquals(Object.keys(data).includes("body"), false);
  assertEquals(pushTitleForJob(job), "New Nipto activity");
  assertEquals(pushBodyForJob(job), "Ada sent you a message");
});

Deno.test("call push uses high-signal strings without SDP or ICE", () => {
  const job: PushJob = {
    id: "call-id",
    user_id: "user-id",
    delivery_type: "incoming_call",
    payload: {
      caller_name: "Grace",
      media_type: "video",
      call_id: "call-id",
      sdp: "secret",
    },
  };
  assertEquals(pushTitleForJob(job), "Grace is calling");
  assertEquals(pushBodyForJob(job), "Video call");
  assertEquals(pushDataForJob(job).sdp, undefined);
});

Deno.test("invalid FCM tokens are detected from statuses and error codes", () => {
  assertEquals(isInvalidTokenStatus(404), true);
  assertEquals(isInvalidTokenStatus(410), true);
  assertEquals(isInvalidTokenStatus(400, "UNREGISTERED"), true);
  assertEquals(isInvalidTokenStatus(400, "INVALID_ARGUMENT"), false);
  assertEquals(
    fcmErrorStatus(400, JSON.stringify({ error: { status: "NOT_FOUND" } })),
    404,
  );
});

Deno.test("service account parsing validates required fields", () => {
  assertThrows(
    () => parseServiceAccount("{}"),
    Error,
    "Invalid FCM service account",
  );
  const account = parseServiceAccount(JSON.stringify({
    project_id: "nipto",
    client_email: "push@nipto.iam.gserviceaccount.com",
    private_key:
      "-----BEGIN PRIVATE KEY-----\nQUJD\n-----END PRIVATE KEY-----\n",
  }));
  assertEquals(account.project_id, "nipto");
  assertEquals(base64url("nipto"), "bmlwdG8");
  assertEquals(pemPrivateKeyToDer(account.private_key).length, 3);
});

function encodePem(label: string, bytes: Uint8Array): string {
  let binary = "";
  for (const byte of bytes) binary += String.fromCharCode(byte);
  const encoded = btoa(binary).match(/.{1,64}/g)?.join("\n") ?? "";
  return `-----BEGIN ${label}-----\n${encoded}\n-----END ${label}-----\n`;
}

function decodeBase64Url(value: string): Uint8Array<ArrayBuffer> {
  const normalized = value.replaceAll("-", "+").replaceAll("_", "/");
  const padded = normalized.padEnd(
    Math.ceil(normalized.length / 4) * 4,
    "=",
  );
  const binary = atob(padded);
  const bytes = new Uint8Array(new ArrayBuffer(binary.length));
  for (let index = 0; index < binary.length; index += 1) {
    bytes[index] = binary.charCodeAt(index);
  }
  return bytes;
}

Deno.test("service account JWT is RS256 signed and verifiable", async () => {
  const algorithm = {
    name: "RSASSA-PKCS1-v1_5",
    modulusLength: 2048,
    publicExponent: new Uint8Array([1, 0, 1]),
    hash: "SHA-256",
  } as const;
  const keys = await crypto.subtle.generateKey(
    algorithm,
    true,
    ["sign", "verify"],
  );
  const pkcs8 = await crypto.subtle.exportKey("pkcs8", keys.privateKey);
  const account = parseServiceAccount(JSON.stringify({
    project_id: "nipto",
    client_email: "push@nipto.iam.gserviceaccount.com",
    private_key: encodePem("PRIVATE KEY", new Uint8Array(pkcs8)),
  }));
  const issuedAt = 1_700_000_000;
  const jwt = await signServiceAccountJwt(account, issuedAt);
  const parts = jwt.split(".");
  assertEquals(parts.length, 3);

  const decoder = new TextDecoder();
  const header = JSON.parse(decoder.decode(decodeBase64Url(parts[0])));
  const payload = JSON.parse(decoder.decode(decodeBase64Url(parts[1])));
  assertEquals(header.alg, "RS256");
  assertEquals(header.typ, "JWT");
  assertEquals(payload.iss, account.client_email);
  assertEquals(
    payload.scope,
    "https://www.googleapis.com/auth/firebase.messaging",
  );
  assertEquals(payload.exp - payload.iat, 3600);

  const verified = await crypto.subtle.verify(
    { name: "RSASSA-PKCS1-v1_5", hash: "SHA-256" },
    keys.publicKey,
    decodeBase64Url(parts[2]),
    new TextEncoder().encode(`${parts[0]}.${parts[1]}`),
  );
  assertEquals(verified, true);
});
