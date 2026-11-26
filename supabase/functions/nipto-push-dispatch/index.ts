import "jsr:@supabase/functions-js/edge-runtime.d.ts";
import {
  fcmErrorStatus,
  isInvalidTokenStatus,
  parseServiceAccount,
  pushBodyForJob,
  pushDataForJob,
  type PushJob,
  pushTitleForJob,
  type ServiceAccount,
  signServiceAccountJwt,
} from "./push_helpers.ts";

type Json = Record<string, unknown>;

class ApiError extends Error {
  constructor(message: string, readonly status = 400) {
    super(message);
  }
}

const encoder = new TextEncoder();

function env(name: string): string {
  const value = Deno.env.get(name);
  if (!value) throw new ApiError(`Server configuration missing: ${name}`, 503);
  return value;
}

function supabaseUrl(): string {
  return env("SUPABASE_URL").replace(/\/$/, "");
}

function serviceRoleKey(): string {
  const raw = Deno.env.get("SUPABASE_SECRET_KEYS");
  if (raw) {
    try {
      const keys = JSON.parse(raw) as Record<string, unknown>;
      const value = keys["default"];
      if (typeof value === "string" && value) return value;
    } catch {
      // Fall through to the legacy service-role key.
    }
  }
  return env("SUPABASE_SERVICE_ROLE_KEY");
}

function json(data: unknown, status = 200): Response {
  return new Response(JSON.stringify(data), {
    status,
    headers: {
      "Content-Type": "application/json; charset=utf-8",
      "Cache-Control": "no-store",
      "Access-Control-Allow-Origin": "*",
      "Access-Control-Allow-Headers":
        "authorization, apikey, content-type, x-nipto-worker-secret",
      "Access-Control-Allow-Methods": "POST, OPTIONS",
    },
  });
}

function constantTimeEqual(left: string, right: string): boolean {
  const a = encoder.encode(left);
  const b = encoder.encode(right);
  if (a.length !== b.length) return false;
  let mismatch = 0;
  for (let index = 0; index < a.length; index += 1) {
    mismatch |= a[index] ^ b[index];
  }
  return mismatch === 0;
}

async function rpc(name: string, args: Json): Promise<unknown> {
  const response = await fetch(`${supabaseUrl()}/rest/v1/rpc/${name}`, {
    method: "POST",
    headers: {
      apikey: serviceRoleKey(),
      Authorization: `Bearer ${serviceRoleKey()}`,
      "Content-Type": "application/json",
    },
    body: JSON.stringify(args),
  });
  const raw = await response.text();
  if (!response.ok) throw new ApiError("Dispatch RPC failed", 503);
  return raw ? JSON.parse(raw) : null;
}

function jobsFromResult(value: unknown): PushJob[] {
  const source = Array.isArray(value) ? value : [];
  const jobs: PushJob[] = [];
  for (const item of source) {
    if (typeof item !== "object" || item === null) continue;
    const row = item as Record<string, unknown>;
    if (
      typeof row.id !== "string" || typeof row.user_id !== "string" ||
      (row.delivery_type !== "notification" &&
        row.delivery_type !== "incoming_call")
    ) continue;
    const payload = typeof row.payload === "object" && row.payload !== null
      ? row.payload as Record<string, unknown>
      : {};
    jobs.push({
      id: row.id,
      user_id: row.user_id,
      delivery_type: row.delivery_type,
      payload,
      attempts: typeof row.attempts === "number" ? row.attempts : undefined,
    });
  }
  return jobs;
}

function tokensFromResult(value: unknown): string[] {
  const source = Array.isArray(value) ? value : [];
  return source.filter((token): token is string =>
    typeof token === "string" && token.length >= 16 && token.length <= 4096
  );
}

let accessTokenCache: { token: string; expiresAt: number } | undefined;
async function fcmAccessToken(account: ServiceAccount): Promise<string> {
  const nowSeconds = Math.floor(Date.now() / 1000);
  if (accessTokenCache && accessTokenCache.expiresAt > nowSeconds + 60) {
    return accessTokenCache.token;
  }
  const assertion = await signServiceAccountJwt(account, nowSeconds);
  const response = await fetch("https://oauth2.googleapis.com/token", {
    method: "POST",
    headers: { "Content-Type": "application/x-www-form-urlencoded" },
    body: new URLSearchParams({
      grant_type: "urn:ietf:params:oauth:grant-type:jwt-bearer",
      assertion,
    }).toString(),
  });
  const raw = await response.text();
  if (!response.ok) throw new ApiError("FCM authorization failed", 502);
  let value: Json;
  try {
    value = JSON.parse(raw) as Json;
  } catch {
    throw new ApiError("FCM authorization failed", 502);
  }
  if (typeof value.access_token !== "string" || !value.access_token) {
    throw new ApiError("FCM authorization failed", 502);
  }
  const expiresIn = typeof value.expires_in === "number"
    ? value.expires_in
    : 3600;
  accessTokenCache = {
    token: value.access_token,
    expiresAt: nowSeconds + Math.min(Math.max(expiresIn, 60), 3600),
  };
  return value.access_token;
}

