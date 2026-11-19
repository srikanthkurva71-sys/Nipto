import "jsr:@supabase/functions-js/edge-runtime.d.ts";
import { argon2id, argon2Verify } from "npm:hash-wasm@4.13.0";
import { isAllowedOidcScope, isValidNiptoId, isValidPassword, passwordsMatch } from "./validation.ts";

type Json = Record<string, unknown>;

const encoder = new TextEncoder();
const decoder = new TextDecoder();
const ARGON2 = { iterations: 3, memorySize: 65_536, parallelism: 1, hashLength: 32, outputType: "encoded" as const };

class ApiError extends Error {
  constructor(message: string, readonly status = 400) { super(message); }
}

function env(name: string): string {
  const value = Deno.env.get(name);
  if (!value) throw new ApiError(`Server configuration missing: ${name}`, 503);
  return value;
}
function supabaseUrl(): string { return env("SUPABASE_URL").replace(/\/$/, ""); }
function publishableKey(): string {
  return Deno.env.get("SUPABASE_PUBLISHABLE_KEY") ?? env("SUPABASE_ANON_KEY");
}
function issuer(): string {
  return (Deno.env.get("NIPTO_OIDC_ISSUER") ?? (supabaseUrl() + "/functions/v1/nipto-identity")).replace(/\/$/, "");
}
function oidcClientId(): string { return env("NIPTO_OIDC_CLIENT_ID"); }
function oidcClientSecret(): string { return env("NIPTO_OIDC_CLIENT_SECRET"); }
function oidcRedirectUri(): string {
  return Deno.env.get("NIPTO_OIDC_REDIRECT_URI") ??
    (supabaseUrl() + "/auth/v1/callback");
}
function keyId(): string { return env("NIPTO_OIDC_KID"); }

function json(data: unknown, status = 200, extra: HeadersInit = {}): Response {
  return new Response(JSON.stringify(data), {
    status,
    headers: {
      "Content-Type": "application/json; charset=utf-8",
      "Cache-Control": "no-store",
      "Access-Control-Allow-Origin": "*",
      "Access-Control-Allow-Headers": "authorization, apikey, content-type",
      "Access-Control-Allow-Methods": "GET, POST, OPTIONS",
      ...extra,
    },
  });
}
function html(content: string, status = 200): Response {
  return new Response(content, {
    status,
    headers: {
      "Content-Type": "text/html; charset=utf-8",
      "Cache-Control": "no-store",
      "X-Content-Type-Options": "nosniff",
      "Referrer-Policy": "no-referrer",
      "Content-Security-Policy": "default-src 'none'; style-src 'unsafe-inline'; script-src 'unsafe-inline'; connect-src 'self'; form-action 'self'; base-uri 'none'; frame-ancestors 'none'",
    },
  });
}
function redirect(url: string): Response {
  return new Response(null, {
    status: 302,
    headers: { Location: url, "Cache-Control": "no-store" },
  });
}
function htmlEscape(value: string): string {
  return value.replaceAll("&", "&amp;").replaceAll("<", "&lt;")
    .replaceAll(">", "&gt;").replaceAll('"', "&quot;").replaceAll("'", "&#39;");
}
function randomToken(bytes = 32): string {
  const data = crypto.getRandomValues(new Uint8Array(bytes));
  return base64url(data);
}
function base64url(bytes: Uint8Array): string {
  let binary = "";
  for (const byte of bytes) binary += String.fromCharCode(byte);
  return btoa(binary).replaceAll("+", "-").replaceAll("/", "_").replaceAll("=", "");
}
function base64Standard(bytes: Uint8Array): string {
  let binary = "";
  for (const byte of bytes) binary += String.fromCharCode(byte);
  return btoa(binary);
}
function fromBase64url(value: string): ArrayBuffer {
  const normalized = value.replaceAll("-", "+").replaceAll("_", "/");
  const binary = atob(normalized + "=".repeat((4 - normalized.length % 4) % 4));
  const bytes = new Uint8Array(binary.length);
  for (let index = 0; index < binary.length; index += 1) bytes[index] = binary.charCodeAt(index);
  return bytes.buffer;
}
async function sha256Hex(value: string): Promise<string> {
  const digest = await crypto.subtle.digest("SHA-256", encoder.encode(value));
  return [...new Uint8Array(digest)].map((b) => b.toString(16).padStart(2, "0")).join("");
}
async function sha256Base64Url(value: string): Promise<string> {
  const digest = await crypto.subtle.digest("SHA-256", encoder.encode(value));
  return base64url(new Uint8Array(digest));
}
async function hmacHex(value: string): Promise<string> {
  const key = await crypto.subtle.importKey(
    "raw", encoder.encode(env("SUPABASE_SERVICE_ROLE_KEY")),
    { name: "HMAC", hash: "SHA-256" }, false, ["sign"],
  );
  const result = await crypto.subtle.sign("HMAC", key, encoder.encode(value));
  return [...new Uint8Array(result)].map((b) => b.toString(16).padStart(2, "0")).join("");
}
function constantTimeEqual(a: string, b: string): boolean {
  const left = encoder.encode(a);
  const right = encoder.encode(b);
  if (left.length !== right.length) return false;
  let mismatch = 0;
  for (let i = 0; i < left.length; i += 1) mismatch |= left[i] ^ right[i];
  return mismatch === 0;
}

async function hashPassword(password: string): Promise<string> {
  return await argon2id({
    password, salt: crypto.getRandomValues(new Uint8Array(16)), ...ARGON2,
  });
}
async function verifyPassword(password: string, hash: string): Promise<boolean> {
  try { return await argon2Verify({ password, hash }); } catch { return false; }
}

