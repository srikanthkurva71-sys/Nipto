# Nipto Social Delivery Plan

## Phase 0 — Foundation
- [x] Verify clean GitHub repository and intended Supabase project.
- [x] Establish product scope and three-tab navigation.
- [x] Create schema for identity, follows, blocks, chat, statuses, posts, Shorts, notifications and reports.
- [x] Enable RLS and private media buckets.
- [x] Add Nipto ID-to-Auth lookup restricted to service role.
- [x] Add Nipto ID login Edge Function and attempt limiting.
- [x] Implement four-destination Flutter app shell (Home, Chats, Shorts, You) and initial Nipto ID auth UX.
- [x] Add Android platform scaffolding and verify debug build in CI.
- [x] Add private feedback intake schema and user feedback screen.
- [x] Align design tokens with Nipto logo palette.

## Phase 1 — Identity and discovery
- [x] Registration, email confirmation and Nipto ID sign-in endpoint.
- [x] Profile editing, unique handle validation and prefix search.
- [x] Follow requests, private profiles, blocks and profile visibility.
- [x] Message privacy and notification preference controls.
- [ ] Verify account recovery deep links and session/device management.

## Phase 2 — Messaging
- [x] Inbox, direct conversations and group invitations.
- [x] Realtime text messages, image attachments and basic read receipts.
- [x] Private chat media and signed access.
- [ ] Complete message requests, retries, pagination, audio/video/file attachments and multi-device delivery.

## Phase 3 — Status
- [x] Text/image/video status publishing.
- [x] 24-hour visibility expiry filtering and viewer inserts.
- [x] Follower-only audience default.
- [ ] Add cleanup job, close-friends audience UI and complete viewer-list screen.

## Phase 4 — Shorts and posts
- [x] Image post picker, caption, visibility choice and private upload.
- [x] Vertical Shorts feed, MP4 upload validation, playback lifecycle, likes and comments.
- [x] Home feed, likes/comments and profile post grid.
- [ ] Build trusted review/moderation operations, thumbnail/transcoding pipeline, video post playback and robust upload resume.

## Phase 5 — Feedback, safety operations and production readiness
- [x] Feedback intake and user-owned history (separate from abuse reports).
- [x] Private staff-role model, fail-closed access checks and audited staff action log.
- [x] Backend RPCs for feedback triage, user-report review and pending post/Short moderation.
- [x] User-facing feedback responses and report/content status notifications.
- [x] Role-gated staff console for feedback, report and pending-content queues; server authorization remains the security boundary.
- [ ] Test staff RPCs as no-role, moderator and admin identities.
- Push delivery and deep links.
- Abuse/report review tools and moderation operations.
- Privacy export/deletion workflows.
- Offline, accessibility, performance and device testing.
- App signing, Play Console policy review and release APK/AAB.

## Definition of done

A feature is done only when its UI, database access, failure handling, authorization tests and Android behavior have been verified. A deployed table or visible screen alone is not a completed feature.
