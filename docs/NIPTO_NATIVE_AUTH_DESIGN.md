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

### Identity records

Create a private `private.nipto_accounts` table with:
- `id uuid primary key` — the stable Nipto identity UUID; equal to `public.profiles.id`.
- `nipto_id_normalized text unique` — canonical login identifier; public handle remains in `profiles`.
- `password_hash text` — encoded Argon2id hash only; never plaintext or reversible encryption.
- `password_changed_at timestamptz`, `created_at`, `updated_at`.
- `status` with explicit active / locked / disabled states.
- Optional credential-version metadata for safe hash upgrades.

Keep account and credential records in a non-exposed schema. No client role can select or update password hashes. Password verification and mutation happen only in trusted Edge Functions using service credentials.

### Session tokens and Supabase authorization

Nipto owns the login and refresh lifecycle. Use short-lived signed access JWTs for Supabase PostgREST, Storage, and Realtime, with:
- `sub`: Nipto account UUID (same UUID as `profiles.id`).
- `role`: `authenticated`.
- `aud`: `authenticated`.
- `iss`: Nipto's documented issuer.
- `iat`, short `exp`, and unique `jti`.
- No email or phone claims.

Use a dedicated asymmetric signing key pair. The public verification key must be configured in the Supabase project's JWT signing-key configuration; the private key belongs only in Edge Function secrets. Never put the private key or service-role key in the Flutter app or repository. Confirm the project accepts these custom tokens for REST, Storage, and Realtime before migrating any production identity.

Refresh tokens are cryptographically random opaque values. Store only a hash of each token in a private session table. Rotate on every refresh, revoke the previous token atomically, detect token reuse, and support per-device and global revocation. Access tokens should be short-lived (target 10 minutes); session lifetime and idle expiry must be explicit.

### Authorization compatibility

All existing RLS policies that use `auth.uid()` must continue to resolve to the Nipto UUID from the verified JWT `sub`. Realtime channel authorization and Storage policies must be tested with a custom Nipto JWT. Never bypass RLS by embedding the service-role key in the app.

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

Do not delete or overwrite existing Supabase Auth identities until a verified migration path exists.

1. Add native account/session tables and Edge Functions in parallel, with no change to production login yet.
2. Configure and validate the dedicated JWT public key against a non-production Supabase environment. Verify REST, RLS, Storage, Realtime, and RPC behavior.
3. Add a migration path for existing signed-in users: while they still have a valid existing session, require an explicit password re-entry, verify it against the existing credential once, create the Argon2id hash, and bind the native account to the same UUID. Do not copy Supabase Auth password hashes.
4. Provide a clearly communicated fallback for users who cannot complete in-session migration. Do not silently fabricate email addresses or claim recovery is available.
5. Backfill private native account rows for existing profiles only when credential migration can be completed safely. Preserve profile UUIDs and all social data.
6. Switch new registration and login to native Nipto Auth only after custom JWT integration passes end-to-end tests.
7. Remove old email lookup/reset Edge Function behavior, email-based UI, and Supabase Auth dependencies only after migration coverage and rollback strategy are verified.
8. Remove the `profiles.id → auth.users.id` foreign key only after all active identities have native account records and no feature still depends on Supabase Auth user management.
9. Keep a rollback window and backups. Never drop `auth.users` or destroy existing sessions/data as part of an early migration.

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

- Do not deploy a partial native-auth schema or switch the app while the custom JWT signing key is not configured and verified.
- Do not use synthetic `@nipto.invalid` email addresses, fake phone numbers, email OTP, or external login providers as a workaround.
- Do not expose service-role credentials or password hashes to the client.
- Do not claim recovery is complete until the full one-time reset protocol is implemented and tested.
- This decision does not require changing the existing social product model, profile UUIDs, or feature data model.


## 9. Supabase-hosted platform feasibility gate (must be resolved before implementation)

The target Supabase project is a hosted Supabase Cloud project, not a self-hosted stack. Supabase's current third-party-auth documentation states that hosted first-class integrations cover a defined set of providers (Clerk, Firebase Auth, Auth0, AWS Cognito, WorkOS), require asymmetric OIDC JWTs, and do not allow Supabase Auth to be disabled. The custom OAuth/OIDC provider administration guide is explicitly for self-hosted Supabase Auth.

Consequences:
- Do not assume that creating a Nipto JWT signing key and publishing a JWKS endpoint is sufficient to make the hosted project trust an arbitrary Nipto issuer.
- Do not deploy this migration or mint tokens until the exact hosted-project trust configuration is confirmed with a working proof of concept.
- Do not claim the custom Nipto password database alone can authorize existing PostgREST, Storage, and Realtime calls. Existing RLS relies on Supabase-verified JWT claims.
- A private Nipto OIDC issuer may be a viable design only if the hosted project can be configured to trust it without an email claim and the proof of concept verifies PostgREST, Storage, Realtime, RPC, and RLS. If that is not supported, the compliant alternatives are (a) self-host the relevant Supabase Auth stack with a Nipto-owned OIDC provider, or (b) move all user-scoped data/media/realtime access behind a Nipto-owned backend/API and stop using direct Supabase client access. Option (b) is a substantial architecture migration.
- The user requirement forbids email, phone, external social identity providers, and synthetic addresses. Do not quietly substitute one of them.

The native-auth schema in this branch is a staged design artifact. It is not production-ready and must not be applied to the hosted production database until this platform gate is passed.
