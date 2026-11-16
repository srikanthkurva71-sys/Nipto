# Nipto Security Model

## Trust boundaries

1. Flutter is an untrusted client. All IDs, paths, payloads and visibility choices require server/database validation.
2. Supabase Auth verifies credentials and issues user sessions.
3. PostgreSQL RLS is the authorization boundary for exposed tables.
4. Edge Functions hold server-side secrets and perform privileged operations.
5. Storage buckets are private. Object access is governed by storage.objects policies.

## Credential handling

- Passwords are sent only to Supabase Auth over TLS.
- Public profiles contain no recovery email, phone number or password material.
- Nipto ID resolution is server-side. resolve_nipto_login is executable only by service_role.
- nipto-login returns session tokens only after Supabase Auth accepts the password.
- The Edge Function applies a digest-keyed 15-minute attempt limit. It returns the same authentication error for unknown IDs and wrong passwords.
- The Flutter client uses only the Supabase publishable key. Never embed service_role, secret, database password or JWT signing keys in the app.

## Authorization

- RLS is enabled on all application tables.
- Users can edit only allowed profile columns; they cannot change their UUID, Nipto ID or moderation/account status.
- Follow state is assigned by a database trigger. Private profiles create pending follow requests.
- Block relationships are enforced in search, status visibility and messaging.
- Direct message rows require accepted conversation membership and the authenticated sender ID.
- Group invitees cannot read or send messages until they accept.
- Public feed visibility also respects private-account state.
- User content is pending moderation by default; client roles cannot approve content.

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

Private buckets: avatars, chat-media, statuses, posts and shorts.
Storage object paths are documented in the core migration. Access checks join object metadata to the relevant profile/content/conversation authorization. Do not make message media public to solve signed-URL problems.

## Outstanding release controls

- Configure verified recovery email templates and Android redirect/deep-link allow-list.
- Review Auth password policy, email confirmation, captcha/abuse controls and session lifetime in Supabase Dashboard.
- Add push provider credentials as Edge Function secrets only.
- Add a media scanning/transcoding pipeline and human moderation tools.
- Add account deletion that removes Auth identity, database data and Storage objects according to a documented retention policy.
- Complete E2E tests for cross-user RLS isolation, private accounts, blocks, group invites, message membership and storage access.
- Complete independent security review before production launch.

## Security advisory interpretation

Supabase's advisor may flag intentional authenticated SECURITY DEFINER RPCs such as profile search and direct-conversation creation. Their inputs are validated and their returned capability is deliberately limited. Internal policy and trigger helpers are in a non-exposed private schema. Any new definer function must use a fixed search_path, minimal output, explicit grants and tests.
