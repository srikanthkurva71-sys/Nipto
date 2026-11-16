import { argon2id, argon2Verify } from "npm:hash-wasm@4.13.0";

const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "GET, POST, OPTIONS",
  "Content-Type": "application/json; charset=utf-8",
  "Cache-Control": "no-store",
};

const encoder = new TextEncoder();
const ARGON2 = { parallelism: 1, iterations: 3, memorySize: 65_536, hashLength: 32 };
const ACCESS_TOKEN_SECONDS = 600;
const REFRESH_TOKEN_DAYS = 30;
const MAX_BODY_BYTES = 8_192;
const RESERVED_IDS = new Set([
  "admin", "administrator", "support", "help", "nipto",
  "official", "security", "moderator",
]);

type Json = Record<string, unknown>;
type Claims = {
  sub: string;
  sid: string;
  nipto_id: string;
  display_name: string;
  exp: number;
  iss: string;
  aud: string;
  role: string;
};

function env(name: string): string {
  const value = Deno.env.get(name);
  if (!value) throw new Error("Missing server configuration");
  return value;
}

function json(body: Json, status = 200): Response {
  return new Response(JSON.stringify(body), { status, headers: corsHeaders });
}

function base64url(bytes: Uint8Array): string {
  let binary = "";
  for (const byte of bytes) binary += String.fromCharCode(byte);
  return btoa(binary).replaceAll("+", "-").replaceAll("/", "_").replaceAll("=", "");
}

function fromBase64url(value: string): Uint8Array {
  const normalized = value.replaceAll("-", "+").replaceAll("_", "/");
  const binary = atob(normalized + "=".repeat((4 - normalized.length % 4) % 4));
  return Uint8Array.from(binary, (char) => char.charCodeAt(0));
}

function randomToken(bytes = 32): string {
  return base64url(crypto.getRandomValues(new Uint8Array(bytes)));
}

function uuid(): string {
  return crypto.randomUUID();
}

async function sha256Hex(value: string): Promise<string> {
  const digest = await crypto.subtle.digest("SHA-256", encoder.encode(value));
  return Array.from(new Uint8Array(digest), (b) => b.toString(16).padStart(2, "0")).join("");
}

async function hmacHex(secret: string, value: string): Promise<string> {
  const key = await crypto.subtle.importKey(
    "raw", encoder.encode(secret), { name: "HMAC", hash: "SHA-256" }, false, ["sign"],
  );
  const signature = await crypto.subtle.sign("HMAC", key, encoder.encode(value));
  return Array.from(new Uint8Array(signature), (b) => b.toString(16).padStart(2, "0")).join("");
}

function issuer(): string {
  return env("NIPTO_OIDC_ISSUER").replace(/\/$/, "");
}

function privateJwk(): Json {
  return JSON.parse(env("NIPTO_OIDC_PRIVATE_JWK")) as Json;
}

function keyId(): string {
  return env("NIPTO_OIDC_KID");
}

let signingKeyPromise: Promise<CryptoKey> | undefined;
function signingKey(): Promise<CryptoKey> {
  signingKeyPromise ??= crypto.subtle.importKey(
    "jwk",
    privateJwk() as JsonWebKey,
    { name: "ECDSA", namedCurve: "P-256" },
    false,
    ["sign"],
  );
  return signingKeyPromise;
}

function publicJwk(): Json {
  const jwk = { ...privateJwk() };
  delete jwk.d;
  delete jwk.key_ops;
  return { ...jwk, use: "sig", alg: "ES256", kid: keyId() };
}

async function signAccessToken(account: {
  user_id: string;
  nipto_id: string;
  display_name: string;
}, sessionId: string): Promise<string> {
  const now = Math.floor(Date.now() / 1000);
  const header = base64url(encoder.encode(JSON.stringify({
    alg: "ES256", typ: "JWT", kid: keyId(),
  })));
  const payload = base64url(encoder.encode(JSON.stringify({
    iss: issuer(),
    sub: account.user_id,
    aud: "authenticated",
    role: "authenticated",
    iat: now,
    exp: now + ACCESS_TOKEN_SECONDS,
    jti: uuid(),
    sid: sessionId,
    nipto_id: account.nipto_id,
    display_name: account.display_name,
  })));
  const input = encoder.encode(header + "." + payload);
  const signature = await crypto.subtle.sign(
    { name: "ECDSA", hash: "SHA-256" }, await signingKey(), input,
  );
  return header + "." + payload + "." + base64url(new Uint8Array(signature));
}

