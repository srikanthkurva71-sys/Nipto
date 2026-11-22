const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
  "Content-Type": "application/json",
};

function reply(body: Record<string, unknown>, status = 200) {
  return new Response(JSON.stringify(body), { status, headers: corsHeaders });
}

function hex(bytes: ArrayBuffer): string {
  return Array.from(new Uint8Array(bytes), (value) => value.toString(16).padStart(2, "0")).join("");
}

Deno.serve(async (request: Request) => {
  if (request.method === "OPTIONS") return new Response("ok", { headers: corsHeaders });
  if (request.method !== "POST") return reply({ error: "Method not allowed" }, 405);

  const supabaseUrl = Deno.env.get("SUPABASE_URL");
  const serviceRoleKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY");
  if (!supabaseUrl || !serviceRoleKey) return reply({ error: "Registration service is not configured" }, 503);

  try {
    const raw = await request.text();
    if (raw.length > 4096) return reply({ error: "Invalid request" }, 400);
    const body = JSON.parse(raw) as { nipto_id?: unknown; password?: unknown; display_name?: unknown };
    const niptoId = typeof body.nipto_id === "string" ? body.nipto_id.trim().toLowerCase() : "";
    const password = typeof body.password === "string" ? body.password : "";
    const displayName = typeof body.display_name === "string" ? body.display_name.trim() : "";

    if (!/^[a-z0-9_]{3,24}$/.test(niptoId)
      || ["admin", "administrator", "support", "help", "nipto", "official", "security", "moderator"].includes(niptoId)
      || password.length < 8 || password.length > 128
      || displayName.length < 1 || displayName.length > 50) {
      return reply({ error: "Invalid registration details" }, 400);
    }

    const forwarded = request.headers.get("cf-connecting-ip")
      ?? request.headers.get("x-real-ip")
      ?? request.headers.get("x-forwarded-for")?.split(",")[0]?.trim()
      ?? "unknown";
    const encoder = new TextEncoder();
    const limiterKey = await crypto.subtle.importKey(
      "raw", encoder.encode(serviceRoleKey), { name: "HMAC", hash: "SHA-256" }, false, ["sign"],
    );
    const digest = await crypto.subtle.sign("HMAC", limiterKey, encoder.encode(forwarded + "\u0000" + niptoId));
    const keyHash = hex(digest);
    const rateResponse = await fetch(supabaseUrl + "/rest/v1/rpc/consume_nipto_login_attempt", {
      method: "POST",
      headers: { apikey: serviceRoleKey, Authorization: "Bearer " + serviceRoleKey, "Content-Type": "application/json" },
      body: JSON.stringify({ p_key_hash: keyHash }),
    });
    if (!rateResponse.ok) return reply({ error: "Registration is temporarily unavailable" }, 503);
    if (await rateResponse.json() !== true) return reply({ error: "Too many attempts. Please try again later." }, 429);

    // Supabase Auth requires an email-shaped identifier internally. This opaque,
    // non-deliverable address is never requested from or displayed to the user.
    const internalEmail = "nipto_" + niptoId + "@accounts.nipto.invalid";
    const createResponse = await fetch(supabaseUrl + "/auth/v1/admin/users", {
      method: "POST",
      headers: { apikey: serviceRoleKey, Authorization: "Bearer " + serviceRoleKey, "Content-Type": "application/json" },
      body: JSON.stringify({
        email: internalEmail,
        password,
        email_confirm: true,
        user_metadata: { nipto_id: niptoId, display_name: displayName },
      }),
    });
    if (!createResponse.ok) {
      // Do not reveal whether a Nipto ID or internal identity already exists.
      return reply({ error: "Could not create account. Choose another Nipto ID or try again." }, 409);
    }
    return reply({ created: true });
  } catch {
    return reply({ error: "Unable to create account right now" }, 500);
  }
});
