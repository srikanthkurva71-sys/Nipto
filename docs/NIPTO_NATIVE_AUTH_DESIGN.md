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

### Recommended deployment architecture

Use a Nipto-owned OpenID Connect (OIDC) identity provider that authenticates Nipto ID + password, paired with a self-hosted Supabase stack (Auth, Postgres, PostgREST, Realtime, and Storage). Configure self-hosted Supabase Auth with a private custom OIDC provider identifier such as `custom:nipto`.

This keeps the user's only credential as Nipto ID + Nipto password. The OIDC provider is operated by Nipto; it is not Google, Apple, Facebook, phone OTP, or another external identity provider. Supabase Auth acts only as the application session broker. It must not collect an email address or phone number.

The Nipto OIDC provider must implement:
- OIDC discovery at `/.well-known/openid-configuration`.
- Authorization Code flow with PKCE (S256), strict redirect URI allow-list, state and nonce validation.
- Token endpoint with short-lived, asymmetrically signed ID tokens and one-time authorization codes.
- JWKS endpoint with key IDs and a documented signing-key rotation process.
- UserInfo claims limited to `sub`, `preferred_username`, `name`, and any required non-sensitive Nipto profile claims. Do not emit `email`, `email_verified`, `phone_number`, or synthetic contact values.
- A private OIDC client registered only with self-hosted Supabase Auth. Its client secret stays in server configuration, never in Flutter.
- Login and recovery endpoints backed by Nipto's Argon2id credential store and the recovery protocol in section 5.

Configure the self-hosted Supabase Auth custom OIDC provider with email optional and verify that the resulting `auth.users` row has no email address. Supabase Auth still creates the Supabase session and stable user UUID used by existing `auth.uid()` policies. Profile provisioning must map the Nipto OIDC claims to the same Nipto ID and display name, with uniqueness enforced by Postgres.

### Credential storage

The Nipto OIDC service stores:
- A stable Nipto subject UUID.
- Canonical unique Nipto ID.
- Argon2id encoded password hash.
- Credential version and password-change timestamps.
- Account state and security audit metadata.

Credential hashes are kept in a private schema, never selected by app roles, never returned through UserInfo, and verified only by the Nipto OIDC service. The OIDC service must not store email or phone credentials.

### Supabase session and authorization

Supabase Auth issues the session JWT after the Nipto OIDC sign-in succeeds. The Nipto Android app uses the normal Supabase session for PostgREST, Storage, Realtime, and RLS. The JWT `sub` must map to the stable `public.profiles.id` UUID. All existing policies using `auth.uid()` continue to be the authorization boundary.

Do not build a parallel custom refresh-token system for the app unless a later measured requirement justifies it. Let the self-hosted Supabase Auth session broker manage app access/refresh tokens; keep the Nipto OIDC provider's authorization codes and ID tokens short-lived and single-use.

### Hosted-project constraint

The current project is Supabase Cloud. Its documented first-class third-party authentication integrations are a limited set of providers; arbitrary custom OIDC provider administration is documented for self-hosted Supabase Auth. The current hosted project therefore cannot be assumed to support `custom:nipto`.

To preserve the current direct Supabase client architecture and RLS, the compliant deployment path is to self-host the Supabase stack and Nipto OIDC provider together. Keeping the hosted Supabase Cloud project would require a much larger redesign in which every user-scoped database, storage, and realtime operation is routed through a Nipto-owned backend. Do not mix a Nipto-issued JWT with the hosted project and assume it works.

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

The existing production project is hosted Supabase Cloud and currently has Supabase Auth identities. Do not delete, overwrite, or migrate those identities until the self-hosted target has passed an end-to-end proof of concept.

1. Build the Nipto OIDC provider and self-hosted Supabase environment in parallel with the current hosted production project.
2. Verify custom OIDC sign-in, no-email user creation, stable profile UUID mapping, RLS, PostgREST, Storage, Realtime, and Edge Functions on the self-hosted environment.
3. Export a protected backup of the production database and storage metadata. Transfer files using a verified migration process; preserve profile UUIDs and all foreign-key relationships.
4. Existing users must establish a Nipto password through a secure, verified migration flow. Do not copy Supabase Auth password hashes or assume they can be converted.
5. Map each existing account to the same stable Nipto subject and profile UUID wherever possible. Validate message, conversation, media, notification, call, staff, and moderation ownership after import.
6. Keep the current hosted project read-only or available for rollback until the new Android build has passed staged user acceptance and data-integrity checks.
7. Switch Android configuration to the self-hosted Supabase endpoint only after migration, backup restoration, and security tests succeed.
8. Retire hosted Supabase only after a verified rollback window and reconciliation of all user data. Never destroy production data during an early authentication experiment.

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

- Do not apply an experimental native-auth schema to the current production project.
- Do not use synthetic `@nipto.invalid` email addresses, fake phone numbers, email OTP, or external social login providers.
- Do not expose OIDC signing keys, provider client secrets, service-role credentials, or password hashes to the client.
- Do not claim recovery is complete until the full one-time reset protocol is implemented and tested.
- Preserve the existing social product model, profile UUIDs, and feature data model.
- Self-hosting requires an explicitly provisioned production server, domain, TLS, backups, monitoring, and a disaster-recovery plan. Do not deploy to a paid host or create billable infrastructure without the owner's explicit cost approval.

## 9. Supabase platform evidence

Supabase's current documentation states that hosted third-party authentication supports a defined set of integrations and requires asymmetric OIDC JWTs. Supabase Auth cannot be disabled in the hosted platform. The custom OAuth/OIDC provider administration guide is specifically for self-hosted Supabase Auth.

References:
- Third-party auth overview: https://supabase.com/docs/guides/auth/third-party/overview
- Custom OAuth/OIDC providers (self-hosted): https://supabase.com/docs/guides/self-hosting/self-hosted-custom-oauth-providers

This evidence is why the current hosted project cannot be assumed to trust a private Nipto OIDC issuer. The native-auth implementation is blocked on creating and testing the self-hosted target stack. The current hosted production project remains untouched.