let verifyKeyPromise: Promise<CryptoKey> | undefined;
function verifyKey(): Promise<CryptoKey> {
  if (!verifyKeyPromise) {
    const jwk = publicJwk();
    verifyKeyPromise = crypto.subtle.importKey(
      "jwk", jwk as JsonWebKey, { name: "ECDSA", namedCurve: "P-256" }, false, ["verify"],
    );
  }
  return verifyKeyPromise;
}

async function verifyAccessToken(request: Request): Promise<Claims> {
  const authorization = request.headers.get("authorization") ?? "";
  const match = /^Bearer ([A-Za-z0-9._-]+)$/.exec(authorization);
  if (!match) throw new Error("Authentication required");
  const parts = match[1].split(".");
  if (parts.length !== 3) throw new Error("Invalid session");
  const header = JSON.parse(new TextDecoder().decode(fromBase64url(parts[0]))) as Json;
  const claims = JSON.parse(new TextDecoder().decode(fromBase64url(parts[1]))) as Claims;
  if (header.alg !== "ES256" || header.kid !== keyId()) throw new Error("Invalid session");
  const valid = await crypto.subtle.verify(
    { name: "ECDSA", hash: "SHA-256" },
    await verifyKey(),
    fromBase64url(parts[2]),
    encoder.encode(parts[0] + "." + parts[1]),
  );
  const now = Math.floor(Date.now() / 1000);
  if (!valid || claims.iss !== issuer() || claims.aud !== "authenticated"
      || claims.role !== "authenticated" || !claims.sub || !claims.sid
      || !claims.nipto_id || !claims.display_name || claims.exp <= now
      || claims.exp > now + ACCESS_TOKEN_SECONDS + 60) {
    throw new Error("Invalid or expired session");
  }
  return claims;
}

async function rpc(name: string, args: Json): Promise<any> {
  const url = env("SUPABASE_URL").replace(/\/$/, "");
  const key = env("SUPABASE_SERVICE_ROLE_KEY");
  const response = await fetch(url + "/rest/v1/rpc/" + name, {
    method: "POST",
    headers: {
      apikey: key,
      Authorization: "Bearer " + key,
      "Content-Type": "application/json",
    },
    body: JSON.stringify(args),
  });
  if (!response.ok) {
    const text = await response.text();
    throw new Error("Database operation failed (" + response.status + "): " + text.slice(0, 300));
  }
  if (response.status === 204) return null;
  return await response.json();
}

async function body(request: Request): Promise<Json> {
  const raw = await request.text();
  if (encoder.encode(raw).length > MAX_BODY_BYTES) throw new Error("Request too large");
  const value = JSON.parse(raw);
  if (!value || typeof value !== "object" || Array.isArray(value)) throw new Error("Invalid request");
  return value as Json;
}

function stringField(value: unknown, max: number): string {
  return typeof value === "string" && value.length <= max ? value : "";
}

function validNiptoId(value: string): boolean {
  return /^[a-z0-9_]{3,24}$/.test(value) && !RESERVED_IDS.has(value);
}

function validPassword(value: string): boolean {
  return value.length >= 12 && value.length <= 128;
}

async function hashPassword(password: string): Promise<string> {
  const salt = crypto.getRandomValues(new Uint8Array(16));
  return await argon2id({
    password,
    salt,
    ...ARGON2,
    outputType: "encoded",
  }) as string;
}

async function verifyPassword(password: string, hash: string): Promise<boolean> {
  try {
    return await argon2Verify({ password, hash });
  } catch {
    return false;
  }
}

async function enforceRateLimit(request: Request, identifier: string): Promise<void> {
  const ip = request.headers.get("cf-connecting-ip")
    ?? request.headers.get("x-real-ip")
    ?? request.headers.get("x-forwarded-for")?.split(",")[0]?.trim()
    ?? "unknown";
  const keyHash = await hmacHex(env("SUPABASE_SERVICE_ROLE_KEY"), ip + "\u0000" + identifier);
  const allowed = await rpc("consume_nipto_login_attempt", { p_key_hash: keyHash });
  if (allowed !== true) throw new Error("RATE_LIMITED");
}