let signingKeyPromise: Promise<CryptoKey> | undefined;
async function signingKey(): Promise<CryptoKey> {
  if (!signingKeyPromise) {
    const jwk = JSON.parse(env("NIPTO_OIDC_PRIVATE_JWK")) as JsonWebKey;
    signingKeyPromise = crypto.subtle.importKey(
      "jwk", jwk, { name: "ECDSA", namedCurve: "P-256" }, false, ["sign"],
    );
  }
  return signingKeyPromise;
}
function publicJwkFromPrivate(): Json {
  const jwk = JSON.parse(env("NIPTO_OIDC_PRIVATE_JWK")) as Record<string, unknown>;
  return {
    kty: "EC", crv: "P-256", x: jwk.x, y: jwk.y,
    use: "sig", alg: "ES256", kid: keyId(),
  };
}
function publicJwkSet(): Json[] {
  const raw = Deno.env.get("NIPTO_OIDC_PUBLIC_KEYS");
  const configured: unknown = raw ? JSON.parse(raw) : [];
  const result: Json[] = [];
  if (Array.isArray(configured)) {
    for (const value of configured) {
      if (typeof value !== "object" || value === null) continue;
      const jwk = value as Record<string, unknown>;
      if (jwk.kty !== "EC" || jwk.crv !== "P-256"
        || typeof jwk.x !== "string" || typeof jwk.y !== "string"
        || typeof jwk.kid !== "string" || jwk.kid === keyId()) continue;
      result.push({
        kty: "EC", crv: "P-256", x: jwk.x, y: jwk.y,
        use: "sig", alg: "ES256", kid: jwk.kid,
      });
    }
  }
  result.push(publicJwkFromPrivate());
  return result;
}
const verificationKeys = new Map<string, Promise<CryptoKey>>();
async function verificationKey(kid: string): Promise<CryptoKey> {
  let pending = verificationKeys.get(kid);
  if (!pending) {
    const jwk = publicJwkSet().find((key) => key.kid === kid);
    if (!jwk) throw new ApiError("Invalid token signing key", 401);
    pending = crypto.subtle.importKey(
      "jwk", jwk as JsonWebKey, { name: "ECDSA", namedCurve: "P-256" }, false, ["verify"],
    );
    verificationKeys.set(kid, pending);
  }
  return await pending;
}
async function signJwt(claims: Json): Promise<string> {
  const header = base64url(encoder.encode(JSON.stringify({
    alg: "ES256", typ: "JWT", kid: keyId(),
  })));
  const payload = base64url(encoder.encode(JSON.stringify(claims)));
  const input = header + "." + payload;
  const signature = await crypto.subtle.sign(
    { name: "ECDSA", hash: "SHA-256" }, await signingKey(), encoder.encode(input),
  );
  return input + "." + base64url(new Uint8Array(signature));
}
async function verifyJwt(token: string, tokenUse: string): Promise<Json> {
  const parts = token.split(".");
  if (parts.length !== 3) throw new ApiError("Invalid token", 401);
  const header = JSON.parse(decoder.decode(fromBase64url(parts[0]))) as Json;
  const claims = JSON.parse(decoder.decode(fromBase64url(parts[1]))) as Json;
  if (header.alg !== "ES256" || typeof header.kid !== "string") {
    throw new ApiError("Invalid token", 401);
  }
  const valid = await crypto.subtle.verify(
    { name: "ECDSA", hash: "SHA-256" },
    await verificationKey(header.kid),
    fromBase64url(parts[2]),
    encoder.encode(parts[0] + "." + parts[1]),
  );
  const now = Math.floor(Date.now() / 1000);
  if (!valid || claims.iss !== issuer() || claims.aud !== oidcClientId()
    || typeof claims.exp !== "number" || claims.exp <= now
    || claims.token_use !== tokenUse) {
    throw new ApiError("Invalid or expired token", 401);
  }
  return claims;
}

async function rpc(name: string, args: Json): Promise<any> {
  const response = await fetch(supabaseUrl() + "/rest/v1/rpc/" + name, {
    method: "POST",
    headers: {
      apikey: env("SUPABASE_SERVICE_ROLE_KEY"),
      Authorization: "Bearer " + env("SUPABASE_SERVICE_ROLE_KEY"),
      "Content-Type": "application/json",
    },
    body: JSON.stringify(args),
  });
  const raw = await response.text();
  if (!response.ok) {
    let databaseCode = "";
    try {
      const failure = JSON.parse(raw);
      databaseCode = typeof failure.code === "string" ? failure.code : "";
    } catch { /* Keep database details private. */ }
    if (response.status === 409 || databaseCode === "23505") {
      throw new ApiError("That Nipto ID is no longer available. Choose another ID.", 409);
    }
    if (databaseCode === "P0001") {
      throw new ApiError("That Nipto account or recovery choice cannot be used for this action.", 400);
    }
    throw new ApiError("Nipto service could not complete the request", 503);
  }
  return raw ? JSON.parse(raw) : null;
}
function firstRow(value: any): Json | null {
  if (Array.isArray(value) && value.length > 0 && typeof value[0] === "object") return value[0] as Json;
  if (typeof value === "object" && value !== null) return value as Json;
  return null;
}
async function enforceRateLimit(request: Request, key: string): Promise<void> {
  const ip = request.headers.get("cf-connecting-ip")
    ?? request.headers.get("x-real-ip")
    ?? request.headers.get("x-forwarded-for")?.split(",").at(-1)?.trim()
    ?? "unknown";
  const allowed = await rpc("consume_nipto_login_attempt", {
    p_key_hash: await hmacHex(ip + ":" + key),
  });
  if (allowed !== true) throw new ApiError("Too many attempts. Please wait and try again.", 429);
}
async function readLimitedBody(request: Request, maxBytes = 16_384): Promise<Uint8Array> {
  const length = Number(request.headers.get("content-length") ?? "0");
  if (length > maxBytes) throw new ApiError("Request is too large", 413);
  if (!request.body) throw new ApiError("Invalid request", 400);

  const reader = request.body.getReader();
  const chunks: Uint8Array[] = [];
  let total = 0;
  while (true) {
    const { done, value } = await reader.read();
    if (done) break;
    total += value.byteLength;
    if (total > maxBytes) {
      await reader.cancel();
      throw new ApiError("Request is too large", 413);
    }
    chunks.push(value);
  }

  const bytes = new Uint8Array(total);
  let offset = 0;
  for (const chunk of chunks) {
    bytes.set(chunk, offset);
    offset += chunk.byteLength;
  }
  return bytes;
}

