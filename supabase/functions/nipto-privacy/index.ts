import "jsr:@supabase/functions-js/edge-runtime.d.ts";
import {
  EXPORT_TTL_MS,
  exportObjectPath,
  isCanonicalUuid,
  isCronAuthorized,
  isPrivacySafeExport,
  isUserChatMediaPath,
  MAX_WORKER_BATCH,
  normalizeBearerAuthorization,
  parseEmptyRequestPayload,
  parseStorageListNames,
  parseWorkerOptions,
  privacyObjectPrefixes,
  sanitizeCancelResult,
  sanitizeClaimedRows,
  sanitizeRequestResult,
  sanitizeStatusResponse,
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

const CORS_HEADERS: Record<string, string> = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};

const STORAGE_LIST_LIMIT = 1_000;
const MAX_OWNED_OBJECTS = 5_000;
const MAX_STORAGE_DEPTH = 8;
const SIGNED_URL_TTL_SECONDS = 60 * 60;

function isRecord(value: unknown): value is Json {
  return typeof value === "object" && value !== null && !Array.isArray(value);
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
  const direct = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY");
  if (direct) return direct;
  const fallback = (Deno.env.get("SUPABASE_SECRET_KEYS") ?? "")
    .split(",")
    .map((value) => value.trim())
    .find((value) => value.length > 0);
  if (!fallback) {
    throw new ApiError(
      "Server configuration missing: service role key",
      503,
      "server_misconfigured",
    );
  }
  return fallback;
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
      ...CORS_HEADERS,
    },
  });
}

function errorResponse(error: unknown): Response {
  if (error instanceof ApiError) {
    return json(
      { error: { message: error.message, code: error.code } },
      error.status,
    );
  }
  // Never echo upstream bodies, JWTs or service-role details to the caller.
  console.error(
    "nipto-privacy unexpected error",
    error instanceof Error ? error.message : "unknown",
  );
  return json({
    error: { message: "Privacy service is unavailable", code: "server_error" },
  }, 502);
}

async function readJson(response: Response): Promise<unknown> {
  const text = await response.text();
  if (text.length === 0) return null;
  try {
    return JSON.parse(text) as unknown;
  } catch {
    throw new ApiError(
      "Upstream response was invalid",
      502,
      "upstream_invalid",
    );
  }
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
  if (!isRecord(value)) {
    throw new ApiError("Invalid JSON request", 400, "invalid_json");
  }
  return value;
}

function userAuthorization(request: Request): string {
  const authorization = normalizeBearerAuthorization(
    request.headers.get("authorization"),
  );
  if (!authorization) {
    throw new ApiError("Sign in to continue", 401, "unauthenticated");
  }
  return authorization;
}

/** The function verifies the caller's Supabase bearer itself; no client user ID is trusted. */
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
  const user = await readJson(response);
  if (!isRecord(user) || !isCanonicalUuid(user.id)) {
    throw new ApiError("Sign in to continue", 401, "unauthenticated");
  }
  return user.id;
}

async function rpcAsUser<T>(
  authorization: string,
  name: string,
  body: Json,
): Promise<T> {
  let response: Response;
  try {
    response = await fetch(
      supabaseUrl() + "/rest/v1/rpc/" + encodeURIComponent(name),
      {
        method: "POST",
        headers: {
          apikey: publishableKey(),
          Authorization: authorization,
          "Content-Type": "application/json",
        },
        body: JSON.stringify(body),
      },
    );
  } catch {
    throw new ApiError(
      "Privacy service is unavailable",
      502,
      "rpc_unavailable",
    );
  }
  if (!response.ok) {
    throw new ApiError("Privacy request was rejected", 403, "rpc_rejected");
  }
  return await readJson(response) as T;
}

