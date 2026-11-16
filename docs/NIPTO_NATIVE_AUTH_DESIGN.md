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

Keep the current hosted Supabase project. Build a Nipto-owned OpenID Connect (OIDC) identity provider as a Supabase Edge Function and register its issuer as a **Custom OIDC third-party auth integration** in the Supabase project.

This is Nipto's own identity service, not Google, Apple, Facebook, a phone provider, or another external identity provider. Supabase Auth remains enabled as a platform component but is not used to collect credentials, create Nipto accounts, or send email. The Nipto app authenticates directly with the Nipto OIDC service; Supabase Data API, Storage, and Realtime validate the Nipto-issued asymmetric JWT through the configured Custom OIDC integration.

Supabase's current Custom OIDC documentation explicitly supports any OIDC-compliant issuer for a Supabase project, requires asymmetric JWT signing with a `kid` header and a `role` claim, and configures trust through the Dashboard or Management API. See section 9.

### Nipto OIDC issuer

Implement these endpoints under a stable HTTPS issuer URL:
- `/.well-known/openid-configuration` — issuer metadata and endpoint URLs.
- `/jwks` — public signing keys with `kid`; never expose private key material.
- `/userinfo` — minimal Nipto profile claims after validating the access token.
- Nipto-specific `/register`, `/login`, `/refresh`, `/logout`, `/logout-all`, `/migrate`, password-change, device-session, and recovery endpoints protected by strict request validation and rate limits.

The mobile app uses native Nipto ID/password screens and receives Nipto-issued JWTs directly. This is a JWT issuer integration, not an OAuth browser-login flow; the Custom OIDC integration is used by Supabase to discover the issuer and validate its asymmetric signatures.

OIDC tokens must include:
- `iss`: exact configured Nipto issuer URL.
- `sub`: stable Nipto account UUID; equal to `public.profiles.id`.
- `aud`: registered Nipto Supabase project client identifier / accepted audience.
- `role`: `authenticated` for signed-in users.
- `iat`, short `exp`, unique `jti`, and required OIDC `nonce` where applicable.
- A `kid` JWT header identifying the asymmetric public key in JWKS.
- No `email`, `email_verified`, `phone_number`, or synthetic contact claims.

Use ES256 or RS256 with a reviewed WebCrypto implementation and a key-rotation process that retains old public keys until all issued tokens expire. Private signing keys belong only in Edge Function secrets. Never put them, service-role credentials, or password hashes in Flutter or source control.

### Supabase authorization

Configure the project's Authentication → Sign In / Providers → Third-Party Auth → Custom OIDC integration with the exact Nipto issuer URL. Verify the integration is active before issuing production tokens. Supabase's Data API, Storage, and Realtime must accept the token and expose the stable `sub` through `auth.uid()`.

Remove the `public.profiles.id → auth.users.id` foreign key only in a separately reviewed migration after staging proof. Preserve profile UUIDs and all dependent foreign keys. Supabase Auth user records are not required for Nipto identities in this architecture.

All existing RLS policies using `auth.uid()` remain the authorization boundary. Never use the service-role key in the Flutter app. Never proxy user operations through service-role endpoints as a shortcut around RLS.

### Session lifecycle

Nipto owns refresh sessions:
- Generate cryptographically random opaque refresh tokens on the server.
- Store only SHA-256 hashes of refresh tokens in a private schema.
- Rotate on every refresh; invalidate the previous token atomically.
- Detect reuse of a rotated token and revoke the affected session family.
- Support device-specific logout and global session revocation.
- Keep access tokens short-lived (target 10 minutes); set explicit absolute and idle session expiry.
- Store refresh tokens in Android secure storage; never store passwords.

### Supabase issuer isolation

The exact issuer is `https://advmjribduqzyuwktkod.supabase.co/functions/v1/nipto-identity`. The Supabase project must trust this HTTPS issuer through Third-Party Auth → Custom OIDC. The JWT must contain `sub` as the stable profile UUID, `role=authenticated`, and a `kid` header.

Because Supabase Auth remains enabled for platform compatibility and legacy-session migration, the database migration adds an issuer-checked `private.nipto_uid()` helper. Existing public SECURITY DEFINER functions that use `auth.uid()` are rewritten to use this helper, and restrictive issuer policies are added to RLS-enabled public tables, Storage objects and Realtime messages. This prevents a legacy Supabase Auth JWT from being treated as a Nipto session. Keep the issuer value in this document, the Edge Function secret, and the database helper identical.

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

The existing production project uses Supabase Auth identities. Do not delete or overwrite them until the Nipto OIDC issuer and Supabase Custom OIDC integration have passed end-to-end staging tests.

1. Deploy Nipto OIDC endpoints to a staging issuer and configure a Custom OIDC integration on a staging Supabase project.
2. Verify discovery, JWKS, asymmetric JWT validation, `role`, audience, issuer, `sub`, expiry, nonce, and key rotation.
3. Verify PostgREST, RLS, Storage, Realtime, RPC and private-channel authorization with Nipto-issued JWTs.
4. Add native Nipto credential and refresh-session records without changing the production auth flow.
5. Migrate signed-in existing users through an explicit password re-entry flow. Verify the old credential once, create a new Argon2id hash, and preserve the existing profile UUID. Never copy Supabase Auth password hashes.
6. Back up production data and storage metadata. Preserve profile IDs, messages, conversations, media ownership, notifications, call history, staff roles, and moderation records.
7. Remove the profile-to-`auth.users` foreign key only after all active accounts are represented in the native Nipto identity store and the staging cutover passes.
8. Switch Android to Nipto OIDC only after migration, rollback, security, and device tests succeed. Keep the old project auth state available through a verified rollback window.
9. Remove old email lookup/reset Edge Function behavior, email-based UI, and unused Supabase Auth identities only after all migration checks are complete.

