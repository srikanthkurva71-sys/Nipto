# Nipto Social — Product and Technical Architecture

**Status:** v1 architecture baseline  
**Target:** Android phones  
**Product:** Social communication platform  
**Out of scope:** ride-hailing, deliveries, payments and web client

## 1. Product definition

Nipto is one social identity for keeping up with people, talking privately and sharing short videos. The first screen after sign-in is the Chats experience. The main navigation has exactly three destinations:

- **Chats:** conversations, user search/discovery, following and statuses.
- **Shorts:** full-screen vertical videos.
- **You:** personal profile and account controls.

The app should feel familiar without copying another product's branding or visual assets. Prioritize clear hierarchy, low-friction actions, readable type, accessible touch targets and fast transitions.

## 2. Account and identity

### Public identity
- Unique @nipto_id, lowercase letters, digits and underscore, 3–24 characters.
- Display name, biography, avatar and privacy state.
- Email address and password are never stored in public.profiles.

### Registration
1. User chooses a Nipto ID, display name, recovery email and password.
2. Flutter calls Supabase Auth signUp using the recovery email and password and sends nipto_id/display_name as user metadata.
3. A database trigger creates the profile in the same Auth transaction. A unique constraint reserves the Nipto ID.
4. Supabase email verification completes before password sign-in is enabled.
5. The user signs in with Nipto ID and password.

### Nipto ID sign-in
1. Flutter invokes nipto-login with Nipto ID and password over TLS.
2. The Edge Function validates input and uses a digest-keyed database rate limiter.
3. The server-only resolve_nipto_login function finds the private Auth email. It is executable only by service_role.
4. The Edge Function sends the email/password pair to Supabase Auth's password-token endpoint.
5. The Edge Function returns the Supabase session tokens. It never returns the recovery email.
6. Flutter installs the refresh token using Supabase Auth session handling.

Supabase Auth remains the credential authority. Nipto owns the user-facing identifier and sign-in experience; it does not invent or store its own password hashing scheme.

### Recovery
Password recovery requires the verified recovery email associated with the account. A Nipto ID alone is not proof of account ownership. Configure the email template and an Android deep link before enabling the recovery UI for release.

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
| user_reports | Abuse/content reports |

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
- Reporting, blocking and moderation workflows must exist before open public launch.
