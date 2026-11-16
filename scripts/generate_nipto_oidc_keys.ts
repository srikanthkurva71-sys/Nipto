// Generate the Nipto OIDC ES256 signing key pair.
// Run locally with: deno run --allow-env scripts/generate_nipto_oidc_keys.ts
// Keep privateJwk out of source control and configure it only as a Supabase
// Edge Function secret. The public JWK is published by the Nipto identity issuer.
const pair = await crypto.subtle.generateKey(
  { name: "ECDSA", namedCurve: "P-256" },
  true,
  ["sign", "verify"],
);

const privateJwk = await crypto.subtle.exportKey("jwk", pair.privateKey);
const publicJwk = await crypto.subtle.exportKey("jwk", pair.publicKey);

console.log(JSON.stringify({
  kid: "nipto-es256-2026-11",
  privateJwk,
  publicJwk: {
    kty: publicJwk.kty,
    crv: publicJwk.crv,
    x: publicJwk.x,
    y: publicJwk.y,
    use: "sig",
    alg: "ES256",
    kid: "nipto-es256-2026-11",
  },
}, null, 2));