async function requestBody(request: Request): Promise<Json> {
  if (request.headers.get("content-type")?.split(";")[0].trim().toLowerCase() !== "application/json") {
    throw new ApiError("A JSON request body is required", 415);
  }
  const bytes = await readLimitedBody(request);
  let value: unknown;
  try {
    value = JSON.parse(new TextDecoder("utf-8", { fatal: true }).decode(bytes));
  } catch {
    throw new ApiError("Invalid JSON request", 400);
  }
  if (typeof value !== "object" || value === null || Array.isArray(value)) {
    throw new ApiError("Invalid request", 400);
  }
  return value as Json;
}
async function authenticatedUserId(request: Request): Promise<string> {
  const authorization = request.headers.get("authorization") ?? "";
  if (!/^Bearer [A-Za-z0-9._-]+$/.test(authorization)) {
    throw new ApiError("Sign in to continue", 401);
  }
  const response = await fetch(supabaseUrl() + "/rest/v1/rpc/nipto_native_current_user", {
    method: "POST",
    headers: {
      apikey: publishableKey(),
      Authorization: authorization,
      "Content-Type": "application/json",
    },
    body: "{}",
  });
  if (!response.ok) throw new ApiError("Sign in to continue", 401);
  const userId = await response.json();
  if (typeof userId !== "string" || !/^[0-9a-f-]{36}$/i.test(userId)) {
    throw new ApiError("Sign in to continue", 401);
  }
  return userId;
}
async function rpcAsUser(request: Request, name: string): Promise<any> {
  const authorization = request.headers.get("authorization") ?? "";
  const response = await fetch(supabaseUrl() + "/rest/v1/rpc/" + name, {
    method: "POST",
    headers: {
      apikey: publishableKey(),
      Authorization: authorization,
      "Content-Type": "application/json",
    },
    body: "{}",
  });
  if (!response.ok) throw new ApiError("Account update could not be completed", 400);
  return await response.json();
}

