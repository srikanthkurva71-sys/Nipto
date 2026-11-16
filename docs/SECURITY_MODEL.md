# Nipto Security Model

## Identity and trust boundaries

1. Flutter is an untrusted client. All IDs, paths, payloads and visibility choices require server/database validation.
2. Nipto owns the account identity: Nipto ID + Nipto password. No email address, phone number, or external identity provider is used for registration, sign-in, or recovery.
3. The Nipto identity Edge Function verifies credentials and issues short-lived asymmetric ES256 JWTs. Supabase's Custom OIDC third-party integration verifies those tokens for Data API, Storage, Realtime and Functions.
4. PostgreSQL RLS remains the authorization boundary for exposed tables. `auth.uid()` resolves to the stable Nipto profile UUID from the verified JWT `sub`.
5. Edge Functions hold server-side secrets and perform privileged operations. The Flutter client never receives a service-role key or OIDC private key.
6. Storage buckets are private. Object access is governed by storage.objects policies.

## Credential handling

- Registration requires a unique Nipto ID and a password. A recovery Nipto account is optional and can be linked later in Settings.
- Passwords are sent only to the Nipto identity Edge Function over TLS and are hashed using Argon2id. Passwords and hashes are never logged or returned.
- Private credential records live in the non-exposed `private` schema. App roles cannot read or write credential hashes, refresh-token hashes, recovery challenges, reset grants or security events.
- Nipto ID resolution is server-side. The Edge Function returns the same authentication error for unknown IDs and incorrect passwords and applies a keyed 15-minute attempt limit.
- Refresh tokens are cryptographically random opaque values. Only SHA-256 hashes are stored. Tokens rotate on use; reuse of a rotated token revokes the affected account's active sessions.
- Access JWTs are short-lived (10 minutes), signed with ES256, carry a `kid`, and contain only the claims needed for Supabase authorization. No `email`, `email_verified`, `phone_number`, or synthetic contact claims are issued.
- The Supabase Custom OIDC integration must trust the exact Nipto issuer and JWKS URL. The app uses the Supabase `accessToken` callback; the Supabase Auth namespace is intentionally not used for application identity.
- Existing Supabase Auth accounts are migrated only from an existing signed-in session. The migration verifies that session through an ID-only RPC that returns the caller UUID and never reads or returns email or user metadata, creates the native Nipto credential under the same profile UUID, moves application foreign keys to `public.profiles`, and then deletes the legacy Auth identity. The legacy Auth record is not deleted until the native credential is committed.
- The Flutter client uses only the Supabase publishable key. Never embed service_role, secret, database password or JWT signing keys in the app.

## Recovery Nipto account

- A recovery Nipto account is optional at registration and can be added later in Settings.
- The selected account must explicitly accept the relationship.
- Forgot password creates a short-lived in-app request to the accepted recovery account.
- The recovery account must be active, unblocked, and still linked when it approves.
- Approval authorizes one short-lived, single-use reset grant. The recovery account never sees or chooses the new password.
- Password reset atomically consumes the grant, updates the Argon2id hash, increments the credential version, and revokes all refresh sessions.
- Unknown Nipto IDs receive a generic acknowledgement. Challenge secrets and reset grants are high-entropy, one-time values; only hashes are stored.
- Requests expire after 15 minutes; reset grants expire after 10 minutes. Approval, reset, replay, and rate-limit cases require dedicated tests.

## Authorization

- RLS is enabled on all application tables.
- Users can edit only allowed profile columns; they cannot change their UUID, Nipto ID or moderation/account status.
- Follow state is assigned by a database trigger. Private profiles create pending follow requests.
- Block relationships are enforced in search, status visibility, recovery selection and messaging.
- Direct message rows require accepted conversation membership and the authenticated sender ID.
- Group invitees cannot read or send messages until they accept.
- Public feed visibility also respects private-account state.
- User content is pending moderation by default; client roles cannot approve content.
- All ownership and moderation foreign keys reference stable `public.profiles.id` values, not `auth.users.id`.

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

- Configure Nipto Edge Function secrets: exact issuer URL, ES256 key ID, and private JWK. Generate key material locally; never commit private keys.
- Configure Supabase Authentication → Third-Party Auth → Custom OIDC with the Nipto issuer. Verify JWKS discovery and signed JWT acceptance before production cutover.
- Validate Argon2id parameters under Edge Function CPU/memory limits and run load tests for concurrent sign-ins.
- Complete legacy-session migration tests, including users with staff roles, moderation history, reports and feedback references. Confirm deleting a legacy Auth user does not delete profile or social data.
- Add push provider credentials as Edge Function secrets only.
- Add a media scanning/transcoding pipeline and human moderation tools.
- Add account deletion that removes Nipto credentials, sessions, profile data and Storage objects according to a documented retention policy.
- Complete E2E tests for cross-user RLS isolation, private accounts, blocks, group invites, message membership, recovery approval/reset, session rotation, and storage access.
- Review every authenticated SECURITY DEFINER RPC against its caller authorization checks; Supabase's advisor reports intentional and potentially sensitive functions that require function-by-function review.
- Complete physical two-device WebRTC tests, production TURN integration, incoming-call notification tests, and independent security review before production launch.

## Security advisory interpretation

Supabase's advisor may flag intentional SECURITY DEFINER RPCs such as profile search and direct-conversation creation. Their inputs must be validated and their returned capability deliberately limited. Internal policy and trigger helpers belong in a non-exposed private schema. Every new definer function must use a fixed `search_path`, minimal output, explicit grants and tests.
