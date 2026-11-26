import "jsr:@supabase/functions-js/edge-runtime.d.ts";
import {
  claimDecision,
  inspectMediaBytes,
  isCanonicalUuid,
  isOwnerPath,
  MediaValidationError,
  MIME_ALLOWLIST,
  normalizeBearerAuthorization,
  pendingValidationState,
  sha256Hex,
} from "./validation.ts";

type Json = Record<string, unknown>;

class ApiError extends Error {
  constructor(
    message: string,
    readonly status = 400,
    readonly code = "request_invalid",
  ) {
    super(message);
    this.name = "ApiError";
  }
}

function env(name: string): string {
  const value = Deno.env.get(name);
  if (!value) {
    throw new ApiError(
      `Server configuration missing: ${name}`,
      503,
      "server_misconfigured",
    );
  }
  return value;
}
function supabaseUrl(): string {
  return env("SUPABASE_URL").replace(/\/$/, "");
}
function serviceKey(): string {
  return env("SUPABASE_SERVICE_ROLE_KEY");
}
function publishableKey(): string {
  return Deno.env.get("SUPABASE_PUBLISHABLE_KEY") ?? env("SUPABASE_ANON_KEY");
}
function json(data: unknown, status = 200): Response {
  return new Response(JSON.stringify(data), {
    status,
    headers: {
      "Content-Type": "application/json; charset=utf-8",
      "Cache-Control": "no-store",
      "Access-Control-Allow-Origin": "*",
      "Access-Control-Allow-Headers": "authorization, apikey, content-type",
      "Access-Control-Allow-Methods": "POST, OPTIONS",
    },
  });
}

async function requestBody(request: Request): Promise<Json> {
  if (
    request.headers.get("content-type")?.split(";")[0].trim().toLowerCase() !==
      "application/json"
  ) {
    throw new ApiError("A JSON request body is required", 415, "json_required");
  }
  const text = await request.text();
  if (text.length > 8_192) {
    throw new ApiError("Request is too large", 413, "request_too_large");
  }
  let value: unknown;
  try {
    value = JSON.parse(text);
  } catch {
    throw new ApiError("Invalid JSON request", 400, "invalid_json");
  }
  if (typeof value !== "object" || value === null || Array.isArray(value)) {
    throw new ApiError("Invalid request", 400, "invalid_json");
  }
  return value as Json;
}

async function currentUserId(authorization: string): Promise<string> {
  let response: Response;
  try {
    response = await fetch(supabaseUrl() + "/auth/v1/user", {
      headers: { apikey: publishableKey(), Authorization: authorization },
    });
  } catch {
    throw new ApiError(
      "Identity service is unavailable",
      502,
      "auth_unavailable",
    );
  }
  if (!response.ok) {
    throw new ApiError("Sign in to continue", 401, "unauthenticated");
  }
  const user = await response.json();
  if (!isCanonicalUuid(user?.id)) {
    throw new ApiError("Sign in to continue", 401, "unauthenticated");
  }
  return user.id as string;
}

async function rpcAsUser<T>(
  authorization: string,
  name: string,
  body: Json,
): Promise<T> {
  const response = await fetch(supabaseUrl() + "/rest/v1/rpc/" + name, {
    method: "POST",
    headers: {
      apikey: publishableKey(),
      Authorization: authorization,
      "Content-Type": "application/json",
    },
    body: JSON.stringify(body),
  });
  if (!response.ok) {
    const detail = await response.text();
    throw new ApiError(
      detail.length > 0 && detail.length <= 500
        ? detail
        : "Media request was rejected",
      403,
      "rpc_rejected",
    );
  }
  return await response.json() as T;
}

async function rpcAsService<T>(name: string, body: Json): Promise<T> {
  const key = serviceKey();
  const response = await fetch(supabaseUrl() + "/rest/v1/rpc/" + name, {
    method: "POST",
    headers: {
      apikey: key,
      Authorization: "Bearer " + key,
      "Content-Type": "application/json",
    },
    body: JSON.stringify(body),
  });
  if (!response.ok) {
    const detail = await response.text();
    throw new ApiError(
      detail.length > 0 && detail.length <= 500
        ? detail
        : "Media update failed",
      502,
      "pipeline_rpc_failed",
    );
  }
  const text = await response.text();
  return (text.length > 0 ? JSON.parse(text) : null) as T;
}

/** Only the Edge Function holds the service-role key; bytes never leave the
 * server and are never exposed through a public bucket URL. */