async function rpcAsService<T>(name: string, body: Json): Promise<T> {
  const key = serviceKey();
  let response: Response;
  try {
    response = await fetch(
      supabaseUrl() + "/rest/v1/rpc/" + encodeURIComponent(name),
      {
        method: "POST",
        headers: {
          apikey: key,
          Authorization: "Bearer " + key,
          "Content-Type": "application/json",
        },
        body: JSON.stringify(body),
      },
    );
  } catch {
    throw new ApiError("Privacy worker is unavailable", 502, "rpc_unavailable");
  }
  if (!response.ok) {
    throw new ApiError("Privacy worker RPC failed", 502, "rpc_failed");
  }
  return await readJson(response) as T;
}

async function selectPrivacyRowsAsUser(
  authorization: string,
  columns: string,
  filters: Record<string, string>,
): Promise<unknown> {
  const url = new URL(supabaseUrl() + "/rest/v1/privacy_requests");
  url.searchParams.set("select", columns);
  for (const [key, value] of Object.entries(filters)) {
    url.searchParams.set(key, value);
  }

  let response: Response;
  try {
    response = await fetch(url, {
      headers: {
        apikey: publishableKey(),
        Authorization: authorization,
        Accept: "application/json",
      },
    });
  } catch {
    throw new ApiError(
      "Privacy service is unavailable",
      502,
      "read_unavailable",
    );
  }
  if (!response.ok) {
    throw new ApiError(
      "Privacy requests could not be read",
      403,
      "read_rejected",
    );
  }
  return await readJson(response);
}

function parseRequestKind(value: unknown): "export" | "deletion" | null {
  if (!isRecord(value)) return null;
  if (Object.keys(value).length !== 1 || value.kind === undefined) return null;
  return value.kind === "export" || value.kind === "deletion"
    ? value.kind
    : null;
}

function parseRequestIdPayload(value: unknown): string | null {
  if (!isRecord(value)) return null;
  if (Object.keys(value).length !== 1) return null;
  return isCanonicalUuid(value.request_id) ? value.request_id : null;
}

function encodeObjectPath(path: string): string {
  return path.split("/").map(encodeURIComponent).join("/");
}

async function handleStatus(request: Request): Promise<Response> {
  const authorization = userAuthorization(request);
  await currentUserId(authorization);
  const rows = await selectPrivacyRowsAsUser(
    authorization,
    "id,kind,status,requested_at,execute_after,completed_at,canceled_at,attempts",
    { order: "requested_at.desc", limit: "50" },
  );
  const sanitized = sanitizeStatusResponse(rows);
  if (!sanitized) {
    throw new ApiError(
      "Privacy status response was invalid",
      502,
      "status_invalid",
    );
  }
  return json(sanitized);
}

async function handleRequest(request: Request): Promise<Response> {
  const kind = parseRequestKind(await requestBody(request));
  if (!kind) {
    throw new ApiError("Use kind 'export' or 'deletion'", 400, "kind_invalid");
  }
  const authorization = userAuthorization(request);
  await currentUserId(authorization);
  const rpcName = kind === "export"
    ? "request_privacy_export"
    : "request_account_deletion";
  const result = sanitizeRequestResult(
    await rpcAsUser<unknown>(authorization, rpcName, {}),
  );
  if (!result) {
    throw new ApiError(
      "Privacy request response was invalid",
      502,
      "request_invalid",
    );
  }
  return json(result);
}

async function handleCancel(request: Request): Promise<Response> {
  if (!parseEmptyRequestPayload(await requestBody(request))) {
    throw new ApiError(
      "No request fields are expected",
      400,
      "payload_invalid",
    );
  }
  const authorization = userAuthorization(request);
  await currentUserId(authorization);
  const canceled = sanitizeCancelResult(
    await rpcAsUser<unknown>(authorization, "cancel_account_deletion", {}),
  );
  if (canceled === null) {
    throw new ApiError(
      "Cancellation response was invalid",
      502,
      "cancel_invalid",
    );
  }
  return json({ canceled });
}

interface ExportRow {
  id: string;
  path: string;
  expiresAt: string;
}

