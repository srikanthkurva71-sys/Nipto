# Nipto Security Model

## Identity and trust boundaries

1. Flutter is an untrusted client. All IDs, object paths, payloads, audience choices and ownership claims are validated by server/database policy.
2. Nipto owns the account credentials: Nipto ID + Nipto password. Nipto does not collect, require, synthesize or use email addresses or phone numbers for registration, sign-in or recovery.
3. The Nipto identity Edge Function is Nipto's OIDC issuer. It verifies Nipto credentials and signs short-lived ES256 OIDC ID tokens for the configured Supabase Custom OAuth/OIDC provider.
4. Supabase Auth is the app-session broker. It validates the Nipto OIDC response and issues normal Supabase access/refresh sessions. PostgREST, Storage, Realtime and authenticated RPCs use those Supabase-issued sessions—not Nipto OIDC tokens.
5. The OIDC `sub` is the stable Nipto credential identity UUID. Supabase maps that external identity to its own `auth.users.id`; `public.profiles.id` remains the same stable Supabase user UUID. Do not rewrite profile or social-data ownership.
6. PostgreSQL RLS is the authorization boundary for exposed application tables. `auth.uid()` resolves to the authenticated Supabase user UUID, not the Nipto OIDC `sub`.
7. Edge Functions hold server-side secrets and perform privileged identity operations. The Flutter client never receives a service-role key, database password, OIDC client secret or signing private key.
8. Storage buckets are private. Object access is governed by `storage.objects` policies and the corresponding profile, content or conversation authorization.

## Credential handling

- Registration requires a unique Nipto ID, display name, password and password confirmation. The optional recovery Nipto account must be explicitly accepted by the selected account.
- Nipto IDs are normalized to lowercase and validated as 3–24 characters using letters/numbers with optional single underscores between parts. Reserved names are rejected.
- Availability checks inspect both existing profiles and private Nipto credential identities. The server repeats the uniqueness check during registration; database unique constraints remain authoritative.
- Password suggestions are generated locally with the browser cryptographic random generator. Passwords are sent only to the Nipto identity Edge Function over TLS and are hashed using Argon2id. Passwords and hashes are never logged or returned.
- Private credential records live in the non-exposed `private` schema. App roles cannot read or write password hashes, OIDC transactions/codes, migration tickets, recovery challenges, reset grants or security events.
- Unknown Nipto IDs and incorrect passwords receive the same sign-in error. Identity, ID-availability, recovery and reset routes use keyed rate limiting.
- The OIDC issuer supports authorization code flow with PKCE S256, state, nonce, CSRF binding and short-lived authorization codes. It accepts only `openid` and optional `profile` scopes; it does not return email or phone claims.
- OIDC ID tokens are ES256-signed, have a short expiry, use a `kid`, and are validated by Supabase Auth through the configured issuer/JWKS. Private signing keys and the OIDC client secret remain in Edge Function secrets.
- Supabase Auth manages application access/refresh token issuance, rotation and revocation. Nipto does not issue a separate app refresh-token format. The app stores Supabase session and PKCE state using encrypted Android storage.
- Existing persisted Supabase sessions are copied from the SDK's prior SharedPreferences key to encrypted storage before the legacy copy is removed.
- Existing Supabase Auth users migrate only from an already authenticated session. A short-lived migration ticket binds the account-link flow to the existing Supabase UUID. After the Nipto identity is linked and verified, the server clears legacy email/phone identity records and the old Supabase password credential while preserving the `auth.users` row, profile UUID and all social data.
- The Flutter client uses only the Supabase publishable key. Never embed `service_role`, secret, database password or JWT signing keys in the app.

## Recovery Nipto account

- A recovery Nipto account is optional at registration and can be added later in Settings.
- The selected account receives an in-app request and must explicitly accept the relationship.
- Forgot password creates a short-lived in-app request to the accepted recovery account. The public response is non-enumerating.
- The recovery account must be active, unblocked and still linked when it approves. Approval and reset-grant redemption recheck account state and block relationships.
- Approval authorizes one short-lived, single-use reset grant. The recovery account never sees or chooses the new password.
- Reset-grant consumption, password-hash update and Supabase session revocation occur in one database transaction. The grant cannot be replayed and expires after 10 minutes; the recovery challenge expires after 15 minutes.
- Challenge secrets and reset grants are high-entropy one-time values. Only their hashes are stored in the database.
- Password change requires the current Nipto password and invalidates existing Supabase sessions.
- Recovery requests, approvals, rejections, password changes and resets are recorded as security events. Recovery is not available without an accepted recovery account.

