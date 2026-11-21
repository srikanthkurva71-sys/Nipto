# Nipto Production Architecture v1.0

**Status:** Architecture baseline for implementation  
**Platform:** Flutter/Dart, Android-first  
**Backend:** Supabase / PostgreSQL  
**Identity:** Independent Nipto ID and password  
**Implementation status:** This document does not claim source code, tests, or release readiness are complete.

## 1. Product Principles
- Unified social networking and communication: profiles, feed, posts, stories, short videos, messaging, discovery, notifications and calling.
- Independent Nipto identity; no mandatory email, phone, Google, Apple, or external identity provider for normal registration/sign-in.
- Privacy and authorization enforced by backend.
- Modular, testable code; reliable error/offline behavior; performance measured; features verified before completion.

## 2. System Architecture
Flutter Android client (UI/design system/router, feature state, repositories/services, networking/cache/secure storage, media/realtime/WebRTC) connects over HTTPS/WebSocket to Supabase backend. Backend includes auth/session handling, PostgreSQL, RLS, RPC/Edge Functions, Realtime, Storage and processing jobs. Privileged secrets remain server-side.

## 3. Flutter Structure
```
lib/
  main.dart
  app/{bootstrap,router,theme,lifecycle}
  core/{config,errors,networking,security,storage,cache,utils,widgets}
  services/{auth,realtime,media,notifications,connectivity,calls}
  features/{authentication,home,feed,profiles,discovery,posts,comments,
    stories,short_videos,messaging,calls,notifications,settings,moderation,search}
test/
integration_test/
```
Feature modules use data/domain/presentation boundaries. Screens do not issue unrestricted database operations. Repositories coordinate data access, services provide shared technical capabilities, and errors/states are typed.

## 4. Navigation
Routes include startup, auth login/register/recovery, home, discover, create, messages and conversation detail, profile by Nipto ID, post, story, clip, notifications, and settings (account/privacy/security/notifications/appearance). Deep links must validate session, existence, ownership, privacy, relationship restrictions, blocks and expiration.

## 5. Authentication
Registration: normalize/validate Nipto ID, check availability, suggest alternatives, password selection, optional recovery account, atomic account creation and profile setup. Suggested ID policy: 3–24 characters; letters/numbers and permitted underscores; reject invalid separators/reserved IDs. Final uniqueness is enforced atomically by the database, not only availability checks. Passwords are securely hashed and never logged or stored plaintext. Sessions support expiry, refresh, revocation and sign-out. Auth errors should not unnecessarily reveal account existence.

## 6. Optional Nipto-to-Nipto Recovery
A user may nominate another Nipto account. The nominated account must explicitly approve. Requests expire, are rate-limited, auditable and revocable by authorized parties. Recovery must not silently grant permanent access. No email-based recovery or mandatory email verification in the standard flow.

## 7. Database Domains
- Identity: nipto_accounts, profiles, account_credentials
- Sessions: user_sessions
- Recovery: recovery_links, recovery_requests, recovery_approvals, recovery_events
- Social graph: follows, blocks, restrictions
- Content: posts, post_media
- Engagement: post_likes, comments, comment_replies
- Stories: stories, story_views
- Video: clips, clip_engagements
- Messaging: conversations, conversation_members, messages, message_receipts
- Notifications: notifications, notification_preferences
- Safety: reports, moderation_actions
- Calls: call_sessions, call_participants
- Media: media_assets, media_processing_jobs

Use foreign keys, uniqueness/check constraints, transactions, appropriate indexes, versioned migrations, cursor pagination and explicit retention/deletion behavior.

## 8. Authorization & Privacy
RLS protects private/user-owned records. Backend checks validate ownership, privacy, follow/relationship rules, blocks/restrictions and participant membership. Storage policies align with visibility. Client visibility checks are not security boundaries. Realtime events do not confer authorization. Never ship service-role keys in Flutter.

## 9. Profiles & Social Graph
Profiles include avatar, cover, display name, Nipto ID, bio, visibility, preferences, followers/following and content. Actions include follow/unfollow, request/accept/reject/cancel, remove follower, block and restrict. Private-account behavior is backend-authoritative.