type SendResult = { delivered: boolean; invalidToken: boolean; error: string };
async function sendPush(
  account: ServiceAccount,
  accessToken: string,
  token: string,
  job: PushJob,
): Promise<SendResult> {
  const response = await fetch(
    `https://fcm.googleapis.com/v1/projects/${
      encodeURIComponent(account.project_id)
    }/messages:send`,
    {
      method: "POST",
      headers: {
        Authorization: `Bearer ${accessToken}`,
        "Content-Type": "application/json",
      },
      body: JSON.stringify({
        message: {
          token,
          notification: {
            title: pushTitleForJob(job),
            body: pushBodyForJob(job),
          },
          data: pushDataForJob(job),
          android: {
            priority: job.delivery_type === "incoming_call" ? "high" : "normal",
          },
        },
      }),
    },
  );
  const raw = await response.text();
  if (response.ok) return { delivered: true, invalidToken: false, error: "" };
  const status = fcmErrorStatus(response.status, raw);
  let message = `FCM request failed (${status})`;
  try {
    const value = JSON.parse(raw) as { error?: { message?: string } };
    if (typeof value.error?.message === "string") {
      message = value.error.message.slice(0, 300);
    }
  } catch {
    // Keep the generic status-only error when the body is not JSON.
  }
  return {
    delivered: false,
    invalidToken: isInvalidTokenStatus(status),
    error: message,
  };
}

async function runWorker(request: Request): Promise<Response> {
  const expected = Deno.env.get("NIPTO_PUSH_WORKER_SECRET") ??
    Deno.env.get("CRON_SECRET");
  if (!expected) throw new ApiError("Worker secret is not configured", 503);
  const supplied = request.headers.get("x-nipto-worker-secret") ??
    request.headers.get("authorization")?.replace(/^Bearer\s+/i, "") ??
    "";
  if (!supplied || !constantTimeEqual(supplied, expected)) {
    throw new ApiError("Unauthorized", 401);
  }

  const rawAccount = Deno.env.get("FCM_SERVICE_ACCOUNT_JSON");
  if (!rawAccount) {
    throw new ApiError("FCM credentials are not configured", 503);
  }
  const account = parseServiceAccount(rawAccount);
  const claimed = jobsFromResult(
    await rpc("nipto_push_claim", { p_limit: 50 }),
  );
  if (claimed.length === 0) {
    return json({ processed: 0, delivered: 0, failed: 0 });
  }

  const accessToken = await fcmAccessToken(account);
  let delivered = 0;
  let failed = 0;
  for (const job of claimed) {
    const tokens = tokensFromResult(
      await rpc("nipto_push_tokens", { p_user_id: job.user_id }),
    );
    if (tokens.length === 0) {
      await rpc("nipto_push_fail", {
        p_job_id: job.id,
        p_error: "No registered device tokens",
        p_retryable: true,
      });
      failed += 1;
      continue;
    }

    let jobDelivered = false;
    let lastError = "Push delivery failed";
    for (const token of tokens) {
      const result = await sendPush(account, accessToken, token, job);
      if (result.invalidToken) {
        await rpc("nipto_push_invalidate_token", { p_token: token });
      }
      if (result.delivered) {
        jobDelivered = true;
      } else if (result.error) {
        lastError = result.error;
      }
    }
    if (jobDelivered) {
      await rpc("nipto_push_complete", { p_job_id: job.id });
      delivered += 1;
    } else {
      await rpc("nipto_push_fail", {
        p_job_id: job.id,
        p_error: lastError,
        p_retryable: true,
      });
      failed += 1;
    }
  }
  return json({ processed: claimed.length, delivered, failed });
}

async function handler(request: Request): Promise<Response> {
  try {
    if (request.method === "OPTIONS") {
      return new Response(null, { status: 204 });
    }
    if (request.method !== "POST") {
      return json({ error: "Method not allowed" }, 405);
    }
    const path = new URL(request.url).pathname.replace(/\/+$/, "");
    if (path.endsWith("/worker/run")) return await runWorker(request);
    return json({ error: "Not found" }, 404);
  } catch (error) {
    if (error instanceof ApiError) {
      return json({ error: error.message }, error.status);
    }
    return json({ error: "Push dispatch failed" }, 500);
  }
}

if (import.meta.main) Deno.serve(handler);
