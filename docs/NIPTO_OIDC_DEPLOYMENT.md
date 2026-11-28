# Nipto OIDC deployment checklist

This runbook describes deployment and validation of the Nipto-owned ID/password issuer. The issuer and Supabase custom provider are deployed/configured, and a real protocol-level registration → PKCE → Supabase session flow has succeeded. Flutter device and full account-recovery checks remain release gates.

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

## Custom provider claim configuration

Supabase Auth strips unrecognized ID-token claims unless they are explicitly allowlisted. The `custom:nipto` provider must be configured with:

- `email_optional`: `true`
- `scopes`: `openid profile`
- `custom_claims_allowlist`: `["nipto_id", "display_name"]`
- attribute mapping: `{}`
- issuer and discovery URL from the OIDC issuer above

The Nipto ID token includes `preferred_username` and `name` as standard profile claims plus `nipto_id` and `display_name` as custom claims. Supabase stores allowlisted custom claims under `raw_user_meta_data->'custom_claims'`. Migration `20261126122909_nipto_oidc_custom_claims_provisioning.sql` updates the `auth.users` trigger to read the Nipto ID and display name from that object (with top-level fallbacks). The Flutter session manager reads the same nested object when deriving the current Nipto identity. Without both settings, a valid no-email signup reaches Supabase Auth but fails user provisioning with `A valid Nipto ID is required`.

The provider config can be set with the Auth admin API using a server-side service-role key:

```sh
curl -X PUT 'https://<project>.supabase.co/auth/v1/admin/custom-providers/custom:nipto' \
  -H 'Authorization: Bearer <service-role-key>' \
  -H 'apikey: <service-role-key>' \
  -H 'Content-Type: application/json' \
  -d '{"custom_claims_allowlist":["nipto_id","display_name"],"attribute_mapping":{},"email_optional":true}'
```

Never place the service-role key in Flutter, CI logs, Git, or client-side scripts.

## Deployment order

1. Confirm all migrations are applied and the native Nipto account tables/RPCs exist.
2. Configure the required Edge Function secrets.
3. Deploy `supabase/functions/nipto-identity/index.ts` with `validation.ts` and `form_body.ts`. The app uses `POST /authorize/prepare` so the Edge Function can resolve Supabase's manual authorize redirect; browser clients cannot read its `Location` header.
4. **Verified:** the discovery document and JWKS endpoints both returned HTTP 200. The JWKS publishes an ES256 P-256 signing key.
5. **Configured:** Supabase Dashboard → Authentication → Sign In / Providers → Custom Providers lists `Nipto` with identifier `custom:nipto`, type `oidc`, status Enabled. The provider uses auto-discovery, issuer `https://advmjribduqzyuwktkod.supabase.co/functions/v1/nipto-identity`, scopes `openid profile`, allows users without email, and allowlists the `nipto_id` and `display_name` claims. Client credentials were generated locally and uploaded as Edge Function secrets; the matching values were entered in the provider form. Supabase Auth callback: `https://advmjribduqzyuwktkod.supabase.co/auth/v1/callback`. Ensure `nipto://auth-callback` is allowed in Authentication → URL Configuration.
6. **Verified at protocol level:** server-side authorize preparation, a real registration through `/authorize/native`, the Supabase callback, a PKCE token exchange with the client verifier, and `/auth/v1/user` all succeeded. The returned identity used `custom:nipto` with an empty email. The test account and auth user were removed after verification.
7. **Still required on device:** test the native Flutter forms, sign-out, refresh, duplicate-ID suggestions, password rejection, account recovery, session revocation, and legacy-account migration. Verify Flutter deep-link restoration after app restart on Android.
8. Run two-device smoke tests and independent security review before release.

## Release gate

The protocol-level flow is verified. Do not call Nipto authentication production-ready until a real Flutter client can create a Nipto ID/password account through the in-app forms, sign in through `custom:nipto`, retain/refresh its Supabase session, restore the session after restart, and complete recovery without an email requirement on a physical Android device.

Never place service-role credentials, OIDC client secrets, or private signing keys in Flutter assets, `dev.json`, CI logs, or Git history.


## Verified deployment snapshot — 2026-11-19

- `nipto-identity` Edge Function: active; JWT verification disabled because the public OIDC endpoints and protected application routes implement their own protocol/authentication checks.
- Supabase Custom Provider: `custom:nipto`, OIDC, Enabled.
- Discovery endpoint: HTTP 200.
- JWKS endpoint: HTTP 200; ES256 / P-256 key published.
- Client ID and client secret: configured as server-side Edge Function secrets and entered in the Supabase provider form. Secret values are intentionally not recorded here.
- **Not yet verified at that time:** complete authorization-code/PKCE exchange, token signature/audience/nonce validation by Supabase, user provisioning without email, Flutter callback restoration, refresh/logout, recovery and two-device flows.

## Verified deployment snapshot — 2026-11-26