function parseExportRow(
  value: unknown,
  userId: string,
  requestId: string,
): ExportRow | null {
  if (!Array.isArray(value) || value.length !== 1 || !isRecord(value[0])) {
    return null;
  }
  const row = value[0];
  if (
    row.id !== requestId || row.kind !== "export" || row.status !== "completed"
  ) return null;
  if (typeof row.export_path !== "string") return null;
  const expectedPath = exportObjectPath(userId, requestId);
  if (!expectedPath || row.export_path !== expectedPath) return null;
  if (typeof row.export_expires_at !== "string") return null;
  const expiresAtMs = Date.parse(row.export_expires_at);
  if (!Number.isFinite(expiresAtMs) || expiresAtMs <= Date.now()) return null;
  return {
    id: requestId,
    path: expectedPath,
    expiresAt: new Date(expiresAtMs).toISOString(),
  };
}

async function signExportObject(path: string): Promise<string> {
  const key = serviceKey();
  let response: Response;
  try {
    response = await fetch(
      supabaseUrl() + "/storage/v1/object/sign/privacy-exports/" +
        encodeObjectPath(path),
      {
        method: "POST",
        headers: {
          apikey: key,
          Authorization: "Bearer " + key,
          "Content-Type": "application/json",
        },
        body: JSON.stringify({ expiresIn: SIGNED_URL_TTL_SECONDS }),
      },
    );
  } catch {
    throw new ApiError("Export is unavailable", 502, "sign_unavailable");
  }
  if (!response.ok) {
    throw new ApiError(
      "Export is unavailable or expired",
      404,
      "export_not_found",
    );
  }
  const payload = await readJson(response);
  if (!isRecord(payload)) {
    throw new ApiError("Export URL response was invalid", 502, "sign_invalid");
  }
  const signed = typeof payload.signedURL === "string"
    ? payload.signedURL
    : typeof payload.signedUrl === "string"
    ? payload.signedUrl
    : null;
  if (!signed || signed.length === 0) {
    throw new ApiError("Export URL response was invalid", 502, "sign_invalid");
  }
  return signed.startsWith("http://") || signed.startsWith("https://")
    ? signed
    : supabaseUrl() + signed;
}

async function handleExportUrl(request: Request): Promise<Response> {
  const requestId = parseRequestIdPayload(await requestBody(request));
  if (!requestId) {
    throw new ApiError(
      "Enter a valid export request ID",
      400,
      "request_id_invalid",
    );
  }
  const authorization = userAuthorization(request);
  const userId = await currentUserId(authorization);
  const rows = await selectPrivacyRowsAsUser(
    authorization,
    "id,kind,status,export_path,export_expires_at",
    {
      id: "eq." + requestId,
      kind: "eq.export",
      status: "eq.completed",
      limit: "1",
    },
  );
  const exportRow = parseExportRow(rows, userId, requestId);
  if (!exportRow) {
    throw new ApiError(
      "Export is unavailable or expired",
      404,
      "export_not_found",
    );
  }
  const signedUrl = await signExportObject(exportRow.path);
  const signedUrlExpiresAt = new Date(
    Date.now() + SIGNED_URL_TTL_SECONDS * 1000,
  ).toISOString();
  return json({ signed_url: signedUrl, expires_at: signedUrlExpiresAt });
}

function storageHeaders(key: string): Record<string, string> {
  return { apikey: key, Authorization: "Bearer " + key };
}

async function storageList(
  bucket: string,
  prefix: string,
  offset: number,
): Promise<unknown> {
  const key = serviceKey();
  let response: Response;
  try {
    response = await fetch(
      supabaseUrl() + "/storage/v1/object/list/" + encodeURIComponent(bucket),
      {
        method: "POST",
        headers: {
          ...storageHeaders(key),
          "Content-Type": "application/json",
        },
        body: JSON.stringify({
          prefix,
          limit: STORAGE_LIST_LIMIT,
          offset,
          sortBy: { column: "name", order: "asc" },
        }),
      },
    );
  } catch {
    throw new ApiError(
      "Storage listing is unavailable",
      502,
      "storage_unavailable",
    );
  }
  if (!response.ok) {
    throw new ApiError("Storage listing failed", 502, "storage_list_failed");
  }
  return await readJson(response);
}