function discoveryDocument(): Json {
  const base = issuer();
  return {
    issuer: base,
    authorization_endpoint: base + "/authorize",
    token_endpoint: base + "/token",
    userinfo_endpoint: base + "/userinfo",
    jwks_uri: base + "/jwks",
    response_types_supported: ["code"],
    subject_types_supported: ["public"],
    id_token_signing_alg_values_supported: ["ES256"],
    scopes_supported: ["openid", "profile"],
    grant_types_supported: ["authorization_code"],
    token_endpoint_auth_methods_supported: ["client_secret_basic", "client_secret_post"],
    code_challenge_methods_supported: ["S256"],
    claims_supported: ["sub", "iss", "aud", "exp", "iat", "nonce", "nipto_id", "preferred_username", "name", "display_name"],
  };
}
function buildSwitchUrl(url: URL, screen: string): string {
  const next = new URL(issuer() + "/authorize");
  for (const key of ["client_id","redirect_uri","response_type","scope","state","nonce","code_challenge","code_challenge_method"]) {
    const value = url.searchParams.get(key);
    if (value) next.searchParams.set(key, value);
  }
  next.searchParams.set("screen", screen);
  return next.toString();
}
function renderAuthorizePage(input: {
  transactionId: string; csrfToken: string; screen: string; error?: string; switchUrl: string; niptoId?: string;
}): string {
  const isRegister = input.screen === "register";
  const isLink = input.screen === "link";
  const error = input.error ? `<p class="error">${htmlEscape(input.error)}</p>` : "";
  const fields = isRegister
    ? `<label>Display name<input name="display_name" maxlength="50" autocomplete="name" required></label>`
    : "";
  const registrationTools = isRegister
    ? `<div id="id-feedback" class="feedback" aria-live="polite">Choose a Nipto ID. We will check availability.</div>
       <div id="id-suggestions" class="suggestions" aria-live="polite"></div>`
    : "";
  const passwordTools = isRegister || isLink
    ? `<div class="password-tools"><button type="button" class="secondary" id="suggest-password">Suggest a strong password</button>
       <button type="button" class="secondary" id="toggle-password" aria-label="Show password">Show</button></div>
       <div id="password-feedback" class="feedback" aria-live="polite">Use at least 12 characters. A unique password is safest.</div>`
    : `<div class="password-tools"><button type="button" class="secondary" id="toggle-password" aria-label="Show password">Show password</button></div>`;
  return `<!doctype html><html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
    <title>${isRegister ? "Create your Nipto account" : isLink ? "Set your Nipto password" : "Sign in to Nipto"}</title>
    <style>
      :root{color-scheme:light;--ink:#17152b;--muted:#77758b;--brand:#6554e8;--brand-dark:#5140d1;--line:#e8e6f1;--surface:#fff;--soft:#f5f3ff}
      *{box-sizing:border-box}
      body{margin:0;min-height:100vh;padding:36px 20px;display:grid;place-items:center;color:var(--ink);font:16px/1.5 Inter,ui-sans-serif,system-ui,-apple-system,BlinkMacSystemFont,"Segoe UI",sans-serif;background:radial-gradient(ellipse at 12% 12%,#ded9ff 0,transparent 38%),radial-gradient(ellipse at 90% 88%,#d9f3f0 0,transparent 34%),linear-gradient(135deg,#f8f7ff,#f4f7fc)}
      main{position:relative;width:min(100%,470px);padding:38px 40px 30px;background:rgba(255,255,255,.96);border:1px solid rgba(255,255,255,.9);border-radius:28px;box-shadow:0 28px 90px rgba(42,34,92,.13),0 3px 12px rgba(42,34,92,.04);overflow:hidden}
      main:before{content:"";position:absolute;inset:0 0 auto;height:5px;background:linear-gradient(90deg,#7968ff,#4c9ce8,#4dc9b4)}
      .brand{display:flex;align-items:center;justify-content:center;gap:10px;margin:0 auto 24px;color:#211d45;font-size:21px;font-weight:900;letter-spacing:3.5px}
      .brand:before{content:"N";display:grid;place-items:center;width:38px;height:38px;border-radius:13px;background:linear-gradient(145deg,#7868ff,#5542d8);color:white;font-size:20px;letter-spacing:0;box-shadow:0 6px 16px #6657e844}
      h1{margin:0;text-align:center;font-size:clamp(25px,5vw,30px);line-height:1.2;letter-spacing:-.8px;font-weight:800}
      p{margin:12px 0 22px;color:var(--muted);line-height:1.65;text-align:center;font-size:14px}
      label{display:block;margin:17px 0 0;color:#302d46;font-size:13px;font-weight:700;letter-spacing:.1px}
      input{display:block;width:100%;height:50px;margin-top:8px;padding:0 15px;border:1px solid #dfddea;border-radius:13px;background:#fcfcff;color:var(--ink);font:inherit;font-size:15px;outline:none;transition:border-color .18s,box-shadow .18s,background .18s}
      input:hover{border-color:#c7c1eb}input:focus{border-color:var(--brand);background:white;box-shadow:0 0 0 4px #6554e817}
      input::placeholder{color:#aaa8b8}
      button{display:block;width:100%;min-height:51px;margin-top:24px;padding:13px 18px;border:0;border-radius:14px;background:linear-gradient(135deg,#7565f5,#5846dc);color:#fff;font:inherit;font-weight:750;font-size:15px;letter-spacing:.1px;cursor:pointer;box-shadow:0 8px 18px #6554e833;transition:transform .15s,box-shadow .15s,opacity .15s}
      button:hover:not(:disabled){transform:translateY(-1px);box-shadow:0 11px 22px #6554e83d}
      button:focus-visible,a:focus-visible{outline:3px solid #a69cff;outline-offset:3px}
      button:disabled{opacity:.48;cursor:not-allowed;box-shadow:none}
      .feedback{min-height:20px;margin-top:8px;color:var(--muted);font-size:12px;line-height:1.45}
      .feedback.good{color:#16804f}.feedback.bad{color:#b42318}
      .suggestions{display:flex;flex-wrap:wrap;gap:8px;margin-top:8px}
      .suggestions button,.password-tools .secondary{display:inline-flex;align-items:center;justify-content:center;width:auto;min-height:34px;margin:0;padding:7px 11px;border:1px solid #e1ddff;border-radius:10px;background:#f4f2ff;color:#5142ca;font-size:12px;font-weight:700;box-shadow:none}
      .suggestions button:hover,.password-tools .secondary:hover{background:#eae7ff;box-shadow:none}
      .password-tools{display:flex;align-items:center;justify-content:space-between;gap:10px;margin-top:10px}
      .password-tools button{flex:0 0 auto}
      a{display:block;margin-top:20px;color:var(--brand-dark);text-align:center;text-decoration:none;font-size:14px;font-weight:700}
      a:hover{text-decoration:underline}
      .error{margin:0 0 16px;padding:12px 14px;border:1px solid #ffd8d8;border-radius:12px;background:#fff4f4;color:#a32121;text-align:left;font-size:13px}
      .hint{margin:22px 0 0;padding-top:17px;border-top:1px solid #f0eef6;color:#9996a8;font-size:11px}
      @media(max-width:520px){body{padding:16px 12px;align-items:center;background:linear-gradient(160deg,#eeebff,#f7f9fd 60%,#e9f7f5)}main{padding:30px 23px 24px;border-radius:23px}.brand{margin-bottom:20px}}
      @media(prefers-reduced-motion:reduce){*,*:before,*:after{scroll-behavior:auto!important;transition:none!important}}
    </style></head><body><main><div class="brand">NIPTO</div>
    <h1>${isRegister ? "Create your Nipto account" : isLink ? "Set your Nipto password" : "Welcome back"}</h1>
    <p>${isRegister ? "Choose your Nipto ID and password. No email or phone number is required." : isLink ? "Create a Nipto password for the account already signed in on this device. No email is required." : "Sign in with your Nipto ID and password. No email is required."}</p>
    ${error}
    <form method="post" action="${issuer()}/authorize">
      <input type="hidden" name="transaction_id" value="${htmlEscape(input.transactionId)}">
      <input type="hidden" name="csrf_token" value="${htmlEscape(input.csrfToken)}">
      <input type="hidden" name="action" value="${isRegister ? "register" : isLink ? "link" : "login"}">
      ${fields}
      ${isLink ? "" : `<label>Nipto ID<input name="nipto_id" id="nipto-id" value="${htmlEscape(input.niptoId ?? "")}" maxlength="24" autocomplete="username" autocapitalize="none" spellcheck="false" required></label>${registrationTools}`}
      <label>Password<input name="password" id="nipto-password" type="password" minlength="12" maxlength="128" autocomplete="${isRegister || isLink ? "new-password" : "current-password"}" required></label>
      ${isRegister || isLink ? `<label>Confirm password<input name="password_confirmation" id="nipto-password-confirmation" type="password" minlength="12" maxlength="128" autocomplete="new-password" required></label>` : ""}
      ${passwordTools}
      <button type="submit" id="submit-auth">${isRegister ? "Create account" : isLink ? "Link Nipto account" : "Sign in"}</button>
    </form>
    ${isLink ? "" : `<a href="${input.switchUrl}">${isRegister ? "Already have a Nipto account? Sign in" : "New to Nipto? Create an account"}</a>`}
    <p class="hint">Your Nipto password is handled by Nipto. It is never sent to an email provider.</p>
    </main>
    <script>
      (() => {
        const form = document.querySelector("form");
        const password = document.getElementById("nipto-password");
        const confirmation = document.getElementById("nipto-password-confirmation");
        const suggest = document.getElementById("suggest-password");
        const toggle = document.getElementById("toggle-password");
        const passwordFeedback = document.getElementById("password-feedback");
        if (password && suggest) {
          suggest.addEventListener("click", () => {
            const lower = "abcdefghijkmnopqrstuvwxyz";
            const upper = "ABCDEFGHJKLMNPQRSTUVWXYZ";
            const digits = "23456789";
            const symbols = "!@#$%^&*()-_=+";
            const all = lower + upper + digits + symbols;
            const randomIndex = (max) => {
              const limit = Math.floor(0x100000000 / max) * max;
              let value;
              do { value = crypto.getRandomValues(new Uint32Array(1))[0]; } while (value >= limit);
              return value % max;
            };
            const chars = [lower[randomIndex(lower.length)], upper[randomIndex(upper.length)],
              digits[randomIndex(digits.length)], symbols[randomIndex(symbols.length)]];
            while (chars.length < 20) chars.push(all[randomIndex(all.length)]);
            for (let i = chars.length - 1; i > 0; i--) {
              const j = randomIndex(i + 1); [chars[i], chars[j]] = [chars[j], chars[i]];
            }
            password.value = chars.join("");
            if (confirmation) confirmation.value = password.value;
            password.type = "text";
            if (confirmation) confirmation.type = "text";
            if (toggle) toggle.textContent = "Hide";
            passwordFeedback.textContent = "Strong 20-character password generated on this device. Save it in a trusted password manager.";
            passwordFeedback.className = "feedback good";
            password.dispatchEvent(new Event("input", { bubbles: true }));
            if (confirmation) confirmation.dispatchEvent(new Event("input", { bubbles: true }));
          });
          password.addEventListener("input", () => {
            const value = password.value;
            const checks = [value.length >= 12, /[a-z]/.test(value), /[A-Z]/.test(value),
              /[0-9]/.test(value), /[^A-Za-z0-9]/.test(value)];
            const score = checks.filter(Boolean).length;
            passwordFeedback.textContent = score >= 5 ? "Strong password." :
              score >= 3 ? "Good start. Add length and character variety." :
              "Use at least 12 characters with a mix of character types.";
            passwordFeedback.className = "feedback " + (score >= 5 ? "good" : "");
          });
        }
        if (toggle && password) toggle.addEventListener("click", () => {
          password.type = password.type === "password" ? "text" : "password";
          if (confirmation) confirmation.type = password.type;
          toggle.textContent = password.type === "password" ? "Show" : "Hide";
        });
        if (confirmation && password) {
          confirmation.addEventListener("input", () => {
            confirmation.setCustomValidity(confirmation.value === password.value
              ? "" : "Passwords do not match.");
          });
          password.addEventListener("input", () => {
            if (confirmation.value) confirmation.setCustomValidity(
              confirmation.value === password.value ? "" : "Passwords do not match.");
          });
        }
        const idInput = document.getElementById("nipto-id");
        const feedback = document.getElementById("id-feedback");
        const suggestions = document.getElementById("id-suggestions");
        const submit = document.getElementById("submit-auth");
        if (idInput && feedback && suggestions && submit) {
          let timer = 0;
          let lastChecked = "";
          let available = false;
          const checkId = async () => {
            const value = idInput.value.trim().replace(/^@/, "").toLowerCase();
            available = false;
            lastChecked = "";
            suggestions.replaceChildren();
            if (value.length < 3 || value.length > 24 || !/^[a-z0-9]+(?:_[a-z0-9]+)*$/.test(value)) {
              feedback.textContent = "Use 3–24 lowercase letters or numbers, with single underscores between parts.";
              feedback.className = "feedback";
              submit.disabled = true;
              return;
            }
            feedback.textContent = "Checking availability…";
            feedback.className = "feedback";
            try {
              const response = await fetch("${issuer()}/id/check", {
                method: "POST", headers: { "Content-Type": "application/json" },
                body: JSON.stringify({ nipto_id: value })
              });
              if (!response.ok) throw new Error("check_failed");
              const result = await response.json();
              if (idInput.value.trim().replace(/^@/, "").toLowerCase() !== value) return;
              lastChecked = value;
              available = result.available === true;
              feedback.textContent = available ? "✓ This Nipto ID is available." :
                "This Nipto ID already exists or cannot be used. Try one of these:";
              feedback.className = "feedback " + (available ? "good" : "bad");
              submit.disabled = !available;
              for (const candidate of (result.suggestions || []).slice(0, 5)) {
                const button = document.createElement("button");
                button.type = "button"; button.textContent = "@" + candidate;
                button.addEventListener("click", () => {
                  idInput.value = candidate;
                  idInput.dispatchEvent(new Event("input", { bubbles: true }));
                });
                suggestions.append(button);
              }
            } catch (_) {
              feedback.textContent = "Could not check right now. Please try again.";
              feedback.className = "feedback bad";
              submit.disabled = true;
            }
          };
          idInput.addEventListener("input", () => {
            clearTimeout(timer); available = false; submit.disabled = true;
            timer = setTimeout(checkId, 350);
          });
          form.addEventListener("submit", (event) => {
            const value = idInput.value.trim().replace(/^@/, "").toLowerCase();
            if (!available || lastChecked !== value) {
              event.preventDefault(); checkId();
            }
          });
          submit.disabled = true;
        }
      })();
    </script>
    </body></html>`;
}
async function authorizeGet(request: Request): Promise<Response> {
  const url = new URL(request.url);
  const client = url.searchParams.get("client_id") ?? "";
  const redirectUri = url.searchParams.get("redirect_uri") ?? "";
  const responseType = url.searchParams.get("response_type") ?? "";
  const scope = url.searchParams.get("scope") ?? "";
  const state = url.searchParams.get("state") ?? "";
  const nonce = url.searchParams.get("nonce");
  const challenge = url.searchParams.get("code_challenge") ?? "";
  const method = url.searchParams.get("code_challenge_method") ?? "";
  if (client !== oidcClientId() || redirectUri !== oidcRedirectUri()
    || responseType !== "code" || !isAllowedOidcScope(scope) || !state || state.length > 512
    || (nonce !== null && (nonce.length === 0 || nonce.length > 512)) || method !== "S256"
    || !/^[A-Za-z0-9_-]{43,128}$/.test(challenge)) {
    throw new ApiError("Invalid Nipto authorization request", 400);
  }
  const csrf = randomToken(32);
  const requestedScreen = url.searchParams.get("screen");
  const screen = requestedScreen === "register" ? "register" : requestedScreen === "link" ? "link" : "login";
  const migrationTicket = url.searchParams.get("migration_ticket");
  if (screen === "link" && (!migrationTicket || !/^[A-Za-z0-9_-]{43,128}$/.test(migrationTicket))) {
    throw new ApiError("This account-link request is invalid. Return to Nipto and try again.", 400);
  }
  await enforceRateLimit(request, "oidc-authorize:" + client);
  const transactionId = await rpc("nipto_oidc_create_transaction", {
    p_client_id: client,
    p_redirect_uri: redirectUri,
    p_scope: scope,
    p_state: state,
    p_nonce: nonce,
    p_code_challenge: challenge,
    p_csrf_hash: await sha256Hex(csrf),
    p_migration_ticket_hash: migrationTicket ? await sha256Hex(migrationTicket) : null,
  });
  return html(renderAuthorizePage({
    transactionId: String(transactionId),
    csrfToken: csrf,
    screen,
    switchUrl: screen === "link" ? "" : buildSwitchUrl(url, screen === "register" ? "login" : "register"),
  }));
}
async function authorizePost(request: Request): Promise<Response> {
  const contentType = request.headers.get("content-type") ?? "";
  if (!/^application\/x-www-form-urlencoded(?:;|$)/i.test(contentType)
    && !/^multipart\/form-data;\s*boundary=/i.test(contentType)) {
    throw new ApiError("A form submission is required", 415);
  }
  const formBytes = await readLimitedBody(request);
  const form = await new Response(new TextDecoder().decode(formBytes), {
    headers: { "Content-Type": contentType },
  }).formData();
  const transactionId = String(form.get("transaction_id") ?? "");
  const csrfToken = String(form.get("csrf_token") ?? "");
  const action = String(form.get("action") ?? "login");
  const niptoId = String(form.get("nipto_id") ?? "").trim().replace(/^@/, "").toLowerCase();
  const password = String(form.get("password") ?? "");
  const displayName = String(form.get("display_name") ?? "").trim();
  const passwordConfirmation = String(form.get("password_confirmation") ?? "");
  const txRows = await rpc("nipto_oidc_get_transaction", {
    p_id: transactionId,
    p_csrf_hash: await sha256Hex(csrfToken),
  });
  const tx = firstRow(txRows);
  if (!tx) throw new ApiError("This sign-in request expired. Return to Nipto and try again.", 410);
  const screen = action === "register" ? "register" : action === "link" ? "link" : "login";
  const switchParams = new URLSearchParams({
    client_id: String(tx.client_id),
    redirect_uri: String(tx.redirect_uri),
    response_type: "code",
    scope: String(tx.scope),
    state: String(tx.state),
    code_challenge: String(tx.code_challenge),
    code_challenge_method: "S256",
  });
  if (tx.nonce !== null && tx.nonce !== undefined) switchParams.set("nonce", String(tx.nonce));
  const switchUrl = screen === "link" ? "" : buildSwitchUrl(new URL(
    issuer() + "/authorize?" + switchParams.toString(),
  ), screen === "register" ? "login" : "register");

  try {
    if ((action === "register" || action === "link") && !passwordsMatch(password, passwordConfirmation)) {
      throw new ApiError("Passwords do not match. Please confirm your password.", 400);
    }
    if (!isValidPassword(password) || (action !== "link" && !isValidNiptoId(niptoId))) {
      throw new ApiError("Check your Nipto ID and password.", 400);
    }
    await enforceRateLimit(request, "oidc:" + (niptoId || transactionId));
    let identityId: string;

    if (action === "link") {
      const ticketHash = String(tx.migration_ticket_hash ?? "");
      if (!/^[a-f0-9]{64}$/.test(ticketHash)) {
        throw new ApiError("This account-link request expired. Return to Nipto and try again.", 410);
      }
      const migration = firstRow(await rpc("nipto_oidc_consume_migration_ticket", {
        p_ticket_hash: ticketHash,
      }));
      if (!migration) throw new ApiError("This account-link request expired. Return to Nipto and try again.", 410);
      const passwordHash = await hashPassword(password);
      const created = await rpc("nipto_oidc_register_legacy", {
        p_user_id: migration.user_id,
        p_nipto_id: migration.nipto_id,
        p_display_name: migration.display_name,
        p_password_hash: passwordHash,
      });
      if (typeof created !== "string") throw new ApiError("Nipto account could not be linked.", 409);
      identityId = created;
    } else if (action === "register") {
      if (displayName.length < 1 || displayName.length > 50) {
        throw new ApiError("Enter a display name between 1 and 50 characters.", 400);
      }
      const availability = firstRow(await rpc("nipto_oidc_check_id", { p_nipto_id: niptoId }));
      if (!availability || availability.available !== true) {
        throw new ApiError("That Nipto ID already exists or cannot be used. Choose one of the suggested IDs.", 409);
      }
      const passwordHash = await hashPassword(password);
        const created = await rpc("nipto_oidc_register", {
          p_nipto_id: niptoId,
          p_display_name: displayName,
          p_password_hash: passwordHash,
        });
      if (typeof created !== "string") throw new ApiError("That Nipto ID is unavailable.", 409);
      identityId = created;
    } else {
      const record = firstRow(await rpc("nipto_oidc_login_record", { p_nipto_id: niptoId }));
      if (!record || typeof record.password_hash !== "string") {
        await hashPassword(password);
        throw new ApiError("The Nipto ID or password is incorrect.", 401);
      }
      const valid = await verifyPassword(password, record.password_hash);
      if (!valid || record.status !== "active") {
        throw new ApiError("The Nipto ID or password is incorrect.", 401);
      }
      identityId = String(record.identity_id);
    }

    const consumed = await rpc("nipto_oidc_consume_transaction", {
      p_id: transactionId,
      p_csrf_hash: await sha256Hex(csrfToken),
    });
    if (consumed !== true) throw new ApiError("This sign-in request expired. Try again.", 410);

    const code = randomToken(32);
    await rpc("nipto_oidc_create_code", {
      p_code_hash: await sha256Hex(code),
      p_identity_id: identityId,
      p_client_id: String(tx.client_id),
      p_redirect_uri: String(tx.redirect_uri),
      p_nonce: tx.nonce === null || tx.nonce === undefined ? null : String(tx.nonce),
      p_code_challenge: String(tx.code_challenge),
    });
    const destination = new URL(String(tx.redirect_uri));
    destination.searchParams.set("code", code);
    destination.searchParams.set("state", String(tx.state));
    return redirect(destination.toString());
  } catch (error) {
    const message = error instanceof ApiError ? error.message : "Nipto could not complete sign-in. Try again.";
    return html(renderAuthorizePage({
      transactionId,
      csrfToken,
      screen,
      error: message,
      switchUrl,
      niptoId,
    }), error instanceof ApiError ? error.status : 400);
  }
}

