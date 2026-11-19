// Generate the Nipto OIDC client credentials and ES256 signing key.
// Run locally with: deno run scripts/generate_nipto_oidc_keys.ts
// Store the output in a password manager, then configure server-side Supabase
// Edge Function secrets. Never commit or paste the private values into GitHub.
function randomBase64Url(byteLength: number): string {
  const bytes = crypto.getRandomValues(new Uint8Array(byteLength));
  let binary = "";
  for (const byte of bytes) binary += String.fromCharCode(byte);
  return btoa(binary).replaceAll("+", "-").replaceAll("/", "_").replace(/=+$/, "");
}

const pair = await crypto.subtle.generateKey(
  { name: "ECDSA", namedCurve: "P-256" },
  true,
  ["sign", "verify"],
);
const kid = `nipto-es256-${crypto.randomUUID().slice(0, 12)}`;
const privateJwk = {
  ...await crypto.subtle.exportKey("jwk", pair.privateKey),
  kid,
  alg: "ES256",
  use: "sig",
};
const jwk = await crypto.subtle.exportKey("jwk", pair.publicKey);
const publicKey = {
  kty: jwk.kty,
  crv: jwk.crv,
  x: jwk.x,
  y: jwk.y,
  use: "sig",
  alg: "ES256",
  kid,
};

console.log(JSON.stringify({
  NIPTO_OIDC_CLIENT_ID: `nipto-prod-${randomBase64Url(12)}`,
  NIPTO_OIDC_CLIENT_SECRET: randomBase64Url(32),
  NIPTO_OIDC_KID: kid,
  NIPTO_OIDC_PRIVATE_JWK: privateJwk,
  NIPTO_OIDC_PUBLIC_KEYS: [publicKey],
}, null, 2));