async function storageDelete(bucket: string, paths: string[]): Promise<void> {
  if (paths.length === 0) return;
  const key = serviceKey();
  let response: Response;
  try {
    response = await fetch(
      supabaseUrl() + "/storage/v1/object/" + encodeURIComponent(bucket),
      {
        method: "DELETE",
        headers: {
          ...storageHeaders(key),
          "Content-Type": "application/json",
        },
        body: JSON.stringify({ prefixes: paths }),
      },
    );
  } catch {
    throw new ApiError(
      "Storage deletion is unavailable",
      502,
      "storage_unavailable",
    );
  }
  if (!response.ok) {
    throw new ApiError("Storage deletion failed", 502, "storage_delete_failed");
  }
}

async function collectOwnedPaths(
  bucket: string,
  prefix: string,
  userId: string,
): Promise<string[]> {
  const found: string[] = [];
  const queue: Array<{ prefix: string; depth: number }> = [{
    prefix,
    depth: 0,
  }];

  while (queue.length > 0) {
    const current = queue.shift();
    if (!current) break;
    let offset = 0;
    while (true) {
      const names = parseStorageListNames(
        await storageList(bucket, current.prefix, offset),
      );
      if (!names) {
        throw new ApiError(
          "Storage listing was invalid",
          502,
          "storage_list_invalid",
        );
      }
      for (const name of names) {
        if (name.endsWith("/")) {
          if (current.depth >= MAX_STORAGE_DEPTH) {
            throw new ApiError(
              "Storage prefix is too deep",
              422,
              "storage_depth_exceeded",
            );
          }
          queue.push({
            prefix: current.prefix + name,
            depth: current.depth + 1,
          });
          continue;
        }
        const fullPath = current.prefix + name;
        const owned = bucket === "chat-media"
          ? isUserChatMediaPath(fullPath, userId)
          : fullPath.startsWith(current.prefix);
        if (!owned) continue;
        found.push(fullPath);
        if (found.length > MAX_OWNED_OBJECTS) {
          throw new ApiError(
            "Too many owned objects to delete",
            422,
            "storage_scope_too_large",
          );
        }
      }
      if (names.length < STORAGE_LIST_LIMIT) break;
      offset += STORAGE_LIST_LIMIT;
      if (offset > MAX_OWNED_OBJECTS) {
        throw new ApiError(
          "Too many owned objects to delete",
          422,
          "storage_scope_too_large",
        );
      }
    }
  }
  return found;
}

async function deleteOwnedMedia(userId: string): Promise<void> {
  for (const prefix of privacyObjectPrefixes(userId)) {
    const bucket = prefix.split("/")[0] ?? "";
    const paths = await collectOwnedPaths(bucket, prefix, userId);
    for (let index = 0; index < paths.length; index += 100) {
      await storageDelete(bucket, paths.slice(index, index + 100));
    }
  }

  // chat-media is shared: list conversations, then delete only this user's
  // object folder inside each one. Other members' media is never enumerated
  // for deletion.
  const conversationFolders: string[] = [];
  let offset = 0;
  while (true) {
    const names = parseStorageListNames(
      await storageList("chat-media", "chat-media/", offset),
    );
    if (!names) {
      throw new ApiError(
        "Storage listing was invalid",
        502,
        "storage_list_invalid",
      );
    }
    for (const name of names) {
      if (name.endsWith("/")) conversationFolders.push(name);
      if (conversationFolders.length > MAX_OWNED_OBJECTS) {
        throw new ApiError(
          "Too many conversations to clean",
          422,
          "storage_scope_too_large",
        );
      }
    }
    if (names.length < STORAGE_LIST_LIMIT) break;
    offset += STORAGE_LIST_LIMIT;
  }
  for (const folder of conversationFolders) {
    const prefix = "chat-media/" + folder + userId + "/";
    const paths = await collectOwnedPaths("chat-media", prefix, userId);
    for (let index = 0; index < paths.length; index += 100) {
      await storageDelete("chat-media", paths.slice(index, index + 100));
    }
  }
}

