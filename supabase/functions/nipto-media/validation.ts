/** Pure validation rules shared by the nipto-media Edge Function and its tests.
 * These helpers never infer a scanner verdict: they only verify bytes that were
 * actually downloaded from private storage by the server.
 */

export class MediaValidationError extends Error {
  constructor(readonly code: string, message: string) {
    super(message);
    this.name = "MediaValidationError";
  }
}

export const MAX_OBJECT_BYTES = 209_715_200;

export const MIME_ALLOWLIST: Record<string, string[]> = {
  avatars: ["image/jpeg", "image/png", "image/webp"],
  "chat-media": [
    "image/jpeg",
    "image/png",
    "image/webp",
    "video/mp4",
    "audio/mpeg",
    "audio/mp4",
  ],
  statuses: ["image/jpeg", "image/png", "image/webp", "video/mp4"],
  posts: ["image/jpeg", "image/png", "image/webp", "video/mp4"],
  shorts: ["video/mp4"],
};

const UUID_PATTERN =
  /^[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i;

export function isCanonicalUuid(value: unknown): value is string {
  return typeof value === "string" && UUID_PATTERN.test(value);
}

/** Accept only one well-formed Bearer token and normalize the scheme casing. */
export function normalizeBearerAuthorization(value: unknown): string | null {
  if (typeof value !== "string" || value.length > 16_500) return null;
  const match = /^Bearer ([A-Za-z0-9._-]{1,16384})$/i.exec(value);
  return match ? "Bearer " + match[1] : null;
}

/** Mirrors the SQL owner-path shapes enforced by storage insert policies. */
export function isOwnerPath(
  bucket: unknown,
  path: unknown,
  owner: unknown,
): boolean {
  if (
    typeof bucket !== "string" || typeof path !== "string" ||
    !isCanonicalUuid(owner)
  ) return false;
  if (
    path.length === 0 || path.length > 512 || path.includes("//") ||
    path.startsWith("/")
  ) return false;
  const parts = path.split("/");
  const mediaName = (pattern: RegExp) =>
    parts[1] !== undefined && pattern.test(parts[1]);
  switch (bucket) {
    case "avatars":
      return parts.length === 2 && parts[0] === owner &&
        mediaName(/^avatar_[0-9]{10,20}\.(jpg|jpeg|png|webp)$/);
    case "chat-media":
      return parts.length === 3 && isCanonicalUuid(parts[0]) &&
        parts[1] === owner &&
        parts[2] !== undefined &&
        /^[0-9]{10,20}\.(jpg|jpeg|png|webp)$/.test(parts[2]);
    case "statuses":
    case "posts":
      return parts.length === 2 && parts[0] === owner &&
        mediaName(/^[0-9]{10,20}\.(jpg|jpeg|png|webp|mp4)$/);
    case "shorts":
      return parts.length === 2 && parts[0] === owner &&
        mediaName(/^[0-9]{10,20}\.mp4$/);
    default:
      return false;
  }
}

export function assertDeclaredMime(bucket: string, mime: string): void {
  if (!MIME_ALLOWLIST[bucket]?.includes(mime)) {
    throw new MediaValidationError(
      "mime_not_allowed",
      "Declared media type is not allowed",
    );
  }
}

function ascii(bytes: Uint8Array, start: number, end: number): string {
  let value = "";
  for (let index = start; index < end; index += 1) {
    value += String.fromCharCode(bytes[index]);
  }
  return value;
}

function hasMagic(bytes: Uint8Array, mime: string): boolean {
  if (bytes.length < 12) return false;
  switch (mime) {
    case "image/jpeg":
      return bytes[0] === 0xff && bytes[1] === 0xd8 && bytes[2] === 0xff;
    case "image/png":
      return bytes[0] === 0x89 && ascii(bytes, 1, 4) === "PNG" &&
        bytes[4] === 0x0d && bytes[5] === 0x0a && bytes[6] === 0x1a &&
        bytes[7] === 0x0a;
    case "image/webp":
      return ascii(bytes, 0, 4) === "RIFF" && ascii(bytes, 8, 12) === "WEBP";
    case "video/mp4":
      return ascii(bytes, 4, 8) === "ftyp";
    default:
      return false;
  }
}

export async function sha256Hex(bytes: Uint8Array): Promise<string> {
  // Copy into an ArrayBuffer-backed view: Uint8Array<ArrayBufferLike> can also
  // be SharedArrayBuffer-backed, which WebCrypto's BufferSource type rejects.
  const buffer = new ArrayBuffer(bytes.byteLength);
  new Uint8Array(buffer).set(bytes);
  const digest = await crypto.subtle.digest("SHA-256", buffer);
  return [...new Uint8Array(digest)].map((byte) =>
    byte.toString(16).padStart(2, "0")
  ).join("");
}

/** Verifies real downloaded bytes against the client's declared MIME. */
export async function inspectMediaBytes(
  bytes: Uint8Array,
  declaredMime: string,
  bucket: string,
): Promise<{ sha256: string; mime: string; size: number }> {
  assertDeclaredMime(bucket, declaredMime);
  if (bytes.byteLength === 0) {
    throw new MediaValidationError("empty_media", "Media object is empty");
  }
  if (bytes.byteLength > MAX_OBJECT_BYTES) {
    throw new MediaValidationError(
      "media_too_large",
      "Media object is too large",
    );
  }
  if (!hasMagic(bytes, declaredMime)) {
    throw new MediaValidationError(
      "magic_mismatch",
      "Media bytes do not match the declared type",
    );
  }
  return {
    sha256: await sha256Hex(bytes),
    mime: declaredMime,
    size: bytes.byteLength,
  };
}

/** Pending states only. A clean/ready verdict must come from a real scanner or
 * processor integration, never from this function. */
export function pendingValidationState(
  mime: string,
): "needs_review" | "processing" {
  return mime === "video/mp4" ? "processing" : "needs_review";
}

export interface AssetSnapshot {
  state?: unknown;
  sha256?: unknown;
  attempts?: unknown;
  next_attempt_at?: unknown;
}

const VALIDATED_STATES = new Set([
  "needs_review",
  "processing",
  "clean",
  "ready",
  "rejected",
]);

/** Idempotency and bounded retry decision, used to avoid re-reading unchanged
 * objects and to respect the server-side attempt/backoff window. */
export function claimDecision(
  asset: AssetSnapshot | null,
  sha256: string,
  nowMs = Date.now(),
  maxAttempts = 5,
): { claim: boolean; reason: string } {
  if (!asset) return { claim: false, reason: "not_enqueued" };
  if (
    asset.sha256 === sha256 && typeof asset.state === "string" &&
    VALIDATED_STATES.has(asset.state)
  ) {
    return { claim: false, reason: "already_validated" };
  }
  const attempts =
    typeof asset.attempts === "number" && Number.isFinite(asset.attempts)
      ? asset.attempts
      : 0;
  if (attempts >= maxAttempts) {
    return { claim: false, reason: "attempt_limit_exceeded" };
  }
  if (typeof asset.next_attempt_at === "string") {
    const next = Date.parse(asset.next_attempt_at);
    if (Number.isFinite(next) && next > nowMs) {
      return { claim: false, reason: "backoff" };
    }
  }
  return { claim: true, reason: "claimed" };
}

/** Deterministic backoff used for logging and external schedulers; the SQL
 * claim RPC remains the authoritative enforcement point. */
export function backoffDelayMs(attempts: number): number {
  if (!Number.isInteger(attempts) || attempts < 1) return 0;
  return Math.min(attempts, 5) * 60_000;
}
