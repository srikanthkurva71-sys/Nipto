# Nipto hosted authentication website

## Decision

Nipto uses its own hosted, Nipto-branded authentication website for browser-based sign-in and account creation. The website is served by the existing `nipto-identity` Supabase Edge Function at its OIDC `/authorize` endpoint.

This is not Supabase's default email/password page and it is not a third-party identity-provider page. Supabase Auth launches the OIDC authorization flow; Nipto renders the credential screens and remains the authority for Nipto IDs and passwords.

## User flow

1. The Flutter app calls Supabase Auth `signInWithOAuth(OAuthProvider('custom:nipto'))`.
2. Supabase redirects the browser to the Nipto OIDC issuer's `/authorize` endpoint.
3. Nipto validates the OIDC request, PKCE challenge, redirect URI, client ID, state and optional nonce.
4. Nipto creates a short-lived, CSRF-protected authorization transaction and renders the Nipto sign-in or registration page.
5. The user submits a Nipto ID and password to Nipto over HTTPS.
6. Nipto applies server-side validation, rate limiting and Argon2id password verification/hashing.
7. Nipto consumes the one-time authorization transaction and issues a short-lived authorization code bound to the PKCE challenge.
8. The browser is redirected to Supabase Auth's callback. Supabase exchanges the code at Nipto's OIDC token endpoint and establishes the Supabase session.
9. Flutter receives the configured deep-link callback and restores the Supabase session.

## Existing implementation

- OIDC issuer: `https://advmjribduqzyuwktkod.supabase.co/functions/v1/nipto-identity`
- Authorization page: `/authorize`
- Registration screen: `/authorize?screen=register` (must be reached through a valid Supabase OIDC authorization request)
- Token endpoint: `/token`
- User info endpoint: `/userinfo`
- Public signing keys: `/jwks`
- OIDC discovery: `/.well-known/openid-configuration`
- Flutter callback: `nipto://auth-callback`
- Supabase callback: `https://advmjribduqzyuwktkod.supabase.co/auth/v1/callback`

The screen selector is only a presentation choice inside a validated OIDC request. Do not expose an unvalidated shortcut that accepts credentials or creates accounts outside the authorization transaction.

## Security boundaries

- Nipto owns Nipto ID availability, account registration, password hashing, password verification, recovery and account status.
- Supabase Auth brokers the OIDC identity into an application session.
- The OIDC authorization code is single-use, short-lived and PKCE-bound.
- The authorization form uses a server-created transaction and CSRF token.
- Passwords are sent only to the Nipto HTTPS issuer and are never stored in Flutter preferences, app assets, logs or analytics.
- `SUPABASE_SERVICE_ROLE_KEY`, `NIPTO_OIDC_CLIENT_SECRET` and `NIPTO_OIDC_PRIVATE_JWK` remain server-side secrets. They must never be placed in the website's browser JavaScript or Flutter app.
- Keep the OIDC issuer and Supabase callback allowlists exact. Do not accept arbitrary redirect URLs.
- Keep the existing recovery endpoints and native recovery UI until a complete, tested web recovery flow is available.

## Deployment and release status

The OIDC issuer and its branded authorization page are already present in the repository and deployed as the `nipto-identity` Edge Function. The current deployed function was verified active (version 5) on 2026-11-19.

This document records the intended architecture; it does not claim that the full registration/login callback flow has passed end-to-end testing. Before release, verify on a real Android device:

- Sign in button opens the Nipto-branded browser page.
- Create account opens the Nipto registration page.
- Switching between sign-in and registration preserves the original OIDC transaction parameters.
- New Nipto ID registration and duplicate-ID handling.
- Correct and incorrect password behavior and rate limiting.
- Authorization-code/PKCE exchange and Supabase user provisioning without requiring an email address.
- Deep-link callback, session persistence, refresh and sign-out.
- Recovery, password reset and session revocation.
- No credentials, tokens, client secrets or private keys appear in logs.

## Custom domain

The current website is hosted on the Supabase Edge Function URL. A branded domain such as `auth.nipto.app` can be configured later, but only after DNS, TLS, OIDC issuer metadata, Supabase custom-provider issuer configuration and redirect validation are updated together. Do not change the issuer URL in only one place.