## Authorization

- RLS is enabled on application tables; private credential tables have RLS enabled and no client-role access.
- Users can edit only allowed profile columns; they cannot change their UUID, Nipto ID or moderation/account status.
- Follow state is assigned by a database trigger. Private profiles create pending follow requests.
- Block relationships are enforced in search, status visibility, recovery selection and messaging.
- Direct message rows require accepted conversation membership and the authenticated sender ID.
- Group invitees cannot read or send messages until they accept.
- Public feed visibility also respects private-account state.
- User content is pending moderation by default; client roles cannot approve content.
- Social-data foreign keys reference stable `public.profiles.id` values. Those profile UUIDs remain equal to the corresponding `auth.users.id`; do not migrate them to Nipto OIDC subject UUIDs.
- Authenticated SECURITY DEFINER RPCs validate the caller's user ID from the Supabase bearer token. Service-role RPCs receive only IDs verified by the Edge Function, never caller-supplied ownership claims.

## Column-level write permissions

Client roles receive column-scoped write grants in addition to RLS:
- Profile edits are limited to display name, bio, avatar path and privacy choice; Nipto ID and account state are not client-editable.
- Follow requests can create only the follower/following pair; the database trigger controls pending versus accepted state.
- Post and Short creators can edit captions and visibility, but cannot change ownership, media object paths or moderation state.
- Statuses are immutable after creation; owners can delete them.
- Message updates cannot change sender, conversation, message type or media path.
- Feedback clients can submit and read their own records but cannot change workflow status or delete submissions.
- Report clients can submit and read their own reports but cannot alter report ownership or contents later.

These grants prevent a valid row owner from changing server-controlled metadata merely because an RLS policy permits access to that row.

## Media

Private buckets: avatars, chat-media, statuses, posts and shorts. Storage object paths are documented in the core migration. Access checks join object metadata to the relevant profile/content/conversation authorization. Do not make message media public to solve signed-URL problems.

## Outstanding release controls

- Create or designate a disposable staging Supabase environment. The connected Supabase account currently exposes only the production Nipto project and no development branches; do not apply the new auth migrations to production as a substitute for staging.
- Configure the Nipto Edge Function secrets: exact issuer URL, OIDC client ID/secret, ES256 key ID, private JWK and public JWKS set. Generate key material locally; never commit private keys.
- Configure Supabase Authentication → Sign In / Providers → Custom OAuth/OIDC with identifier `custom:nipto`, exact issuer/JWKS, `email_optional=true`, scopes `openid profile`, and manual identity linking enabled.
- Validate the full new-user trigger, OIDC registration/login, legacy-account migration, account linking, RLS, Storage, Realtime and RPC behavior in staging.
- Validate Argon2id parameters under Edge Function CPU/memory limits and run load tests for concurrent sign-ins and recovery.
- Complete E2E tests for cross-user RLS isolation, private accounts, blocks, group invites, message membership, recovery approval/reset, session refresh/revocation and storage access.
- Provision production TURN infrastructure and verify independent mobile networks; add push delivery and app-wide incoming-call handling.
- Add media scanning/transcoding, thumbnails, resilient upload processing and human moderation operations.
- Add account deletion, data export and retention workflows.
- Review every authenticated SECURITY DEFINER RPC against its caller authorization checks; function-by-function review is required before production rollout.
- Complete physical two-device WebRTC tests, network-transition tests, accessibility/performance checks and independent security review before production launch.
- Configure release signing, Play Console compliance and a production AAB only after the above gates pass.

## Security advisory interpretation

Supabase's advisor may flag intentional SECURITY DEFINER RPCs such as profile search and direct-conversation creation. Their inputs must be validated and their returned capability deliberately limited. Internal policy and trigger helpers belong in a non-exposed private schema. Every new definer function must use a fixed `search_path`, minimal output, explicit grants and tests.
