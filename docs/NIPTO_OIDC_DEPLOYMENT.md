# Nipto OIDC deployment checklist

This runbook describes deployment and validation of the Nipto-owned ID/password issuer. The issuer and Supabase custom provider are now deployed/configured; the end-to-end authentication checks below remain release gates.

## Current architecture

- Flutter authenticates through Supabase Auth using the custom provider ID `custom:nipto`.
- The Nipto identity Edge Function is the OIDC issuer and validates Nipto IDs/passwords.
- Supabase Auth remains the session broker. The app must never contain the service-role key, OIDC client secret, or private signing JWK.
- OIDC issuer default: `https://advmjribduqzyuwktkod.supabase.co/functions/v1/nipto-identity`.
- Supabase Auth callback default: `https://advmjribduqzyuwktkod.supabase.co/auth/v1/callback`.

## Required Edge Function secrets

Configure these only in Supabase Edge Function secrets; never commit values:

- `NIPTO_OIDC_CLIENT_ID`
- `NIPTO_OIDC_CLIENT_SECRET`
- `NIPTO_OIDC_KID`
- `NIPTO_OIDC_PRIVATE_JWK`
- `SUPABASE_SERVICE_ROLE_KEY`
- `SUPABASE_URL`
- `SUPABASE_PUBLISHABLE_KEY` (or `SUPABASE_ANON_KEY`)

Optional:
- `NIPTO_OIDC_ISSUER` (defaults to the issuer URL above)
- `NIPTO_OIDC_REDIRECT_URI` (defaults to the Supabase Auth callback above)
- `NIPTO_OIDC_PUBLIC_KEYS` (for explicit public-key rotation)
- `TURN_SHARED_SECRET`, `TURN_URLS`, `TURN_STUN_URL` (for TURN credential issuance)

Generate the client credentials and ES256 key pair with `deno run scripts/generate_nipto_oidc_keys.ts`. The script prints `NIPTO_OIDC_CLIENT_ID`, `NIPTO_OIDC_CLIENT_SECRET`, `NIPTO_OIDC_KID`, `NIPTO_OIDC_PRIVATE_JWK`, and `NIPTO_OIDC_PUBLIC_KEYS`. Keep the complete output in a password manager. Put the private JWK and client secret only in Supabase Edge Function secrets; put the same client ID and client secret into the Auth provider form. Never commit the generated output.

## Deployment order

1. Confirm all migrations are applied and the native Nipto account tables/RPCs exist.
2. Configure the required Edge Function secrets.
3. Deploy `supabase/functions/nipto-identity/index.ts` together with `validation.ts`.
4. **Verified:** the discovery document and JWKS endpoints both returned HTTP 200. The JWKS publishes an ES256 P-256 signing key. This does not validate authorization-code/PKCE exchange or token acceptance.
5. **Configured:** Supabase Dashboard → Authentication → Sign In / Providers → Custom Providers lists `Nipto` with identifier `custom:nipto`, type `oidc`, status Enabled. The provider uses auto-discovery, issuer `https://advmjribduqzyuwktkod.supabase.co/functions/v1/nipto-identity`, scopes `openid profile`, and allows users without email. Client credentials were generated locally and uploaded as Edge Function secrets; the matching values were entered in the provider form. Supabase Auth callback: `https://advmjribduqzyuwktkod.supabase.co/auth/v1/callback`. Ensure `nipto://auth-callback` is allowed in Authentication → URL Configuration.
6. **Still required:** test registration, sign-in, authorization-code/PKCE exchange, no-email user provisioning, sign-out, refresh, duplicate-ID suggestions, password rejection, account recovery, session revocation, and legacy-account migration. Verify Flutter deep-link restoration after app restart on Android.
7. Run two-device smoke tests and independent security review before release.

## Release gate

Do not call Nipto authentication production-ready until a real Flutter client can create a Nipto ID/password account, sign in through `custom:nipto`, retain/refresh its Supabase session, and complete recovery without an email requirement.

Never place service-role credentials, OIDC client secrets, or private signing keys in Flutter assets, `dev.json`, CI logs, or Git history.


## Verified deployment snapshot — 2026-11-19

- `nipto-identity` Edge Function: active; JWT verification disabled because the public OIDC endpoints and protected application routes implement their own protocol/authentication checks.
- Supabase Custom Provider: `custom:nipto`, OIDC, Enabled.
- Discovery endpoint: HTTP 200.
- JWKS endpoint: HTTP 200; ES256 / P-256 key published.
- Client ID and client secret: configured as server-side Edge Function secrets and entered in the Supabase provider form. Secret values are intentionally not recorded here.
- **Not yet verified:** complete authorization-code/PKCE exchange, token signature/audience/nonce validation by Supabase, user provisioning without email, Flutter callback restoration, refresh/logout, recovery and two-device flows.