async function accountRecord(niptoId: string): Promise<any | null> {
  const rows = await rpc("nipto_native_login_record", { p_nipto_id: niptoId });
  return Array.isArray(rows) ? rows[0] ?? null : rows ?? null;
}

async function createSession(account: any, deviceLabel: string): Promise<Json> {
  const refreshToken = randomToken(48);
  const sessionId = await rpc("nipto_native_create_session", {
    p_user_id: account.user_id,
    p_refresh_token_hash: await sha256Hex(refreshToken),
    p_expires_at: new Date(Date.now() + REFRESH_TOKEN_DAYS * 86_400_000).toISOString(),
    p_device_label: deviceLabel.slice(0, 80),
  });
  const accessToken = await signAccessToken(account, sessionId);
  return {
    access_token: accessToken,
    refresh_token: refreshToken,
    expires_in: ACCESS_TOKEN_SECONDS,
    token_type: "Bearer",
    user: {
      id: account.user_id,
      nipto_id: account.nipto_id,
      display_name: account.display_name,
    },
  };
}

async function route(request: Request): Promise<Response> {
  const url = new URL(request.url);
  const path = url.pathname.replace(/\/$/, "");
  const method = request.method;

  if (method === "OPTIONS") return new Response("ok", { headers: corsHeaders });
  if (path.endsWith("/.well-known/openid-configuration") && method === "GET") {
    const base = issuer();
    return json({
      issuer: base,
      jwks_uri: base + "/jwks",
      userinfo_endpoint: base + "/userinfo",
      claims_supported: ["iss", "sub", "aud", "exp", "iat", "jti", "role", "sid", "nipto_id", "display_name"],
      subject_types_supported: ["public"],
      id_token_signing_alg_values_supported: ["ES256"],
    });
  }
  if (path.endsWith("/jwks") && method === "GET") {
    return json({ keys: [publicJwk()] });
  }
  if (path.endsWith("/register") && method === "POST") {
    const input = await body(request);
    const niptoId = stringField(input.nipto_id, 24).trim().toLowerCase().replace(/^@/, "");
    const displayName = stringField(input.display_name, 50).trim();
    const password = stringField(input.password, 128);
    const recoveryId = stringField(input.recovery_nipto_id, 24).trim().toLowerCase().replace(/^@/, "");
    if (!validNiptoId(niptoId) || displayName.length < 1 || !validPassword(password)
        || (recoveryId && (!validNiptoId(recoveryId) || recoveryId === niptoId))) {
      return json({ error: "Check your Nipto ID, name and password requirements." }, 400);
    }
    await enforceRateLimit(request, "register:" + niptoId);
    const passwordHash = await hashPassword(password);
    const rows = await rpc("nipto_native_register", {
      p_nipto_id: niptoId,
      p_display_name: displayName,
      p_password_hash: passwordHash,
      p_recovery_nipto_id: recoveryId || null,
    });
    const account = Array.isArray(rows) ? rows[0] : rows;
    if (!account?.user_id) return json({ error: "Account could not be created." }, 409);
    return json(await createSession({
      user_id: account.user_id,
      nipto_id: niptoId,
      display_name: displayName,
    }, stringField(input.device_label, 80)));
  }
  if (path.endsWith("/login") && method === "POST") {
    const input = await body(request);
    const niptoId = stringField(input.nipto_id, 24).trim().toLowerCase().replace(/^@/, "");
    const password = stringField(input.password, 128);
    if (!validNiptoId(niptoId) || password.length < 1) return json({ error: "Invalid Nipto ID or password." }, 400);
    await enforceRateLimit(request, niptoId);
    const account = await accountRecord(niptoId);
    const dummy = await dummyHash();
    const matched = await verifyPassword(password, account?.password_hash ?? dummy);
    if (!account || !matched) return json({ error: "Invalid Nipto ID or password." }, 401);
    return json(await createSession(account, stringField(input.device_label, 80)));
  }
  if (path.endsWith("/refresh") && method === "POST") {
    const input = await body(request);
    const oldToken = stringField(input.refresh_token, 256);
    if (oldToken.length < 40) return json({ error: "Session expired. Sign in again." }, 401);
    const newToken = randomToken(48);
    const rows = await rpc("nipto_native_rotate_session", {
      p_old_refresh_token_hash: await sha256Hex(oldToken),
      p_new_refresh_token_hash: await sha256Hex(newToken),
      p_new_expires_at: new Date(Date.now() + REFRESH_TOKEN_DAYS * 86_400_000).toISOString(),
    });
    const session = Array.isArray(rows) ? rows[0] : rows;
    if (!session?.user_id || !session?.session_id) return json({ error: "Session expired. Sign in again." }, 401);
    const profileRows = await fetchProfile(session.user_id);
    return json({
      access_token: await signAccessToken(profileRows, session.session_id),
      refresh_token: newToken,
      expires_in: ACCESS_TOKEN_SECONDS,
      token_type: "Bearer",
      user: { id: profileRows.user_id, nipto_id: profileRows.nipto_id, display_name: profileRows.display_name },
    });
  }
  if (path.endsWith("/logout") && method === "POST") {
    const claims = await verifyAccessToken(request);
    await rpc("nipto_native_revoke_session", {
      p_user_id: claims.sub,
      p_session_id: claims.sid,
    });
    return json({ ok: true });
  }
  if (path.endsWith("/logout-all") && method === "POST") {
    const claims = await verifyAccessToken(request);
    await rpc("nipto_native_revoke_all_sessions", { p_user_id: claims.sub });
    return json({ ok: true });
  }
  if (path.endsWith("/userinfo") && method === "GET") {
    const claims = await verifyAccessToken(request);
    return json({
      sub: claims.sub,
      preferred_username: claims.nipto_id,
      name: claims.display_name,
    });
  }
  if (path.endsWith("/recovery/start") && method === "POST") {
    const input = await body(request);
    const niptoId = stringField(input.nipto_id, 24).trim().toLowerCase().replace(/^@/, "");
    const challengeSecret = randomToken(32);
    const challengeHash = await sha256Hex(challengeSecret);
    const rows = validNiptoId(niptoId)
      ? await rpc("nipto_native_start_recovery", {
          p_nipto_id: niptoId,
          p_challenge_hash: challengeHash,
        })
      : [];
    const created = Array.isArray(rows) ? rows[0] : rows;
    return json({
      message: "If this account can be recovered, its trusted Nipto account will receive an in-app request.",
      challenge_id: created?.challenge_id ?? uuid(),
      challenge_secret: challengeSecret,
    });
  }
  if (path.endsWith("/recovery/claim") && method === "POST") {
    const input = await body(request);
    const challengeId = stringField(input.challenge_id, 36);
    const challengeSecret = stringField(input.challenge_secret, 128);
    if (!/^[0-9a-f-]{36}$/i.test(challengeId) || challengeSecret.length < 40) {
      return json({ status: "pending" });
    }
    const grantSecret = randomToken(32);
    const ownerId = await rpc("nipto_native_claim_reset_grant", {
      p_challenge_id: challengeId,
      p_challenge_hash: await sha256Hex(challengeSecret),
      p_grant_hash: await sha256Hex(grantSecret),
    });
    return ownerId
      ? json({ status: "approved", reset_grant: grantSecret })
      : json({ status: "pending" });
  }
  if (path.endsWith("/recovery/reset") && method === "POST") {
    const input = await body(request);
    const grant = stringField(input.reset_grant, 128);
    const password = stringField(input.new_password, 128);
    if (grant.length < 40 || !validPassword(password)) {
      return json({ error: "The recovery request is invalid or expired." }, 400);
    }
    const userId = await rpc("nipto_native_consume_reset_grant", {
      p_grant_hash: await sha256Hex(grant),
      p_new_password_hash: await hashPassword(password),
    });
    if (!userId) return json({ error: "The recovery request is invalid or expired." }, 400);
    return json({ ok: true, message: "Password updated. Sign in with your new password." });
  }
  if (path.endsWith("/recovery/contacts") && method === "GET") {
    const claims = await verifyAccessToken(request);
    const rows = await rpc("nipto_native_list_recovery_contacts", { p_user_id: claims.sub });
    return json({ contacts: rows ?? [] });
  }
  if (path.endsWith("/recovery/link") && method === "POST") {
    const claims = await verifyAccessToken(request);
    const input = await body(request);
    const recoveryId = stringField(input.recovery_nipto_id, 24).trim().toLowerCase().replace(/^@/, "");
    if (!validNiptoId(recoveryId) || recoveryId === claims.nipto_id) {
      return json({ error: "Enter another valid Nipto ID." }, 400);
    }
    const requestId = await rpc("nipto_native_request_recovery_contact", {
      p_owner_id: claims.sub,
      p_nipto_id: recoveryId,
    });
    return json({ request_id: requestId, status: "pending" });
  }
  if (path.endsWith("/recovery/contact-response") && method === "POST") {
    const claims = await verifyAccessToken(request);
    const input = await body(request);
    const ok = await rpc("nipto_native_respond_recovery_contact", {
      p_request_id: stringField(input.request_id, 36),
      p_recovery_user_id: claims.sub,
      p_accept: input.accept === true,
    });
    return json({ ok: ok === true });
  }
  if (path.endsWith("/recovery/requests") && method === "GET") {
    const claims = await verifyAccessToken(request);
    const rows = await rpc("nipto_native_list_recovery_requests", {
      p_recovery_user_id: claims.sub,
    });
    return json({ requests: rows ?? [] });
  }
  if (path.endsWith("/recovery/respond") && method === "POST") {
    const claims = await verifyAccessToken(request);
    const input = await body(request);
    const ok = await rpc("nipto_native_respond_password_recovery", {
      p_challenge_id: stringField(input.challenge_id, 36),
      p_recovery_user_id: claims.sub,
      p_approve: input.approve === true,
    });
    return json({ ok: ok === true });
  }
  if (path.endsWith("/change-password") && method === "POST") {
    const claims = await verifyAccessToken(request);
    const input = await body(request);
    const currentPassword = stringField(input.current_password, 128);
    const newPassword = stringField(input.new_password, 128);
    if (!validPassword(newPassword)) return json({ error: "Use at least 12 characters for your new password." }, 400);
    const account = await accountRecord(claims.nipto_id);
    if (!account || account.user_id !== claims.sub
        || !(await verifyPassword(currentPassword, account.password_hash))) {
      return json({ error: "Current password is incorrect." }, 401);
    }
    const ok = await rpc("nipto_native_change_password", {
      p_user_id: claims.sub,
      p_new_password_hash: await hashPassword(newPassword),
    });
    return json({ ok: ok === true, message: "Password changed. Sign in again on your devices." });
  }

  return json({ error: "Not found" }, 404);
}

