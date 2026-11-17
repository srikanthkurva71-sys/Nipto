# Nipto Native Account Authentication

**Status:** Architecture decision / implementation plan  
**Applies to:** Nipto Android app, Supabase database, Edge Functions, Realtime  
**Decision:** Nipto ID + Nipto password are the only account credentials. Nipto does not collect, require, synthesize, or use email addresses or phone numbers for authentication or account recovery.

## 1. Product contract

- Registration requires a unique Nipto ID, display name, password, and password confirmation.
- A recovery Nipto account is optional. It may be selected during registration or added later in Settings.
- No email field, email verification, email reset link, phone OTP, or external identity provider is part of the Nipto account flow.
- Sign-in accepts Nipto ID + password.
- Forgot password starts an in-app recovery request to the account's already accepted recovery Nipto account.
- The recovery account owner must approve the request while authenticated as themselves.
- Approval authorizes a narrowly scoped, one-time password reset. The recovery account never learns or chooses the owner's new password.
- A user without an accepted recovery Nipto account cannot use this recovery path. The app must say this clearly before the user relies on it.

## 2. Existing implementation: migration required

The current implementation is not compliant with this decision:
- Registration calls Supabase Auth `signUp(email, password)`.
- Sign-in resolves Nipto ID to `auth.users.email`, then calls Supabase Auth's password-token endpoint.
- Password recovery calls `resetPasswordForEmail`.
- `public.profiles.id` references `auth.users.id`; many feature policies use `auth.uid()` and application tables reference `profiles.id`.

Removing the visible email field without replacing these dependencies would break registration, sign-in, RLS, Realtime, and existing account ownership. Do not ship that partial change.

## 3. Target identity and session architecture

### Hosted Supabase integration

Keep the hosted Supabase project and its Auth session model so existing `auth.uid()`, RLS, Storage, Realtime and profile foreign keys continue to work. Build Nipto's own OpenID Connect (OIDC) identity provider as a Supabase Edge Function and register it in Authentication → Sign In / Providers → Custom OAuth/OIDC Providers using identifier `custom:nipto`, with **email_optional=true** and scopes that do not request email.

This is Nipto's own identity service, not Google, Apple, Facebook, a phone provider, or another external identity provider. Nipto stores and verifies the Nipto ID/password credentials. Supabase Auth acts only as the session broker: the Flutter app opens the Nipto-hosted OIDC authorization page through `signInWithOAuth(OAuthProvider('custom:nipto'))`; after Nipto authenticates the user, Supabase Auth creates or resumes the platform session. The provider must not return an email claim, and Supabase must accept the provider without an email address.

The Supabase access token used by PostgREST, Storage and Realtime is issued by Supabase Auth and retains the stable Supabase user UUID. Nipto's OIDC ID token is only used by Supabase Auth to establish that session. This is intentionally different from configuring Nipto as a Supabase Third-Party Auth JWT issuer.

### Nipto OIDC issuer

Implement these endpoints under a stable HTTPS issuer URL:
- `/.well-known/openid-configuration` — issuer metadata and endpoint URLs.
- `/jwks` — public signing keys with `kid`; never expose private key material.
- `/userinfo` — minimal Nipto profile claims after validating the access token.
- Nipto-specific `/register`, `/login`, `/refresh`, `/logout`, `/logout-all`, `/migrate`, password-change, device-session, and recovery endpoints protected by strict request validation and rate limits.

The Flutter app starts the Custom OAuth/OIDC authorization flow using Supabase Flutter. The Nipto-hosted authorization page collects Nipto ID and password, and the Nipto OIDC token endpoint returns a signed ID token to Supabase Auth. Supabase Auth then issues its normal access and refresh tokens to the app. No email scope or email claim is requested or required.

OIDC tokens must include:
- `iss`: exact configured Nipto issuer URL.
- `sub`: stable Nipto account UUID; equal to `public.profiles.id`.
- `aud`: registered Nipto Supabase project client identifier / accepted audience.
- `iat`, short `exp`, unique `jti`, and required OIDC `nonce` where applicable.
- A `kid` JWT header identifying the asymmetric public key in JWKS.
- No `email`, `email_verified`, `phone_number`, or synthetic contact claims. Supabase Auth adds its own `role=authenticated` claim to the app session JWT.

Use ES256 or RS256 with a reviewed WebCrypto implementation and a key-rotation process that retains old public keys until all issued tokens expire. Private signing keys belong only in Edge Function secrets. Never put them, service-role credentials, or password hashes in Flutter or source control.