async function deleteAuthUser(userId: string): Promise<void> {
  const key = serviceKey();
  const headers = storageHeaders(key);
  const endpoint = supabaseUrl() + "/auth/v1/admin/users/" +
    encodeURIComponent(userId);
  let check: Response;
  try {
    check = await fetch(endpoint, { headers });
  } catch {
    throw new ApiError(
      "Auth admin API is unavailable",
      502,
      "auth_unavailable",
    );
  }
  if (check.status === 404) return;
  if (!check.ok) {
    throw new ApiError(
      "Auth user could not be checked",
      502,
      "auth_check_failed",
    );
  }

  let deleted: Response;
  try {
    deleted = await fetch(endpoint, { method: "DELETE", headers });
  } catch {
    throw new ApiError(
      "Auth admin API is unavailable",
      502,
      "auth_unavailable",
    );
  }
  if (!deleted.ok && deleted.status !== 404) {
    throw new ApiError(
      "Auth user could not be deleted",
      502,
      "auth_delete_failed",
    );
  }
}

async function processExport(requestId: string, userId: string): Promise<void> {
  const snapshot = await rpcAsService<unknown>(
    "nipto_privacy_export_snapshot",
    { p_user_id: userId },
  );
  if (!isPrivacySafeExport(snapshot)) {
    throw new ApiError(
      "Export payload failed the privacy safety check",
      500,
      "unsafe_export",
    );
  }
  const path = exportObjectPath(userId, requestId);
  if (!path) {
    throw new ApiError("Export path is invalid", 500, "export_path_invalid");
  }

  const key = serviceKey();
  let uploaded: Response;
  try {
    uploaded = await fetch(
      supabaseUrl() + "/storage/v1/object/privacy-exports/" +
        encodeObjectPath(path),
      {
        method: "POST",
        headers: {
          ...storageHeaders(key),
          "Content-Type": "application/json",
          "x-upsert": "true",
          "cache-control": "max-age=0",
        },
        body: JSON.stringify(snapshot),
      },
    );
  } catch {
    throw new ApiError(
      "Export upload is unavailable",
      502,
      "upload_unavailable",
    );
  }
  if (!uploaded.ok) {
    throw new ApiError("Export upload failed", 502, "upload_failed");
  }

  const expiresAt = new Date(Date.now() + EXPORT_TTL_MS).toISOString();
  const completed = await rpcAsService<unknown>("nipto_privacy_complete", {
    p_request_id: requestId,
    p_export_path: path,
    p_export_expires_at: expiresAt,
  });
  if (completed !== true) {
    throw new ApiError(
      "Export completion was rejected",
      502,
      "complete_failed",
    );
  }
}

async function processDeletion(
  requestId: string,
  userId: string,
): Promise<void> {
  await rpcAsService<unknown>("nipto_privacy_anonymize_attribution", {
    p_user_id: userId,
  });
  await deleteOwnedMedia(userId);
  await rpcAsService<unknown>("nipto_native_revoke_all_sessions", {
    p_user_id: userId,
  });
  await deleteAuthUser(userId);
  const completed = await rpcAsService<unknown>("nipto_privacy_complete", {
    p_request_id: requestId,
    p_export_path: null,
    p_export_expires_at: null,
  });
  if (completed !== true) {
    throw new ApiError(
      "Deletion completion was rejected",
      502,
      "complete_failed",
    );
  }
}

interface ExpiredExport {
  id: string;
  path: string;
}

