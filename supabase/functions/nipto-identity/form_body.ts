export class FormBodyError extends Error {
  constructor(readonly status: 400 | 413 | 415, message: string) {
    super(message);
    this.name = "FormBodyError";
  }
}

/** Parse a URL-encoded request body while enforcing a streaming byte limit. */
export async function readUrlEncodedForm(
  request: Request,
  maxBytes = 8_192,
): Promise<FormData> {
  const contentType = request.headers.get("content-type") ?? "";
  if (!/^application\/x-www-form-urlencoded(?:;|$)/i.test(contentType)) {
    throw new FormBodyError(415, "A URL-encoded request body is required");
  }
  const declaredLength = request.headers.get("content-length");
  if (declaredLength !== null) {
    if (!/^\d+$/.test(declaredLength)) {
      throw new FormBodyError(400, "Invalid content length");
    }
    if (Number(declaredLength) > maxBytes) {
      throw new FormBodyError(413, "Request is too large");
    }
  }
  if (!request.body) throw new FormBodyError(400, "Invalid request");

  const reader = request.body.getReader();
  const chunks: Uint8Array[] = [];
  let total = 0;
  while (true) {
    const { done, value } = await reader.read();
    if (done) break;
    total += value.byteLength;
    if (total > maxBytes) {
      await reader.cancel();
      throw new FormBodyError(413, "Request is too large");
    }
    chunks.push(value);
  }

  const bytes = new Uint8Array(total);
  let offset = 0;
  for (const chunk of chunks) {
    bytes.set(chunk, offset);
    offset += chunk.byteLength;
  }
  try {
    return await new Response(bytes, {
      headers: { "Content-Type": contentType },
    }).formData();
  } catch {
    throw new FormBodyError(400, "Invalid URL-encoded form");
  }
}