### Supabase authorization

Configure the project's Authentication → Sign In / Providers → Custom OAuth Providers with identifier `custom:nipto`, the exact Nipto issuer, client ID/secret, scopes `openid profile`, and **email_optional=true**. Verify discovery, JWKS, redirect URI, client credentials, issuer and audience before enabling the provider. Do not add an email scope. The OIDC provider must not fabricate an email address.

Supabase Auth creates the application session with the same stable `auth.users.id` UUID used by `public.profiles.id`. Preserve the existing profile-to-auth-user foreign key and every profile UUID. Existing RLS policies using `auth.uid()` remain the authorization boundary; Supabase's own access token continues to authorize Data API, Storage and Realtime. Never use the service-role key in Flutter or proxy normal user operations through service-role endpoints.

### Session lifecycle

Supabase Auth owns the app's access and refresh token lifecycle. Nipto owns password verification and credential security:
- Keep the Nipto password hash in the private schema and use Argon2id.
- Supabase issues the app session only after Nipto's OIDC authorization succeeds.
- Use Supabase Auth's refresh and revocation behavior for app sessions; provide Nipto device-session management through authenticated server-side operations.
- Revoke Supabase sessions after password reset or password change.
- Store the Supabase refresh session using the platform SDK's secure persistence; never store Nipto passwords.

### OIDC issuer and signing

The issuer URL is `https://advmjribduqzyuwktkod.supabase.co/functions/v1/nipto-identity`. Supabase Auth fetches the issuer discovery document and JWKS to validate Nipto's signed ID tokens. ID tokens must contain stable Nipto identity claims, issuer, audience, expiry and nonce; include a `kid` header and use an asymmetric signing algorithm supported by Supabase Auth. Keep private signing keys only in Edge Function secrets and plan key rotation. Do not add email or phone claims.

## 3.1 Registration experience

- Normalize Nipto IDs to lowercase and validate 3–24 characters using letters, numbers and underscores only.
- Reserve platform and impersonation-sensitive names (for example, admin, support, official and security).
- Check availability against both existing public profiles and the private Nipto identity table.
- Show a clear live state: checking, available, already taken, invalid, or temporarily unable to check.
- When unavailable, suggest up to five available alternatives (for example, a suffix or numeric variant). Selecting a suggestion must trigger a fresh availability check.
- Repeat the uniqueness/availability check on the server during account creation to prevent race conditions. The unique database constraint remains authoritative.
- Offer a 20-character strong password suggestion generated locally with the browser cryptographic random generator. Do not send the suggested password to any third-party service.
- Include show/hide, length/strength feedback, and a reminder to save the password in a trusted password manager. Password suggestion is optional; users can choose their own password.
- Password minimum is 12 characters and maximum is 128. Password confirmation is required in the final native registration UX.

## 4. Password security

- Use Argon2id with a reviewed, pinned implementation and parameters calibrated on supported server runtime; store the encoded hash including salt and parameters.
- Enforce a reasonable password length (minimum 12 characters recommended; maximum 128) and reject oversized request bodies.
- Never log passwords, hashes, reset tokens, session tokens, or recovery proofs.
- Constant-time hash verification; generic sign-in error for unknown ID and wrong password.
- Rate-limit by normalized account identifier and privacy-preserving client/network key. Apply progressive cooldowns and monitoring without permanently locking accounts due to attacker-generated failures.
- Use TLS for all app-to-service traffic.
- Require current password or a valid recovery grant for password changes.
- Revoke other sessions after a password reset; the reset session may be explicitly retained if the product chooses.
- Use server-generated randomness, not Dart client randomness, for reset grants and session secrets.

## 5. Recovery Nipto account

### Linking

- A user may add one recovery Nipto account at registration or later from Settings → Security.
- The target account receives an in-app notification and must accept.
- Pending, rejected, blocked, suspended, or removed contacts cannot recover the account.
- Prevent self-linking and enforce the one-contact policy server-side.
- Both parties can see and revoke the relationship. Changing the contact requires re-approval.
- Explain that recovery is only available while the trusted account remains active and accessible.

### Forgot-password protocol

