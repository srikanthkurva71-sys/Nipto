export const MAX_WORKER_BATCH = 10;
export const MAX_ATTEMPTS = 5;
export const EXPORT_TTL_MS = 7 * 24 * 60 * 60 * 1000;

const UUID_RE =
  /^[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i;

const STATUSES = new Set([
  "pending",
  "processing",
  "completed",
  "failed",
  "canceled",
]);

const FORBIDDEN_EXPORT_KEYS = new Set([
  "password",
  "password_hash",
  "passwd",
  "secret",
  "token",
  "device_tokens",
  "credential",
  "credentials",
  "authorization",
  "apikey",
  "api_key",
  "email",
  "phone",
  "raw_user_meta_data",
  "user_metadata",
  "app_metadata",
  "nipto_accounts",
  "staff_roles",
  "staff_action_log",
  "private",
  "auth_users",
]);

export type PrivacyKind = "export" | "deletion";
export type PrivacyStatus =
  | "pending"
  | "processing"
  | "completed"
  | "failed"
  | "canceled";

export interface PrivacyRequestSummary {
  id: string;
  kind: PrivacyKind;
  status: PrivacyStatus;
  requested_at: string;
  execute_after: string;
  completed_at: string | null;
  canceled_at: string | null;
  attempts: number;
}

export interface ClaimedPrivacyRequest {
  id: string;
  user_id: string;
  kind: PrivacyKind;
  status: "processing";
  attempts: number;
  execute_after: string;
  requested_at: string;
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}

/** Accept only a single well-formed Bearer token and normalize the scheme casing. */
export function normalizeBearerAuthorization(value: unknown): string | null {
  if (typeof value !== "string" || value.length > 16_500) return null;
  const match = /^Bearer ([A-Za-z0-9._-]{1,16384})$/i.exec(value);
  return match ? "Bearer " + match[1] : null;
}

export function isCanonicalUuid(value: unknown): value is string {
  return typeof value === "string" && UUID_RE.test(value);
}

function constantTimeEquals(a: string, b: string): boolean {
  let mismatch = a.length ^ b.length;
  const length = Math.max(a.length, b.length);
  for (let index = 0; index < length; index++) {
    mismatch |= (a.charCodeAt(index) || 0) ^ (b.charCodeAt(index) || 0);
  }
  return mismatch === 0;
}

/** Worker calls carry CRON_SECRET as a Bearer token and no user JWT. */
export function isCronAuthorized(
  authorizationHeader: unknown,
  secret: string | undefined,
): boolean {
  if (!secret || secret.length === 0) return false;
  const authorization = normalizeBearerAuthorization(authorizationHeader);
  if (!authorization) return false;
  return constantTimeEquals(authorization.slice(7), secret);
}

function normalizedTimestamp(value: unknown): string | null {
  if (value === undefined || value === null || value === "") return null;
  if (typeof value !== "string") return null;
  const milliseconds = Date.parse(value);
  return Number.isFinite(milliseconds)
    ? new Date(milliseconds).toISOString()
    : null;
}

function requiredTimestamp(value: unknown): string | null {
  const timestamp = normalizedTimestamp(value);
  return timestamp && timestamp.length > 0 ? timestamp : null;
}

function parseKind(value: unknown): PrivacyKind | null {
  return value === "export" || value === "deletion" ? value : null;
}

function parseStatus(value: unknown): PrivacyStatus | null {
  return typeof value === "string" && STATUSES.has(value)
    ? value as PrivacyStatus
    : null;
}

/** Convert a PostgREST row into the minimal, client-safe status projection. */
export function sanitizeRequestSummary(
  value: unknown,
): PrivacyRequestSummary | null {
  if (!isRecord(value)) return null;
  const id = value.id;
  const kind = parseKind(value.kind);
  const status = parseStatus(value.status);
  const requestedAt = requiredTimestamp(value.requested_at);
  const executeAfter = requiredTimestamp(value.execute_after);
  const attempts = value.attempts;
  if (
    !isCanonicalUuid(id) || !kind || !status || !requestedAt || !executeAfter
  ) return null;
  if (
    !Number.isInteger(attempts) || (attempts as number) < 0 ||
    (attempts as number) > MAX_ATTEMPTS
  ) return null;
  return {
    id,
    kind,
    status,
    requested_at: requestedAt,
    execute_after: executeAfter,
    completed_at: normalizedTimestamp(value.completed_at),
    canceled_at: normalizedTimestamp(value.canceled_at),
    attempts: attempts as number,
  };
}

export function sanitizeStatusResponse(
  value: unknown,
): { requests: PrivacyRequestSummary[] } | null {
  const rows = Array.isArray(value)
    ? value
    : isRecord(value) && Array.isArray(value.requests)
    ? value.requests
    : null;
  if (!rows || rows.length > 50) return null;
  const requests: PrivacyRequestSummary[] = [];
  for (const row of rows) {
    const summary = sanitizeRequestSummary(row);
    if (!summary) return null;
    requests.push(summary);
  }
  return { requests };
}

/** RPC request endpoints return either a bare UUID or a small status object. */
export function sanitizeRequestResult(
  value: unknown,
): { request_id: string; status: "pending" } | null {
  if (isCanonicalUuid(value)) return { request_id: value, status: "pending" };
  if (!isRecord(value)) return null;
  const id = value.request_id ?? value.id;
  if (!isCanonicalUuid(id)) return null;
  if (value.status !== undefined && value.status !== "pending") return null;
  return { request_id: id, status: "pending" };
}

export function sanitizeCancelResult(value: unknown): boolean | null {
  if (isRecord(value) && typeof value.canceled === "boolean") {
    return value.canceled;
  }
  return null;
}

export function sanitizeClaimedRows(
  value: unknown,
): ClaimedPrivacyRequest[] | null {
  if (!Array.isArray(value) || value.length > MAX_WORKER_BATCH) return null;
  const rows: ClaimedPrivacyRequest[] = [];
  for (const row of value) {
    if (!isRecord(row)) return null;
    const id = row.id;
    const userId = row.user_id;
    const kind = parseKind(row.kind);
    const requestedAt = requiredTimestamp(row.requested_at);
    const executeAfter = requiredTimestamp(row.execute_after);
    const attempts = row.attempts;
    if (
      !isCanonicalUuid(id) || !isCanonicalUuid(userId) || !kind ||
      row.status !== "processing"
    ) return null;
    if (!requestedAt || !executeAfter) return null;
    if (
      !Number.isInteger(attempts) || (attempts as number) < 1 ||
      (attempts as number) > MAX_ATTEMPTS
    ) return null;
    rows.push({
      id,
      user_id: userId,
      kind,
      status: "processing",
      attempts: attempts as number,
      execute_after: executeAfter,
      requested_at: requestedAt,
    });
  }
  return rows;
}

export function isDue(
  row: Pick<PrivacyRequestSummary, "status" | "execute_after">,
  nowMs: number,
): boolean {
  const dueAt = Date.parse(row.execute_after);
  return row.status === "pending" && Number.isFinite(dueAt) &&
    Number.isFinite(nowMs) && dueAt <= nowMs;
}

export function parseEmptyRequestPayload(value: unknown): boolean {
  return isRecord(value) && Object.keys(value).length === 0;
}

export function parseWorkerOptions(value: unknown): { limit: number } | null {
  if (!isRecord(value)) return null;
  if (Object.keys(value).some((key) => key !== "limit")) return null;
  const limit = value.limit === undefined ? 5 : value.limit;
  if (
    !Number.isInteger(limit) || (limit as number) < 1 ||
    (limit as number) > MAX_WORKER_BATCH
  ) return null;
  return { limit: limit as number };
}

function isForbiddenExportKey(key: string): boolean {
  const lower = key.toLowerCase();
  if (FORBIDDEN_EXPORT_KEYS.has(lower)) return true;
  return lower.endsWith("_hash") || lower.endsWith("_secret") ||
    lower.endsWith("_token");
}

/** Reject any export payload that contains a credential-shaped or private key. */
export function isPrivacySafeExport(value: unknown): boolean {
  let visited = 0;
  const walk = (node: unknown, depth: number): boolean => {
    visited++;
    if (visited > 20_000 || depth > 12) return false;
    if (node === null) return true;
    if (Array.isArray(node)) return node.every((item) => walk(item, depth + 1));
    if (typeof node !== "object") {
      return typeof node === "string" || typeof node === "number" ||
        typeof node === "boolean";
    }
    if (Object.getPrototypeOf(node) !== Object.prototype) return false;
    for (
      const [key, child] of Object.entries(node as Record<string, unknown>)
    ) {
      if (isForbiddenExportKey(key)) return false;
      if (!walk(child, depth + 1)) return false;
    }
    return true;
  };
  return walk(value, 0);
}

export function exportObjectPath(
  userId: string,
  requestId: string,
): string | null {
  if (!isCanonicalUuid(userId) || !isCanonicalUuid(requestId)) return null;
  return userId + "/" + requestId + ".json";
}

export function privacyObjectPrefixes(userId: string): string[] {
  if (!isCanonicalUuid(userId)) return [];
  return [
    "avatars/" + userId + "/",
    "statuses/" + userId + "/",
    "posts/" + userId + "/",
    "shorts/" + userId + "/",
  ];
}

/** chat-media/{conversation_id}/{user_id}/... — never delete another member's media. */
export function isUserChatMediaPath(path: string, userId: string): boolean {
  if (!isCanonicalUuid(userId)) return false;
  const parts = path.split("/");
  return parts.length >= 4 && parts[0] === "chat-media" &&
    isCanonicalUuid(parts[1]) && parts[2] === userId;
}

export function parseStorageListNames(value: unknown): string[] | null {
  if (!Array.isArray(value) || value.length > 1_000) return null;
  const names: string[] = [];
  for (const row of value) {
    if (
      !isRecord(row) || typeof row.name !== "string" || row.name.length === 0
    ) return null;
    if (row.name.includes("..") || row.name.startsWith("/")) return null;
    names.push(row.name);
  }
  return names;
}
