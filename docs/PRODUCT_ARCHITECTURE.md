# Nipto Social — Product and Technical Architecture

**Status:** v1 architecture baseline  
**Target:** Android phones  
**Product:** Social communication platform  
**Out of scope:** ride-hailing, deliveries, payments and web client

## 1. Product definition

Nipto is one social identity for keeping up with people, talking privately and sharing short videos. The first screen after sign-in is the Chats experience. The main navigation has four destinations, available through swipe gestures and the bottom bar:

- **Home:** a paginated feed of approved posts, likes and comments from eligible public and followed accounts.
- **Chats:** conversations, user search/discovery, following, 24-hour statuses and notifications.
- **Shorts:** full-screen vertical videos.
- **You:** personal profile, posts and account controls.

The app should feel familiar without copying another product's branding or visual assets. Prioritize clear hierarchy, low-friction actions, readable type, accessible touch targets and fast transitions.

## 2. Account and identity

### Public identity
- Unique `@nipto_id`, lowercase letters/numbers with optional single underscores between parts, 3–24 characters.
- Display name, biography, avatar and privacy state.
- Email and phone are not Nipto account identifiers and are not collected for Nipto authentication.
- A recovery Nipto account is optional and must be explicitly accepted by the selected recovery account.

### Registration and sign-in
1. The user chooses a Nipto ID and display name. Availability is checked against both existing profiles and private Nipto credential identities.
2. The registration screen offers alternative IDs when a name is unavailable and can generate a strong password locally on the device. The user confirms the password before submission.
3. The Nipto identity Edge Function validates the request, applies rate limits, hashes the password with Argon2id, and stores the private Nipto identity record.
4. The app redirects through Supabase Auth's configured Custom OIDC provider (`custom:nipto`). The Nipto issuer serves OIDC discovery/JWKS and authorization-code + PKCE endpoints.
5. Supabase Auth validates the Nipto issuer and creates its normal Supabase session. The existing Supabase user UUID remains the canonical internal key for profiles, RLS, Storage, Realtime and RPC authorization.
6. Android stores Supabase session and PKCE state in encrypted storage. Existing persisted sessions are migrated from the prior SDK storage key before the old copy is removed.

Nipto owns the user-facing identity and password verification. Supabase Auth is the session broker, not the source of Nipto credentials. OIDC scopes are restricted to `openid` and optional `profile`; email and phone scopes are not accepted. No synthetic email is used.

### Existing-account migration
- Existing users authenticate through the currently deployed legacy path only to begin an explicit migration.
- A short-lived migration ticket binds the existing authenticated Supabase UUID to the Nipto identity-link flow.
- The Nipto identity is linked to that same UUID; existing profile and social records are preserved.
- Only after the custom Nipto identity is confirmed on the Supabase user are legacy email/phone identities and the old password credential cleared.
- Migration requires a tested backup and rollback plan in staging before production rollout.

### Password and account recovery
- Password change requires the current Nipto password.
- The user may add one optional recovery Nipto account. The selected account must accept the relationship in-app.
- Forgot-password starts an opaque, rate-limited request. The accepted recovery account receives an in-app notification and must explicitly approve it.
- Approval creates a short-lived, single-use reset grant. Reset updates the Nipto password hash and revokes active Supabase sessions.
- Recovery does not use email, SMS, or an email reset link. Requests are non-enumerating and approval is tied to the accepted recovery relationship.

### Sessions and security
- Supabase access/refresh tokens remain standard Supabase Auth sessions so existing `auth.uid()` checks and RLS policies continue to work.
- Session management lists and revokes the user's sessions.
- Password reset revokes all sessions; password change also invalidates existing sessions.
- Password hashes use Argon2id; OIDC ID tokens are ES256-signed and published through JWKS.
- Rate limits, short-lived authorization codes, PKCE S256, CSRF binding, one-time recovery grants and service-role-only RPCs protect identity operations.
- Signing keys and OIDC client secrets are provisioned as backend secrets and never committed or embedded in the APK.

## 3. Navigation and screen architecture