1. User enters their Nipto ID on the Forgot password screen.
2. Server returns the same generic acknowledgement whether or not the account exists or has a recovery contact.
3. If an accepted recovery contact exists, create a short-lived recovery request and notify that account in-app.
4. The request contains the requesting account's Nipto ID and a creation time, but no password, reset token, or secret.
5. The recovery contact reviews and explicitly approves or rejects while authenticated. Approval is rate-limited and audited.
6. The requester polls/continues using a high-entropy challenge secret created for this single request; the server stores only its hash. Knowing the Nipto ID or request UUID alone is insufficient.
7. After approval, the server issues a one-time, account-bound reset grant with a short expiry (target 10 minutes). The grant is delivered only to the matching recovery challenge.
8. The requester sets a new password. The server atomically consumes the grant, updates the password hash, increments the credential/session version, and revokes existing sessions.
9. Replays, expired grants, rejected requests, mismatched accounts, and concurrent consumption all fail closed.

The recovery contact never receives the reset grant and cannot set the password. A recovery approval must not create a normal authenticated session for the account owner.

### Abuse controls

- One pending recovery request per account; bounded attempts and cooldown.
- Short request expiry (target 15 minutes) and one-time grant expiry (target 10 minutes).
- Generic responses to prevent Nipto ID enumeration.
- Block checks, account-state checks, per-contact approval limits, and audit events.
- Notify the owner of approvals, rejections, password changes, and session revocations when an authenticated channel is available.
- A recovery contact cannot approve a request initiated by their own account.
- Recovery requests are not public profile data.

## 6. Existing-account migration

The existing production project uses Supabase Auth identities. Do not delete or overwrite them until the Nipto OIDC issuer and Supabase Custom OAuth/OIDC provider have passed end-to-end staging tests.

1. Deploy Nipto OIDC endpoints to a staging issuer and configure a Custom OAuth/OIDC provider on a staging Supabase project.
2. Verify discovery, JWKS, asymmetric ID-token validation, client audience, issuer, `sub`, expiry, nonce, and Supabase Auth session creation with email_optional enabled.
3. Verify PostgREST, RLS, Storage, Realtime, RPC and private-channel authorization with Supabase-issued access tokens created after Nipto OIDC sign-in.
4. Add Nipto credential records and link each Nipto identity to the existing Supabase Auth user UUID without changing the production auth flow.
5. Migrate signed-in existing users through an explicit password re-entry flow. Verify the old credential once, create a new Argon2id hash, and preserve the existing profile UUID. Never copy Supabase Auth password hashes.
6. Back up production data and storage metadata. Preserve profile IDs, messages, conversations, media ownership, notifications, call history, staff roles, and moderation records.
7. Preserve the profile-to-`auth.users` foreign key and every existing profile UUID because Supabase Auth remains the app-session broker. Link each Nipto credential identity to the existing Supabase user UUID; do not recreate profiles or rewrite social-data ownership.
8. Switch Android to Nipto OIDC only after migration, rollback, security, and device tests succeed. Keep the old project auth state available through a verified rollback window.
9. After the Nipto identity is linked and verified, remove the legacy email/phone identities and clear the legacy Supabase password hash while preserving the Supabase user UUID. Remove old email lookup/reset behavior only after all migration checks are complete.

## 7. Required implementation and release tests

- Registration with no email, duplicate Nipto ID, reserved ID, malformed ID, weak/oversized password.
- Login success, wrong password, unknown ID, disabled account, throttling, generic errors.
- Supabase access token accepted by PostgREST; RLS prevents cross-account reads/writes.
- Supabase session expiry/refresh, device logout, and global logout.
- Realtime topic authorization and Storage policies under native JWT.
- Optional recovery omitted at registration and linked later in Settings.
- Pending/accepted/rejected/revoked recovery contact behavior.
- Recovery request enumeration resistance, approval authorization, expiry, replay, concurrent redemption, rate limits, and password/session revocation.
- Existing-user migration preserves UUIDs, profile content, messages, conversations, media ownership, notifications, and call history.
- Android integration tests on at least two physical devices for sign-in, session refresh, recovery approval, and password reset.

## 8. Deployment gates and non-goals

- Preserve the profile-to-auth.users foreign key. Do not apply the Nipto credential schema to production before staging proof.
- Do not use synthetic `@nipto.invalid` email addresses, fake phone numbers, email OTP, or external social login providers.
- Do not expose OIDC signing keys, service-role credentials, refresh tokens, or password hashes to the client.
- Do not claim recovery is complete until the full one-time reset protocol is implemented and tested.
- Preserve the existing social product model, profile UUIDs, and feature data model.
- Use the existing Supabase project for data, storage and realtime. Configure only the Custom OAuth/OIDC provider configuration after staging verification.