## 7. Required implementation and release tests

- Registration with no email, duplicate Nipto ID, reserved ID, malformed ID, weak/oversized password.
- Login success, wrong password, unknown ID, disabled account, throttling, generic errors.
- Access JWT accepted by PostgREST; RLS prevents cross-account reads/writes.
- JWT expiry, refresh rotation, refresh replay detection, device logout, global logout.
- Realtime topic authorization and Storage policies under native JWT.
- Optional recovery omitted at registration and linked later in Settings.
- Pending/accepted/rejected/revoked recovery contact behavior.
- Recovery request enumeration resistance, approval authorization, expiry, replay, concurrent redemption, rate limits, and password/session revocation.
- Existing-user migration preserves UUIDs, profile content, messages, conversations, media ownership, notifications, and call history.
- Android integration tests on at least two physical devices for sign-in, session refresh, recovery approval, and password reset.

## 8. Deployment gates and non-goals

- Do not apply the profile foreign-key removal or native-auth schema to production before staging proof.
- Do not use synthetic `@nipto.invalid` email addresses, fake phone numbers, email OTP, or external social login providers.
- Do not expose OIDC signing keys, service-role credentials, refresh tokens, or password hashes to the client.
- Do not claim recovery is complete until the full one-time reset protocol is implemented and tested.
- Preserve the existing social product model, profile UUIDs, and feature data model.
- Use the existing Supabase project for data, storage and realtime. Configure only the Custom OIDC trust integration after staging verification.

## 9. Supabase platform evidence

Supabase's current Custom OIDC documentation confirms that any OIDC-compliant issuer can be configured as a third-party authentication provider for a hosted Supabase project. Requirements include HTTPS issuer discovery, asymmetric JWT signatures, a `kid` header, and a `role` claim. The integration is configured in the Dashboard under Authentication → Sign In / Providers → Third-Party Auth → Custom OIDC, or through the Management API.

References:
- Custom OIDC provider for hosted Supabase: https://supabase.com/docs/guides/auth/third-party/custom-oidc
- Third-party auth overview: https://supabase.com/docs/guides/auth/third-party/overview

This corrects the earlier assumption that custom OIDC was limited to self-hosted Supabase. Nipto can retain its hosted Supabase project if the custom OIDC integration is configured and the end-to-end tests pass. Supabase Auth itself remains enabled by the platform, but Nipto will not use its email or phone credential flows.


## 10. Deployment configuration and activation

The Nipto identity Edge Function uses these server-only environment variables:
- `NIPTO_OIDC_ISSUER`: exact HTTPS URL, without trailing slash, for `https://<project-ref>.supabase.co/functions/v1/nipto-identity`.
- `NIPTO_OIDC_KID`: stable key identifier, for example `nipto-es256-2026-11`.
- `NIPTO_OIDC_PRIVATE_JWK`: the complete active private ES256 JWK generated locally by `scripts/generate_nipto_oidc_keys.ts`. Never commit or paste it into chat. Configure it only in Supabase Edge Function Secrets.
- `NIPTO_OIDC_PUBLIC_KEYS`: a JSON array of public ES256 JWKs. Include the active public key and any previous public keys still needed to verify unexpired tokens.
- `SUPABASE_URL` and `SUPABASE_SERVICE_ROLE_KEY` are Supabase-provided Edge Function environment values and must remain server-side.

The key-generation script prints a private JWK and its public counterpart. Store the private JWK securely, set the Edge Function secrets, and verify the public JWKS endpoint contains only public key coordinates. The issuer supports overlapping verification keys: on rotation, set the new private JWK and active key ID, and publish both the old and new public JWKs in `NIPTO_OIDC_PUBLIC_KEYS`. Retain the old public key for at least 30 minutes after rotation so Supabase's cached JWKS and still-valid 10-minute access tokens continue to verify; then remove it. Emergency key compromise response may take up to the provider's JWKS refresh interval.

After deployment, configure Authentication → Sign In / Providers → Third-Party Auth → Custom OIDC with the exact `NIPTO_OIDC_ISSUER`. Supabase's issuer discovery must resolve the `jwks_uri`. Confirm the integration is active before using Nipto-issued tokens with Data API, Storage, or Realtime.

The Edge Function is configured with `verify_jwt = false` because login, registration, and recovery-start are public endpoints and authenticated routes verify Nipto's ES256 JWT in the function itself. This does not disable authorization: every protected route must call the shared token verifier, and all database RPCs remain service-role-only. Do not add a route that accepts a caller-supplied user UUID as identity.

The app initializes Supabase with the `accessToken` callback from `NiptoSessionManager`. In this configuration the Supabase Auth namespace is unavailable by design; application identity comes from the verified Nipto session manager. Refresh tokens are stored using Android secure storage, while access tokens remain in memory.

