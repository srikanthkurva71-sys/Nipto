// Generate an ES256 key for the Nipto OIDC issuer.
// Run locally with: deno run scripts/generate_nipto_oidc_keys.ts
// Keep privateJwk out of source control. Configure it only as a Supabase
// Edge Function secret. Public keys may be stored in NIPTO_OIDC_PUBLIC_KEYS.
const pair = await crypto.subtle.generateKey(
  { name: "ECDSA", namedCurve: "P-256" },
  true,
  ["sign", "verify"],
);

const kid = `nipto-es256-${crypto.randomUUID().slice(0, 12)}`;
const privateJwk = await crypto.subtle.exportKey("jwk", pair.privateKey);
const publicJwk = await crypto.subtle.exportKey("jwk", pair.publicKey);

privateJwk.kid = kid;
privateJwk.alg = "ES256";
privateJwk.use = "sig";

const publicKey = {
  kty: publicJwk.kty,
  crv: publicJwk.crv,
  x: publicJwk.x,
  y: publicJwk.y,
  use: "sig",
  alg: "ES256",
  kid,
};

console.log(JSON.stringify({
  NIPTO_OIDC_KID: kid,
  NIPTO_OIDC_PRIVATE_JWK: privateJwk,
  NIPTO_OIDC_PUBLIC_KEYS: [publicKey],
}, null, 2));
