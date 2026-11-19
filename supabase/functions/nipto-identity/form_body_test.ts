import { assertEquals, assertRejects } from "jsr:@std/assert@1.0.14";
import { FormBodyError, readUrlEncodedForm } from "./form_body.ts";

Deno.test("bounded form parser accepts a URL-encoded token exchange body", async () => {
  const request = new Request("https://nipto.invalid/token", {
    method: "POST",
    headers: { "content-type": "application/x-www-form-urlencoded" },
    body: new URLSearchParams({
      grant_type: "authorization_code",
      code: "one-time-code",
      code_verifier: "v".repeat(43),
    }),
  });

  const form = await readUrlEncodedForm(request);
  assertEquals(form.get("grant_type"), "authorization_code");
  assertEquals(form.get("code"), "one-time-code");
  assertEquals(form.get("code_verifier"), "v".repeat(43));
});

Deno.test("bounded form parser rejects non-form content types", async () => {
  const request = new Request("https://nipto.invalid/token", {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: "{}",
  });

  await assertRejects(
    () => readUrlEncodedForm(request),
    FormBodyError,
    "URL-encoded",
  );
});

Deno.test("bounded form parser rejects a declared body larger than the limit", async () => {
  const request = new Request("https://nipto.invalid/token", {
    method: "POST",
    headers: {
      "content-type": "application/x-www-form-urlencoded",
      "content-length": "9000",
    },
    body: "code=short",
  });

  const error = await assertRejects(
    () => readUrlEncodedForm(request, 8_192),
    FormBodyError,
    "too large",
  );
  assertEquals(error.status, 413);
});

Deno.test("bounded form parser rejects streamed bodies larger than the limit", async () => {
  const request = new Request("https://nipto.invalid/token", {
    method: "POST",
    headers: { "content-type": "application/x-www-form-urlencoded" },
    body: new ReadableStream<Uint8Array>({
      start(controller) {
        controller.enqueue(new TextEncoder().encode("x".repeat(5_000)));
        controller.enqueue(new TextEncoder().encode("y".repeat(5_000)));
        controller.close();
      },
    }),
    // Required by the Request constructor for streaming bodies in Deno.
    // @ts-ignore: Deno supports this non-standard RequestInit extension.
    duplex: "half",
  });

  const error = await assertRejects(
    () => readUrlEncodedForm(request, 8_192),
    FormBodyError,
    "too large",
  );
  assertEquals(error.status, 413);
});