function parseBasicAuth(value: string): { id: string; secret: string } | null {
  if (!value.startsWith("Basic ")) return null;
  try {
    const decoded = atob(value.slice(6));
    const index = decoded.indexOf(":");
    if (index < 0) return null;
    return { id: decoded.slice(0, index), secret: decoded.slice(index + 1) };
  } catch { return null; }
}
async function tokenEndpoint(request: Request): Promise<Response> {
  const contentType = request.headers.get("content-type") ?? "";
  if (!/^application\\/x-www-form-urlencoded(?:;|$)/i.test(contentType)) {
    return json({ error: "invalid_request" }, 400);
  }
  // Bound token-exchange input before parsing; this endpoint is public to the
  // authorization server network and must not accept arbitrarily large bodies.
  const formBytes = await readLimitedBody(request, 8_192);
  let form: FormData;
  try {
    form = await new Response(formBytes, {
      headers: { "Content-Type": contentType },
    }).formData();
  } catch {
    return json({ error: "invalid_request" }, 400);
  }
  const basic = parseBasicAuth(request.headers.get("authorization") ?? "");
  const clientId = basic?.id ?? String(form.get("client_id") ?? "");
  const clientSecret = basic?.secret ?? String(form.get("client_secret") ?? "");
  if (clientId !== oidcClientId() || !constantTimeEqual(clientSecret, oidcClientSecret())) {
    return json({ error: "invalid_client" }, 401, { "WWW-Authenticate": "Basic" });
  }
  if (String(form.get("grant_type") ?? "") !== "authorization_code") {
    return json({ error: "unsupported_grant_type" }, 400);
  }
  const code = String(form.get("code") ?? "");
  const redirectUri = String(form.get("redirect_uri") ?? "");
  const verifier = String(form.get("code_verifier") ?? "");
  if (!code || redirectUri !== oidcRedirectUri()
    || !/^[A-Za-z0-9._~-]{43,128}$/.test(verifier)) {
    return json({ error: "invalid_grant" }, 400);
  }
  const challenge = await sha256Base64Url(verifier);
  const rows = await rpc("nipto_oidc_consume_code", {
    p_code_hash: await sha256Hex(code),
    p_client_id: clientId,
    p_redirect_uri: redirectUri,
    p_code_challenge: challenge,
  });
  const row = firstRow(rows);
  if (!row) return json({ error: "invalid_grant" }, 400);

  const now = Math.floor(Date.now() / 1000);
  const common = {
    iss: issuer(),
    sub: String(row.identity_id),
    aud: clientId,
    iat: now,
    nipto_id: String(row.nipto_id),
    preferred_username: String(row.nipto_id),
    display_name: String(row.display_name),
    name: String(row.display_name),
  };
  const idToken = await signJwt({
    ...common,
    exp: now + 300,
    auth_time: now,
    ...(row.nonce === null || row.nonce === undefined ? {} : { nonce: String(row.nonce) }),
  });
  const accessToken = await signJwt({
    ...common,
    exp: now + 3600,
    scope: "openid profile",
    token_use: "userinfo",
  });
  return json({
    access_token: accessToken,
    id_token: idToken,
    token_type: "Bearer",
    expires_in: 3600,
    scope: "openid profile",
  }, 200, { Pragma: "no-cache" });
}
async function userInfo(request: Request): Promise<Response> {
  const authorization = request.headers.get("authorization") ?? "";
  const token = authorization.replace(/^Bearer\s+/i, "");
  if (!token || token === authorization) throw new ApiError("Bearer token required", 401);
  const claims = await verifyJwt(token, "userinfo");
  return json({
    sub: claims.sub,
    nipto_id: claims.nipto_id,
    preferred_username: claims.preferred_username,
    name: claims.name,
    display_name: claims.display_name,
  });
}