async function downloadObject(
  bucket: string,
  path: string,
): Promise<Uint8Array> {
  const key = serviceKey();
  const objectPath = path.split("/").map((part) => encodeURIComponent(part))
    .join("/");
  const response = await fetch(
    supabaseUrl() + "/storage/v1/object/" + encodeURIComponent(bucket) + "/" +
      objectPath,
    {
      headers: { apikey: key, Authorization: "Bearer " + key },
    },
  );
  if (!response.ok) {
    throw new ApiError("Media object is unavailable", 404, "object_missing");
  }
  const bytes = new Uint8Array(await response.arrayBuffer());
  if (bytes.byteLength === 0) {
    throw new ApiError("Media object is empty", 422, "empty_media");
  }
  return bytes;
}

async function inspect(request: Request): Promise<Response> {
  const authorization = normalizeBearerAuthorization(
    request.headers.get("authorization"),
  );
  if (!authorization) {
    throw new ApiError("Sign in to continue", 401, "unauthenticated");
  }

  const input = await requestBody(request);
  const bucket = String(input.bucket ?? "");
  const path = String(input.path ?? "");
  if (!Object.hasOwn(MIME_ALLOWLIST, bucket)) {
    throw new ApiError("Unknown media bucket", 400, "bucket_not_allowed");
  }
  const userId = await currentUserId(authorization);
  if (!isOwnerPath(bucket, path, userId)) {
    throw new ApiError(
      "Media path is not owned by this account",
      403,
      "path_not_owned",
    );
  }

  // Ownership, object presence and declared MIME/size are re-checked server-side
  // before any bytes are read.
  const enqueued = await rpcAsUser<Json>(authorization, "nipto_media_enqueue", {
    p_bucket: bucket,
    p_path: path,
  });
  const declaredMime = typeof enqueued?.mime === "string" ? enqueued.mime : "";
  const current = await rpcAsUser<Json | null>(
    authorization,
    "nipto_media_status",
    {
      p_bucket: bucket,
      p_path: path,
    },
  );

  const bytes = await downloadObject(bucket, path);
  const sha256 = await sha256Hex(bytes);
  const decision = claimDecision(current, sha256);
  if (!decision.claim) {
    return json({
      bucket,
      path,
      claimed: false,
      reason: decision.reason,
      state: typeof current?.state === "string"
        ? current.state
        : "not_enqueued",
    });
  }

  const claimed = await rpcAsService<Json>("nipto_media_claim", {
    p_bucket: bucket,
    p_path: path,
    p_sha256: sha256,
  });
  if (claimed?.claimed !== true) {
    return json({
      bucket,
      path,
      claimed: false,
      reason: typeof claimed?.reason === "string"
        ? claimed.reason
        : "not_claimed",
      state: typeof claimed?.state === "string"
        ? claimed.state
        : "not_enqueued",
    });
  }

  try {
    const inspected = await inspectMediaBytes(bytes, declaredMime, bucket);
    // No external scanner or processor is configured: images wait for human
    // review and videos wait for processing. Never emit clean/ready here.
    const state = pendingValidationState(inspected.mime);
    await rpcAsService("nipto_media_finish_validation", {
      p_bucket: bucket,
      p_path: path,
      p_sha256: inspected.sha256,
      p_mime: inspected.mime,
      p_size: inspected.size,
      p_state: state,
      p_error: null,
    });
    return json({
      bucket,
      path,
      claimed: true,
      state,
      sha256: inspected.sha256,
      size: inspected.size,
    });
  } catch (error) {
    const code = error instanceof MediaValidationError
      ? error.code
      : "validation_error";
    await rpcAsService("nipto_media_finish_validation", {
      p_bucket: bucket,
      p_path: path,
      p_sha256: sha256,
      p_mime: declaredMime,
      p_size: bytes.byteLength,
      p_state: "rejected",
      p_error: code,
    });
    return json(
      {
        error: "Media validation failed",
        code,
        state: "rejected",
        bucket,
        path,
      },
      422,
    );
  }
}

Deno.serve(async (request: Request) => {
  try {
    if (request.method === "OPTIONS") return json({ ok: true });
    if (request.method !== "POST") {
      throw new ApiError("Method not allowed", 405, "method_not_allowed");
    }
    return await inspect(request);
  } catch (error) {
    if (error instanceof ApiError) {
      return json({ error: error.message, code: error.code }, error.status);
    }
    return json(
      {
        error: "Media validation could not be completed.",
        code: "internal_error",
      },
      500,
    );
  }
});
