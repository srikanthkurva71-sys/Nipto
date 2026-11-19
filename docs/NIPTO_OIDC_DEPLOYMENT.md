# Nipto OIDC deployment checklist

This runbook describes the deployment gate for the Nipto-owned ID/password issuer. Do not enable the Supabase custom provider until every prerequisite below is configured and verified.

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
4. Verify the discovery document, JWKS, ID availability endpoint, and OIDC authorization-code/PKCE flow.
5. In Supabase Dashboard → Authentication → Sign In / Providers → Custom OAuth Providers → New Provider, choose **Auto-discovery (OIDC)**. Set identifier `custom:nipto`, name `Nipto`, the generated client ID and client secret, issuer `https://advmjribduqzyuwktkod.supabase.co/functions/v1/nipto-identity`, scopes `openid profile`, and `email_optional=true`; then create and enable it. Supabase Auth callback: `https://advmjribduqzyuwktkod.supabase.co/auth/v1/callback`. Also allow `nipto://auth-callback` in Authentication → URL Configuration for the Flutter app redirect.
6. Test registration, sign-in, sign-out, refresh, duplicate-ID suggestions, password rejection, account recovery, session revocation, and legacy-account migration.
7. Only after staging tests pass, repeat the configuration in production and run two-device smoke tests.

## Release gate

Do not call Nipto authentication production-ready until a real Flutter client can create a Nipto ID/password account, sign in through `custom:nipto`, retain/refresh its Supabase session, and complete recovery without an email requirement.

Never place service-role credentials, OIDC client secrets, or private signing keys in Flutter assets, `dev.json`, CI logs, or Git history.
