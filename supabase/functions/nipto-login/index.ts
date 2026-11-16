
const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
  "Content-Type": "application/json",
};

function reply(body: Record<string, unknown>, status = 200, extra: Record<string, string> = {}) {
  return new Response(JSON.stringify(body), {
    status,
    headers: { ...corsHeaders, ...extra },
  });
}

function hex(bytes: ArrayBuffer): string {
  return Array.from(new Uint8Array(bytes), (value) => value.toString(16).padStart(2, "0")).join("");
}

Deno.serve(async (request: Request) => {
  if (request.method === "OPTIONS") return new Response("ok", { headers: corsHeaders });
  if (request.method !== "POST") return reply({ error: "Method not allowed" }, 405);

  const supabaseUrl = Deno.env.get("SUPABASE_URL");
  const serviceRoleKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY");
  const publicKey = Deno.env.get("SUPABASE_ANON_KEY") ?? Deno.env.get("SUPABASE_PUBLISHABLE_KEY");

  if (!supabaseUrl || !serviceRoleKey || !publicKey) {
    return reply({ error: "Authentication service is not configured" }, 503);
  }

  try {
    const rawBody = await request.text();
    if (rawBody.length > 4096) return reply({ error: "Invalid request" }, 400);

    const body = JSON.parse(rawBody) as { nipto_id?: unknown; password?: unknown };
    const niptoId = typeof body.nipto_id === "string" ? body.nipto_id.trim().toLowerCase() : "";
    const password = typeof body.password === "string" ? body.password : "";

    if (!/^[a-z0-9_]{3,24}$/.test(niptoId) || password.length < 8 || password.length > 128) {
      return reply({ error: "Invalid Nipto ID or password" }, 400);
    }

    const forwarded = request.headers.get("cf-connecting-ip")
      ?? request.headers.get("x-real-ip")
      ?? request.headers.get("x-forwarded-for")?.split(",")[0]?.trim()
      ?? "unknown";
    const digest = await crypto.subtle.digest(
      "SHA-256",
      new TextEncoder().encode(forwarded + "\u0000" + niptoId),
    );
    const keyHash = hex(digest);

    const rateResponse = await fetch(supabaseUrl + "/rest/v1/rpc/consume_nipto_login_attempt", {
      method: "POST",
      headers: {
        apikey: serviceRoleKey,
        Authorization: "Bearer " + serviceRoleKey,
        "Content-Type": "application/json",
      },
      body: JSON.stringify({ p_key_hash: keyHash }),
    });
    if (!rateResponse.ok) return reply({ error: "Authentication is temporarily unavailable" }, 503);
    const allowed = await rateResponse.json();
    if (allowed !== true) {
      return reply({ error: "Too many attempts. Please try again later." }, 429, { "Retry-After": "900" });
    }

    const lookupResponse = await fetch(supabaseUrl + "/rest/v1/rpc/resolve_nipto_login", {
      method: "POST",
      headers: {
        apikey: serviceRoleKey,
        Authorization: "Bearer " + serviceRoleKey,
        "Content-Type": "application/json",
      },
      body: JSON.stringify({ p_nipto_id: niptoId }),
    });

    if (!lookupResponse.ok) return reply({ error: "Unable to sign in right now" }, 503);
    const email = await lookupResponse.json();

    // Keep account-existence details private: missing ID and wrong password look identical.
    if (typeof email !== "string" || !email) {
      return reply({ error: "Invalid Nipto ID or password" }, 401);
    }

    const authResponse = await fetch(supabaseUrl + "/auth/v1/token?grant_type=password", {
      method: "POST",
      headers: {
        apikey: publicKey,
        "Content-Type": "application/json",
      },
      body: JSON.stringify({ email, password }),
    });

    const session = await authResponse.json();
    if (!authResponse.ok) return reply({ error: "Invalid Nipto ID or password" }, 401);

    return reply({
      access_token: session.access_token,
      refresh_token: session.refresh_token,
      token_type: session.token_type,
      expires_in: session.expires_in,
    });
  } catch {
    // Do not log or echo credentials, tokens, or provider response bodies.
    return reply({ error: "Unable to sign in right now" }, 500);
  }
});