## 10. Feed, Posts, Comments
Posts support text, image, video, multiple and mixed media; draft, preview, publish, edit, delete, like, comment/reply, share, save, hide and report. Feed uses cursor pagination, stable ordering, refresh and deduplication with loading/empty/offline/error/retry states. Ranking balances freshness, relationship, quality and user-controlled signals. Comments support create/edit/delete/reply/like/report; preserve drafts on failure and validate access server-side.

## 11. Stories
Images/video, overlays, audience controls, replies, reactions, view tracking/viewer list where permitted, archive, expiration and deletion. Expired content must not remain available via stale caches or direct paths.

## 12. Short Videos
Vertical playback, captions, creator profile, likes/comments/share/save/follow, upload, processing and discovery. Pause off-screen, dispose controllers, and bound active players/cache/memory.

## 13. Messaging
Inbox and one-to-one conversations; text and approved attachments; realtime delivery; replies, reactions, edits/deletes, sending/sent/delivered/read/failed states, typing, unread, pagination/search, mute/block/privacy. Idempotency prevents duplicate sends on retry.

## 14. Realtime
Fetch authoritative state then subscribe; validate and deduplicate events; handle ordering/reconnect; reconcile on reconnect; avoid duplicate subscriptions; clean up; use selective, privacy-safe payloads.

## 15. WebRTC Calls
Audio/video call lifecycle, signaling, session descriptions, ICE, STUN/TURN, permissions, audio routing, mute/camera, end/reconnect/failure, invitations/notifications. Validate participants and authorization server-side. States: idle, calling, ringing, connecting, connected, reconnecting, ended, failed.

## 16. Media
Select → validate → upload → server validation → processing (resize/thumbnail/transcode/metadata) → controlled storage → authorized delivery. Provide progress/retry/cancel, ownership checks, cleanup and bounded cache/storage.

## 17. Search & Discovery
Search Nipto IDs, people, posts, clips, hashtags and topics. Recommendations respect privacy, blocks, restrictions, deleted content and account visibility; include controls to hide/not interested/mute/block/reset.

## 18. Notifications
Follow/request/approval, likes, comments/replies, mentions, messages, calls, recovery and security events. Provide unread, read/mark-all, pagination, preferences, deduplication and validated deep links. Avoid sensitive content in logs/analytics.

## 19. Moderation & Trust
Reports for accounts, posts, comments, messages, stories and clips. Workflow: validate → queue → review → decision → action/audit → appeal where applicable. Rate limits and abuse controls.

## 20. Performance & Scalability
Lazy lists, stable keys, minimal rebuilds, resized images, thumbnail-first loading, bounded cache/controllers, lifecycle cleanup, request timeout/cancel/retry/deduplication. Measure startup, scrolling, feed/media latency, memory, network, crash/ANR. Optimize PostgreSQL queries/indexes, cursor pagination, connection usage, queues, rate limits and capacity based on observed load.

## 21. Security Threat Model
Account takeover, ID enumeration, unauthorized data access, session theft, spam, duplicate actions, media exposure, privilege escalation, malicious uploads and recovery abuse. Controls: secure password hashing, rate limits, secure sessions/revocation, RLS, server-side checks, idempotency, storage policies, validation, isolated processing, approval/expiry/revocation/audit, safe logs and secret management.

## 22. Integrity, Migrations & Recovery
Versioned migrations; transactions and constraints; clean/existing DB tests; rollback or forward-repair planning; backups before risky changes; deployed schema verification. Automated backups, storage recovery, documented restore drills, recovery objectives and backup monitoring.

## 23. State & Offline
Backend is authoritative for session/identity, profile, graph, posts, messages, privacy, permissions and media processing. Client owns transient UI/playback; drafts may be local. Cache with freshness rules, preserve pending input, represent offline/reconnecting/pending/failed/synchronizing states and reconcile after reconnect.

## 24. Observability & Analytics
Monitor crashes, ANRs, API/database latency, realtime, upload/processing, call failures and storage. Aggregate metrics privacy-consciously. Never log passwords, secrets, recovery tokens or private message contents.