async function handleRoute(request: Request): Promise<Response> {
  const url = new URL(request.url);
  const path = url.pathname;
  const method = request.method;

  if (method === "OPTIONS") return json({ ok: true });
  if (path.endsWith("/id/check") && method === "POST") {
    const input = await requestBody(request);
    const niptoId = String(input.nipto_id ?? "").trim().replace(/^@/, "").toLowerCase();
    await enforceRateLimit(request, "id-check:" + niptoId);
    const result = firstRow(await rpc("nipto_oidc_check_id", { p_nipto_id: niptoId }));
    if (!result) throw new ApiError("Nipto ID availability could not be checked.", 503);
    return json({
      available: result.available === true,
      suggestions: Array.isArray(result.suggestions) ? result.suggestions.slice(0, 5) : [],
    });
  }

  if (path.endsWith("/.well-known/openid-configuration") && method === "GET") {
    return json(discoveryDocument());
  }
  if (path.endsWith("/jwks") && method === "GET") return json({ keys: publicJwkSet() });
  if (path.endsWith("/authorize") && method === "GET") return await authorizeGet(request);
  if (path.endsWith("/authorize") && method === "POST") return await authorizePost(request);
  if (path.endsWith("/token") && method === "POST") return await tokenEndpoint(request);
  if (path.endsWith("/userinfo") && method === "GET") return await userInfo(request);

  if (path.endsWith("/turn-credentials") && method === "GET") {
    const userId = await authenticatedUserId(request);
    await enforceRateLimit(request, "turn-credentials:" + userId);
    const secret = Deno.env.get("TURN_SHARED_SECRET");
    const urls = (Deno.env.get("TURN_URLS") ?? "").split(",").map((x) => x.trim())
      .filter((x) => x.startsWith("turn:") || x.startsWith("turns:"));
    const stun = Deno.env.get("TURN_STUN_URL") ?? "";
    const iceServers: Json[] = [];
    if (stun.startsWith("stun:")) iceServers.push({ urls: stun });
    let expiresAt: number | null = null;
    if (secret && urls.length) {
      expiresAt = Math.floor(Date.now() / 1000) + 3600;
      const username = expiresAt + ":" + userId;
      const key = await crypto.subtle.importKey(
        "raw", encoder.encode(secret), { name: "HMAC", hash: "SHA-1" }, false, ["sign"],
      );
      const signed = await crypto.subtle.sign("HMAC", key, encoder.encode(username));
      iceServers.push({
        urls, username, credential: base64Standard(new Uint8Array(signed)), credentialType: "password",
      });
    }
    return json({ ice_servers: iceServers, turn_available: Boolean(secret && urls.length), expires_at: expiresAt });
  }

  if (path.endsWith("/recovery/start") && method === "POST") {
    const input = await requestBody(request);
    const niptoId = String(input.nipto_id ?? "").trim().replace(/^@/, "").toLowerCase();
    await enforceRateLimit(request, "recovery-start:" + niptoId);
    const challengeSecret = randomToken(32);
    const rows = await rpc("nipto_native_start_recovery", {
      p_nipto_id: niptoId,
      p_challenge_hash: await sha256Hex(challengeSecret),
    });
    const row = firstRow(rows);
    return json({
      status: "pending",
      challenge_id: row ? String(row.challenge_id) : crypto.randomUUID(),
      challenge_secret: challengeSecret,
    });
  }

  if (path.endsWith("/recovery/claim") && method === "POST") {
    const input = await requestBody(request);
    const challengeId = String(input.challenge_id ?? "");
    const challengeSecret = String(input.challenge_secret ?? "");
    await enforceRateLimit(request, "recovery-claim:" + challengeId);
    const challengeHash = await sha256Hex(challengeSecret);
    const status = await rpc("nipto_native_recovery_status", {
      p_challenge_id: challengeId, p_challenge_hash: challengeHash,
    });
    if (status === "rejected") return json({ status: "rejected" });
    if (status === "expired") return json({ status: "expired" });
    if (status === "consumed") return json({ status: "consumed" });
    if (status !== "approved") return json({ status: "pending" });
    const grant = randomToken(32);
    const owner = await rpc("nipto_native_claim_reset_grant", {
      p_challenge_id: challengeId,
      p_challenge_hash: challengeHash,
      p_grant_hash: await sha256Hex(grant),
    });
    return owner ? json({ status: "approved", reset_grant: grant }) : json({ status: "pending" });
  }

  if (path.endsWith("/recovery/reset") && method === "POST") {
    const input = await requestBody(request);
    const grant = String(input.reset_grant ?? "");
    const password = String(input.new_password ?? "");
    if (password.length < 12 || password.length > 128) {
      throw new ApiError("Use a password between 12 and 128 characters.");
    }
    await enforceRateLimit(request, "recovery-reset:" + await sha256Hex(grant));
    const userId = await rpc("nipto_native_consume_reset_grant", {
      p_grant_hash: await sha256Hex(grant),
      p_new_password_hash: await hashPassword(password),
    });
    if (typeof userId !== "string") throw new ApiError("This reset request is invalid or expired.", 400);
    // The SQL RPC atomically consumes the grant, changes the password and revokes sessions.
    return json({ ok: true });
  }

  if (path.endsWith("/recovery/contacts") && method === "GET") {
    const userId = await authenticatedUserId(request);
    const contacts = await rpc("nipto_native_list_recovery_contacts", { p_user_id: userId });
    return json({ contacts: contacts ?? [] });
  }
  if (path.endsWith("/recovery/requests") && method === "GET") {
    const userId = await authenticatedUserId(request);
    const requests = await rpc("nipto_native_list_recovery_requests", { p_recovery_user_id: userId });
    return json({ requests: requests ?? [] });
  }
  if (path.endsWith("/recovery/link") && method === "POST") {
    const userId = await authenticatedUserId(request);
    const input = await requestBody(request);
    const requestId = await rpc("nipto_native_request_recovery_contact", {
      p_owner_user_id: userId,
      p_nipto_id: String(input.recovery_nipto_id ?? "").trim().replace(/^@/, "").toLowerCase(),
    });
    return json({ request_id: requestId });
  }
  if (path.endsWith("/recovery/contact-response") && method === "POST") {
    const userId = await authenticatedUserId(request);
    const input = await requestBody(request);
    const ok = await rpc("nipto_native_respond_recovery_contact", {
      p_request_id: String(input.request_id ?? ""),
      p_recovery_user_id: userId,
      p_accept: input.accept === true,
    });
    if (ok !== true) throw new ApiError("Recovery request is no longer available.", 404);
    return json({ ok: true });
  }
  if (path.endsWith("/recovery/contact-remove") && method === "POST") {
    const userId = await authenticatedUserId(request);
    const input = await requestBody(request);
    const ok = await rpc("nipto_native_remove_recovery_contact", {
      p_user_id: userId,
      p_request_id: String(input.request_id ?? ""),
    });
    if (ok !== true) throw new ApiError("Recovery contact not found.", 404);
    return json({ ok: true });
  }
  if (path.endsWith("/recovery/respond") && method === "POST") {
    const userId = await authenticatedUserId(request);
    const input = await requestBody(request);
    const ok = await rpc("nipto_native_respond_password_recovery", {
      p_challenge_id: String(input.challenge_id ?? ""),
      p_recovery_user_id: userId,
      p_approve: input.approve === true,
    });
    if (ok !== true) throw new ApiError("This recovery request is no longer available.", 404);
    return json({ ok: true });
  }

  if (path.endsWith("/change-password") && method === "POST") {
    const userId = await authenticatedUserId(request);
    const input = await requestBody(request);
    const currentPassword = String(input.current_password ?? "");
    const newPassword = String(input.new_password ?? "");
    if (newPassword.length < 12 || newPassword.length > 128) {
      throw new ApiError("Use a password between 12 and 128 characters.");
    }
    const account = firstRow(await rpc("nipto_native_account_for_user", { p_user_id: userId }));
    if (!account || typeof account.password_hash !== "string"
      || !await verifyPassword(currentPassword, account.password_hash)) {
      throw new ApiError("Your current password is incorrect.", 401);
    }
    const ok = await rpc("nipto_native_change_password", {
      p_identity_id: account.identity_id,
      p_password_hash: await hashPassword(newPassword),
    });
    if (ok !== true) throw new ApiError("Password could not be updated.", 400);
    return json({ ok: true });
  }

  if (path.endsWith("/migration/prepare") && method === "POST") {
    const userId = await authenticatedUserId(request);
    const profile = firstRow(await rpc("nipto_native_profile_for_user", { p_user_id: userId }));
    if (!profile || typeof profile.nipto_id !== "string") {
      throw new ApiError("This account cannot be migrated right now.", 400);
    }
    const migrationTicket = randomToken(32);
    await rpc("nipto_oidc_create_migration_ticket", {
      p_user_id: userId,
      p_ticket_hash: await sha256Hex(migrationTicket),
    });
    return json({
      migration_ticket: migrationTicket,
      nipto_id: profile.nipto_id,
      display_name: profile.display_name,
    });
  }

  if (path.endsWith("/account/link") && method === "POST") {
    const userId = await authenticatedUserId(request);
    const input = await requestBody(request);
    const niptoId = String(input.nipto_id ?? "").trim().replace(/^@/, "").toLowerCase();
    await rpc("nipto_oidc_link_user", { p_nipto_id: niptoId, p_user_id: userId });
    await rpcAsUser(request, "nipto_native_clear_legacy_email");
    return json({ ok: true });
  }

  if (path.endsWith("/sessions") && method === "GET") {
    const userId = await authenticatedUserId(request);
    const sessions = await rpc("nipto_native_list_sessions", { p_user_id: userId });
    return json({ sessions: sessions ?? [] });
  }
  if (path.endsWith("/sessions/revoke") && method === "POST") {
    const userId = await authenticatedUserId(request);
    const input = await requestBody(request);
    const ok = await rpc("nipto_native_revoke_session", {
      p_user_id: userId,
      p_session_id: String(input.session_id ?? ""),
    });
    if (ok !== true) throw new ApiError("That session is no longer active.", 404);
    return json({ ok: true });
  }

  return json({ error: "Not found" }, 404);
}

Deno.serve(async (request: Request) => {
  try {
    return await handleRoute(request);
  } catch (error) {
    if (error instanceof ApiError) return json({ error: error.message }, error.status);
    return json({ error: "Nipto could not complete the request. Please try again." }, 500);
  }
});