export type PushJob = {
  id: string;
  user_id: string;
  delivery_type: "notification" | "incoming_call";
  payload: Record<string, unknown>;
  attempts?: number;
};

export type ServiceAccount = {
  project_id: string;
  client_email: string;
  private_key: string;
};

export function base64url(input: Uint8Array | string): string {
  const bytes = typeof input === "string"
    ? new TextEncoder().encode(input)
    : input;
  let binary = "";
  for (const byte of bytes) binary += String.fromCharCode(byte);
  return btoa(binary).replaceAll("+", "-").replaceAll("/", "_").replaceAll(
    "=",
    "",
  );
}

function asString(value: unknown): string {
  return typeof value === "string" ? value : "";
}

export function pushDataForJob(job: PushJob): Record<string, string> {
  const payload = job.payload ?? {};
  const data: Record<string, string> = {
    click_action: "FLUTTER_NOTIFICATION_CLICK",
    delivery_type: job.delivery_type,
  };
  const keys = [
    "notification_id",
    "notification_type",
    "entity_id",
    "call_id",
    "conversation_id",
    "media_type",
  ];
  for (const key of keys) {
    const value = asString(payload[key]);
    if (value) data[key] = value.slice(0, 128);
  }
  return data;
}

const VERBS: Record<string, string> = {
  follow: "started following you",
  follow_request: "sent you a follow request",
  follow_accepted: "accepted your follow request",
  like: "liked your content",
  comment: "commented on your content",
  message: "sent you a message",
  status_view: "viewed your status",
  system: "sent you an update",
};

export function pushTitleForJob(job: PushJob): string {
  const payload = job.payload ?? {};
  if (job.delivery_type === "incoming_call") {
    return `${asString(payload.caller_name) || "Someone"} is calling`;
  }
  return "New Nipto activity";
}

export function pushBodyForJob(job: PushJob): string {
  const payload = job.payload ?? {};
  if (job.delivery_type === "incoming_call") {
    return asString(payload.media_type) === "video"
      ? "Video call"
      : "Audio call";
  }
  const notificationType = asString(payload.notification_type);
  const verb = VERBS[notificationType] ?? "has new activity";
  return `${asString(payload.actor_name) || "Someone"} ${verb}`;
}

export function isInvalidTokenStatus(status: number, errorCode = ""): boolean {
  return status === 404 || status === 410 || errorCode === "UNREGISTERED";
}

export function parseServiceAccount(raw: string): ServiceAccount {
  let value: unknown;
  try {
    value = JSON.parse(raw);
  } catch {
    throw new Error("Invalid FCM service account");
  }
  if (typeof value !== "object" || value === null || Array.isArray(value)) {
    throw new Error("Invalid FCM service account");
  }
  const account = value as Record<string, unknown>;
  if (
    typeof account.project_id !== "string" || !account.project_id ||
    typeof account.client_email !== "string" || !account.client_email ||
    typeof account.private_key !== "string" ||
    !account.private_key.includes("PRIVATE KEY")
  ) {
    throw new Error("Invalid FCM service account");
  }
  return {
    project_id: account.project_id,
    client_email: account.client_email,
    private_key: account.private_key,
  };
}

export function pemPrivateKeyToDer(pem: string): Uint8Array<ArrayBuffer> {
  const normalized = pem
    .replace(/-----BEGIN [^-]+-----/g, "")
    .replace(/-----END [^-]+-----/g, "")
    .replace(/\s/g, "");
  if (!normalized || !/^[A-Za-z0-9+/=]+$/.test(normalized)) {
    throw new Error("Invalid FCM private key");
  }
  const binary = atob(normalized);
  const bytes = new Uint8Array(new ArrayBuffer(binary.length));
  for (let index = 0; index < binary.length; index += 1) {
    bytes[index] = binary.charCodeAt(index);
  }
  return bytes;
}

export async function signServiceAccountJwt(
  account: ServiceAccount,
  issuedAt = Math.floor(Date.now() / 1000),
): Promise<string> {
  const header = base64url(JSON.stringify({ alg: "RS256", typ: "JWT" }));
  const payload = base64url(JSON.stringify({
    iss: account.client_email,
    scope: "https://www.googleapis.com/auth/firebase.messaging",
    aud: "https://oauth2.googleapis.com/token",
    iat: issuedAt,
    exp: issuedAt + 3600,
  }));
  const input = `${header}.${payload}`;
  const key = await crypto.subtle.importKey(
    "pkcs8",
    pemPrivateKeyToDer(account.private_key),
    { name: "RSASSA-PKCS1-v1_5", hash: "SHA-256" },
    false,
    ["sign"],
  );
  const signature = await crypto.subtle.sign(
    { name: "RSASSA-PKCS1-v1_5", hash: "SHA-256" },
    key,
    new TextEncoder().encode(input),
  );
  return `${input}.${base64url(new Uint8Array(signature))}`;
}

export function fcmErrorStatus(status: number, body: string): number {
  try {
    const value = JSON.parse(body) as {
      error?: { status?: string; code?: number; message?: string };
    };
    const error = value.error;
    if (!error) return status;
    if (error.status === "NOT_FOUND" || error.code === 404) return 404;
    if (error.status === "PERMISSION_DENIED" || error.code === 403) return 403;
    if (error.status === "INVALID_ARGUMENT" || error.code === 400) return 400;
  } catch {
    // Keep the original HTTP status when the error body is not JSON.
  }
  return status;
}