let dummyHashPromise: Promise<string> | undefined;
function dummyHash(): Promise<string> {
  dummyHashPromise ??= hashPassword(randomToken(32));
  return dummyHashPromise;
}

async function fetchProfile(userId: string): Promise<any> {
  const url = env("SUPABASE_URL").replace(/\/$/, "");
  const key = env("SUPABASE_SERVICE_ROLE_KEY");
  const response = await fetch(url + "/rest/v1/profiles?id=eq." + encodeURIComponent(userId)
    + "&select=id,nipto_id,display_name,account_state", {
    headers: { apikey: key, Authorization: "Bearer " + key },
  });
  if (!response.ok) throw new Error("Unable to load account");
  const rows = await response.json();
  const profile = Array.isArray(rows) ? rows[0] : null;
  if (!profile || profile.account_state !== "active") throw new Error("Account unavailable");
  return {
    user_id: profile.id,
    nipto_id: profile.nipto_id,
    display_name: profile.display_name,
  };
}

Deno.serve(async (request: Request) => {
  try {
    const response = await route(request);
    return response;
  } catch (error) {
    if (error instanceof SyntaxError) return json({ error: "Invalid request." }, 400);
    if (error instanceof Error && error.message === "RATE_LIMITED") {
      return new Response(JSON.stringify({ error: "Too many attempts. Try again later." }), {
        status: 429,
        headers: { ...corsHeaders, "Retry-After": "900" },
      });
    }
    // Do not log request bodies, credentials, tokens, hashes, or provider payloads.
    return json({ error: "Nipto identity service is temporarily unavailable." }, 503);
  }
});