### Chats
- Inbox with recent conversations, group invitations and unread state.
- Search by Nipto ID prefix.
- User discovery and follow/follow-request actions.
- Status tray for followed accounts, sorted by recency.
- Direct and group conversations.
- Message types: text first; image, video, audio and files through private storage after validation.
- Message delivery/read receipts, replies, edit window and delete-for-me/delete-for-everyone policy to be finalized.

### Shorts
- Vertical PageView with one active video controller at a time.
- Lazy initialization, pause off-screen, dispose unused controllers.
- Only approved content is distributed to other users.
- Likes, comments, share intents and creator profile links.
- Upload pipeline must validate type, duration, dimensions and file size before moderation and publication.

### You
- Avatar, display name, Nipto ID and bio.
- Followers/following and follow requests.
- Posts and published Shorts.
- Privacy, notification, blocked-account, session and account-recovery settings.
- Account deletion and data export request entry points.

## 4. Backend services

- **Supabase Auth:** credential verification, email confirmation, sessions and password reset.
- **PostgreSQL:** profiles, follows, blocks, conversations, messages, statuses, posts, Shorts, likes, comments, notifications and reports.
- **RLS:** per-user and per-conversation authorization; the client cannot bypass it.
- **Realtime:** message, membership and notification changes.
- **Storage:** private buckets for avatars, chat media, statuses, posts and Shorts.
- **Edge Functions:** Nipto ID login, moderation orchestration, notification dispatch and media-processing callbacks as those modules are implemented.

## 5. Database entities

| Entity | Purpose |
|---|---|
| profiles | Public Nipto identity and profile preferences |
| follows | Accepted follows and pending private-account requests |
| blocked_users | One-way block relationships, enforced symmetrically |
| close_friends | Status audience allow-list |
| conversations | Direct or group conversation container |
| conversation_members | Membership, invitation state, role and read cursor |
| messages | Text/media message metadata |
| message_receipts | Delivery/read state per recipient |
| statuses, status_views | 24-hour updates and views |
| posts, post_likes, post_comments | Profile posts and interactions |
| shorts, short_likes, short_comments | Short-video content and interactions |
| notifications | In-app notification inbox |
| device_tokens | Android push token ownership |
| user_reports | Abuse/content reports and safety escalations |
| user_feedback | Private product feedback, feature requests, ratings and support requests |

## 6. API and data contracts

- Auth user UUID is the canonical internal user key.
- Nipto ID is unique, normalized lowercase and user-changeable only through a future server-controlled rename flow.
- Storage object paths begin with the owning user UUID, or conversation UUID for chat uploads.
- Client-supplied owner/sender IDs are always checked against auth.uid().
- User-generated posts and Shorts start with moderation_state = pending. The client cannot update moderation state.
- A private-account follow is always a pending follow request. A database trigger chooses the state; the client cannot force acceptance.
- Group invitations are invited; messages require accepted membership.

## 7. Performance requirements

- Paginate inbox, search, status lists, comments and feeds.
- Use indexed cursor/order columns and avoid unbounded selects.
- Debounce Nipto ID search.
- Keep one active video decoder during vertical scrolling.
- Generate video thumbnails and adaptive renditions server-side before scale.
- Use image resizing and short-lived signed URLs for private media.
- Do not download media until it is close to the viewport.
- Use optimistic UI only where rollback and duplicate prevention are implemented.

## 8. v1 non-functional requirements

- No secret keys in APK or repository.
- No direct public bucket for private conversations.
- All client-facing tables have RLS enabled and least-privilege grants.
- User-facing forms have validation and clear error states.
- App handles offline/slow network, expired sessions and media failures.
- Accessibility: semantic labels, contrast, scalable text and touch targets.
- Safe defaults for unsolicited messages, discoverability and private accounts.
- Reporting, blocking, feedback intake and moderation workflows must exist before open public launch.
- Feedback is separate from abuse reports. Users can submit a category, optional 1–5 rating, subject and message, then view their own submission status. Only trusted moderation tooling may change feedback status.