## 25. Testing
Unit: validation, normalization, state, repositories, errors, pagination. Widget: auth/feed/profile/messaging/settings/states. Integration: registration, login, recovery, follow, post/comment, upload, message, realtime, calls, sign-out. Backend: RLS, authorization, uniqueness, privacy, blocks, recovery, rate limits. Network/media/Android lifecycle, permissions, low-memory and release validation.

## 26. Android Compatibility
Test supported OS/device sizes, permissions, notifications, camera/mic/audio routing, foreground/background, process death/restart, low memory, interrupted network/uploads, accessibility and device-specific behavior.

## 27. Configuration & Environments
Standard developer commands should not require repeated manual config flags. Separate dev/staging/prod. Validate public config. Never embed privileged secrets in Flutter. Reproducible build configuration.

## 28. CI/CD & Release
Pipeline: format → analyze → unit/widget → backend/migration checks → integration → release build → artifact validation → distribution → monitoring. Debug APK for development; release APK for suitable testing; AAB for Play. Signing keys remain outside source.

## 29. Incident & Maintenance
Incident detection, severity, response, communication, recovery, root-cause tracking, dependency/security review, staged rollout, controlled migrations and rollback/forward-repair strategy.

## 30. 50-Phase Roadmap
1. Architecture and product baseline
2. Repository and Flutter foundation
3. Configuration and environments
4. Shared design system
5. Navigation and lifecycle
6. Backend foundation
7. Database schema and migrations
8. Authorization and RLS
9. Identity and registration
10. Session and sign-in
11. Recovery architecture
12. Profiles
13. Social graph and follow requests
14. Feed foundation
15. Posts and media attachments
16. Likes and engagement
17. Comments and replies
18. Search
19. Create and upload workflows
20. Privacy settings
21. Stories
22. Story views and audience controls
23. Short-video foundation
24. Video processing and delivery
25. Messaging foundation
26. Realtime message delivery
27. Receipts, reactions and message controls
28. Notifications
29. WebRTC calling
30. Integration and stabilization
31. UX screen inventory
32. Backend integration matrix
33. Interaction contracts
34. Backend action contracts
35. Navigation/deep-link contracts
36. State management and consistency
37. Performance engineering
38. Scalability and capacity
39. Security hardening and threat model
40. Data integrity, migrations and backup
41. Media processing and delivery
42. Advanced realtime synchronization
43. Recommendations and discovery
44. Moderation and trust/safety
45. Analytics and observability
46. Comprehensive QA
47. Android compatibility/device validation
48. Release engineering and deployment
49. Production readiness audit
50. Launch and maintenance framework

## 31. Definition of Done
A feature is complete only when UI and interaction, real backend integration, authorization/privacy, loading/empty/offline/error/retry states, duplicate protection, input preservation, tests and Android verification are complete; no critical defects remain and evidence is recorded.

## 32. Production Readiness Checklist
- [ ] Registration and ID uniqueness
- [ ] Login/session restore/revocation
- [ ] Approved Nipto-to-Nipto recovery
- [ ] RLS and storage access
- [ ] Profile/follow workflows
- [ ] Feed/posts/comments
- [ ] Stories/short videos
- [ ] Messaging/realtime
- [ ] Calls
- [ ] Notifications/deep links
- [ ] Privacy/block/report
- [ ] Migrations/backup/restore
- [ ] Performance/reliability metrics
- [ ] Unit/widget/integration/security tests
- [ ] Android compatibility
- [ ] Release build/signing
- [ ] Monitoring/incident plan

## 33. Change Control
This document is the implementation baseline. Architecture changes require documented rationale, privacy/security impact, migration implications and tests. It does not claim source, backend, tests or release are already complete.

## Appendix — Engineering Workflow
Requirement → inspect current source → identify gap → focused implementation → format/analyze → tests → backend security validation → Android verification → evidence → next task.

## Appendix — Initial Repository Risk
Prior conversation reported possible local corruption in a session manager and test/config scaffolding. This report is unverified against the current remote main branch. Inspect before repairing; do not blindly replace or delete untracked files, backups or configuration.