## 9. Supabase platform evidence

Supabase's current Custom OAuth/OIDC provider documentation confirms that an external OIDC identity provider can be connected to Supabase Auth. For Nipto, configure identifier `custom:nipto`, use the Nipto issuer and client credentials, request only `openid profile`, and set `email_optional=true`. Supabase Auth validates Nipto's ID token and issues the app's normal Supabase session. Configure the provider in Authentication → Sign In / Providers → Custom OAuth Providers or through the Auth admin API. Manual identity linking must also be enabled for the existing-account migration flow.

References:
- Custom OAuth/OIDC providers and email_optional: https://supabase.com/docs/guides/auth/custom-oauth-providers
- Supabase Auth identity linking: https://supabase.com/docs/guides/auth/auth-identity-linking

This corrects the earlier assumption that custom OIDC was limited to self-hosted Supabase. Nipto can retain its hosted Supabase project if the custom OIDC integration is configured and the end-to-end tests pass. Supabase Auth itself remains enabled by the platform, but Nipto will not use its email or phone credential flows.


## 10. Deployment configuration and activation

The Nipto identity Edge Function uses these server-only environment variables:
- `NIPTO_OIDC_ISSUER`: exact HTTPS URL, without trailing slash, for `https://<project-ref>.supabase.co/functions/v1/nipto-identity`.
- `NIPTO_OIDC_CLIENT_ID` and `NIPTO_OIDC_CLIENT_SECRET`: credentials for the Supabase custom provider. Keep the secret server-side and configure the exact same client ID/secret in Supabase Auth provider settings.
- `SUPABASE_PUBLISHABLE_KEY` (or the supported anon-key fallback) for authenticated user-scoped RPC calls.
- `NIPTO_OIDC_KID`: stable key identifier, for example `nipto-es256-2026-11`.
- `NIPTO_OIDC_PRIVATE_JWK`: the complete active private ES256 JWK generated locally by `scripts/generate_nipto_oidc_keys.ts`. Never commit or paste it into chat. Configure it only in Supabase Edge Function Secrets.
- `NIPTO_OIDC_PUBLIC_KEYS`: a JSON array of public ES256 JWKs. Include the active public key and any previous public keys still needed to verify unexpired tokens.
- `SUPABASE_URL` and `SUPABASE_SERVICE_ROLE_KEY` are Supabase-provided Edge Function environment values and must remain server-side.

The key-generation script prints a private JWK and its public counterpart. Store the private JWK securely, set the Edge Function secrets, and verify the public JWKS endpoint contains only public key coordinates. The issuer supports overlapping verification keys: on rotation, set the new private JWK and active key ID, and publish both the old and new public JWKs in `NIPTO_OIDC_PUBLIC_KEYS`. Retain the old public key for at least 30 minutes after rotation so Supabase's cached JWKS and still-valid five-minute ID tokens continue to verify; verify the provider's JWKS cache behavior during staging before shortening this overlap. Emergency key compromise response may take up to the provider's JWKS refresh interval.

After deployment, configure Authentication → Sign In / Providers → Custom OAuth Providers with the exact `NIPTO_OIDC_ISSUER`. Supabase's issuer discovery must resolve the `jwks_uri`. Confirm the integration is active before using Supabase-issued session tokens with Data API, Storage, or Realtime.

The Edge Function is configured with `verify_jwt = false` because OIDC authorization/token endpoints and the Nipto ID availability check are public, while protected application routes validate the Supabase Auth access token by calling `nipto_native_current_user` with the caller's bearer token. Supabase verifies the session and `auth.uid()` supplies the authenticated user UUID. This does not disable authorization: every protected route must call `authenticatedUserId` before using a user-scoped RPC. Service-role RPCs must receive only that verified UUID, never a caller-supplied identity.

The app initializes the normal Supabase Flutter client and uses `signInWithOAuth(OAuthProvider('custom:nipto'))` for Nipto sign-in and registration. Supabase Auth validates the Nipto OIDC ID token, then stores and refreshes its own app session. Application identity is read from the Supabase session and Nipto profile claims. The branch supplies custom secure storage for the Supabase session and PKCE verifier. On first initialization it migrates an existing session from the SDK's default SharedPreferences key into secure storage before deleting the old copy, preserving existing signed-in users for the account-linking flow. Nipto passwords and OIDC private keys are never stored in the app.