function parseExpiredExports(value: unknown): ExpiredExport[] | null {
  if (!Array.isArray(value) || value.length > 50) return null;
  const rows: ExpiredExport[] = [];
  for (const row of value) {
    if (
      !isRecord(row) || !isCanonicalUuid(row.id) ||
      typeof row.export_path !== "string"
    ) return null;
    const parts = row.export_path.split("/");
    if (
      parts.length !== 2 || !isCanonicalUuid(parts[0]) ||
      parts[1] !== row.id + ".json"
    ) return null;
    rows.push({ id: row.id, path: row.export_path });
  }
  return rows;
}

async function purgeExpiredExports(): Promise<number> {
  const rows = parseExpiredExports(
    await rpcAsService<unknown>("nipto_privacy_list_expired_exports", {
      p_limit: 10,
    }),
  );
  if (!rows) {
    throw new ApiError(
      "Expired export listing was invalid",
      502,
      "expired_list_invalid",
    );
  }

  let purged = 0;
  for (const row of rows) {
    try {
      await storageDelete("privacy-exports", [row.path]);
      const result = await rpcAsService<unknown>("nipto_privacy_purge_export", {
        p_request_id: row.id,
      });
      if (result === true) purged++;
    } catch (error) {
      console.error(
        "privacy export purge failed",
        error instanceof Error ? error.message : "unknown",
      );
    }
  }
  return purged;
}

function safeWorkerError(error: unknown): string {
  if (error instanceof ApiError) return error.message.slice(0, 500);
  return "Privacy worker step failed";
}

async function handleWorker(request: Request): Promise<Response> {
  const secret = Deno.env.get("CRON_SECRET");
  if (!isCronAuthorized(request.headers.get("authorization"), secret)) {
    throw new ApiError("Unauthorized", 401, "unauthorized");
  }
  const options = parseWorkerOptions(await requestBody(request));
  if (!options) {
    throw new ApiError("Invalid worker payload", 400, "payload_invalid");
  }

  const claimed = sanitizeClaimedRows(
    await rpcAsService<unknown>("nipto_privacy_claim_due", {
      p_limit: options.limit,
    }),
  );
  if (!claimed) {
    throw new ApiError(
      "Claimed request rows were invalid",
      502,
      "claim_invalid",
    );
  }

  let completed = 0;
  let failed = 0;
  for (const row of claimed) {
    try {
      if (row.kind === "export") await processExport(row.id, row.user_id);
      else await processDeletion(row.id, row.user_id);
      completed++;
    } catch (error) {
      failed++;
      try {
        await rpcAsService<unknown>("nipto_privacy_fail", {
          p_request_id: row.id,
          p_error: safeWorkerError(error),
        });
      } catch (failError) {
        console.error(
          "privacy failure update failed",
          failError instanceof Error ? failError.message : "unknown",
        );
      }
    }
  }

  let purged = 0;
  try {
    purged = await purgeExpiredExports();
  } catch (error) {
    console.error(
      "privacy export purge pass failed",
      error instanceof Error ? error.message : "unknown",
    );
  }

  return json({ processed: claimed.length, completed, failed, purged });
}

Deno.serve(async (request: Request): Promise<Response> => {
  if (request.method === "OPTIONS") {
    return new Response(null, { status: 204, headers: CORS_HEADERS });
  }

  const path = new URL(request.url).pathname.replace(/\/+$/, "");
  try {
    if (request.method !== "POST") {
      throw new ApiError("Method not allowed", 405, "method_not_allowed");
    }
    if (path.endsWith("/status")) return await handleStatus(request);
    if (path.endsWith("/request")) return await handleRequest(request);
    if (path.endsWith("/cancel")) return await handleCancel(request);
    if (path.endsWith("/export-url")) return await handleExportUrl(request);
    if (path.endsWith("/worker/run")) return await handleWorker(request);
    throw new ApiError("Unknown privacy route", 404, "not_found");
  } catch (error) {
    return errorResponse(error);
  }
});