- `nipto-identity` Edge Function: active version 16, entrypoint `index.ts`, files `index.ts`, `validation.ts`, `form_body.ts`, JWT verification disabled for its public protocol routes and protected routes with their own checks. It is the only deployed identity Edge Function; the retired `nipto-login` function was undeployed and its local source/config removed.
- `custom:nipto`: OIDC provider enabled, `email_optional=true`, scopes `openid profile`, PKCE enabled, `custom_claims_allowlist=["nipto_id","display_name"]`.
- Native authorization endpoint `POST /authorize/native`: validated action/screen, client, redirect URI, state, nonce, S256 challenge, credential fields, and rate limits before creating the OIDC transaction and code.
- Full protocol probe: `GET /auth/v1/authorize` → native credential submission → Supabase callback → PKCE token exchange → authenticated `/auth/v1/user` succeeded. The returned identity had `provider=custom:nipto`, `email=""`, and `user_metadata.custom_claims.nipto_id` populated.
- The probe account and Supabase auth user were deleted after verification; no test identity remains in the project.
- `auth.users` trigger now reads Nipto claims from `raw_user_meta_data->'custom_claims'` via migration `20261126122909_nipto_oidc_custom_claims_provisioning.sql`.
- Migration history is reconciled with the remote project: local filenames use the recorded versions `20261126115641` and `20261126122909`. The remote hardening row retains the descriptive name `20261126160836_nipto_least_privilege_hardening`; its SQL is idempotent.
- **Still unverified:** Flutter deep-link callback restoration, refresh/logout lifecycle on device, in-app recovery, legacy migration, two-device calling, push delivery, media, and release signing.

## Verified deployment snapshot — 2026-11-27

- `nipto-identity` Edge Function: active version 16, JWT verification disabled for protocol routes that self-verify their inputs and protected routes with their own checks.
- `POST /authorize/prepare`: validates the SDK-generated Supabase authorize URL, server-side reads the manual redirect, validates the provider redirect, and returns the provider PKCE challenge needed by the native OIDC bridge. This removes the browser-hostile in-Dart redirect parse that stopped the app-level flow.
- Full protocol probe: `/auth/v1/authorize` → `/authorize/prepare` → `/authorize/native` → Supabase callback → PKCE token exchange → authenticated user lookup succeeded. The account had no email and was deleted after verification.
- The first hosted Android emulator E2E attempt failed before app start because the SDK emulator could not load `libpulse.so.0`. A browser fallback was rejected because Flutter integration tests do not support web devices. The second attempt installed `libpulse0`, `libgl1` and `libxkbfile1`, but the API 36 image exited before `emulator-5554` appeared because `-accel off` requires the explicit `ANDROID_I_WANT_MY_TCG=yes` opt-in. The third attempt accepted the TCG opt-in but still exited before boot: Qt 6.5+ needed `libxcb-cursor0`, and the action auto-disabled KVM despite `/dev/kvm` being available. The fourth attempt booted and launched the app, but registration stopped before account creation: `supabase_flutter`'s `getOAuthSignInUrl` does not include `client_id` in the initial `/auth/v1/authorize` URL, while `authorize/prepare` required it there and returned HTTP 400. Supabase adds `client_id` only on the provider redirect. `nipto-identity` v17 now reads the expected client ID from its secret for rate limiting and validates the returned `client_id` on the provider-leg URL. No probe account was created in any failed attempt. The workflow follows the action's documented headless/KVM setup (`libxcb-cursor0`, udev KVM rule, `disable-linux-hw-accel: false`, `-no-window -gpu swiftshader_indirect`), retains the TCG fallback, allows 20 minutes for boot, and runs the same app flow on `emulator-5554`; the rerun result must be checked before claiming device-level validation.
- **Still unverified:** Android device/runtime behavior, deep-link restoration after restart, refresh/logout lifecycle on device, in-app recovery, legacy migration, two-device calling, push delivery on device, media, and release signing.

## Verified deployment snapshot — 2026-11-28

- `nipto-identity` Edge Function: active version 17, files `index.ts`, `validation.ts`, `form_body.ts`, JWT verification disabled for protocol routes that self-verify their inputs and protected routes with their own checks.
- `POST /authorize/prepare` now accepts the SDK-generated authorize URL without `client_id`; it reads the expected client from its server-side secret for rate limiting and validates `client_id` on Supabase's provider redirect instead.
- A live protocol probe using the exact `supabase_flutter` URL shape (`provider`, `redirect_to`, `screen`, `flow_type`, `code_challenge`, `code_challenge_method`, no `client_id`) returned `prepare 200`; registration → native authorization → callback → PKCE exchange → authenticated user lookup passed with `provider=custom:nipto`, empty email, and the matching `nipto_id` claim.
- Forward migration `20261128000000_nipto_message_mutation_access_gate.sql` was applied and recorded; message edit/delete functions and policies now call the shared conversation-access helper.
- **Still unverified:** the app-level hosted-emulator rerun after v17, physical Android device/runtime behavior, deep-link restoration after restart, refresh/logout lifecycle on device, in-app recovery, legacy migration, two-device calling, push delivery on device, media, and release signing.
