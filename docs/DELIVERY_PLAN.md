# Nipto Social Delivery Plan

## Phase 0 — Foundation
- [x] Verify clean GitHub repository and intended Supabase project.
- [x] Establish product scope and three-tab navigation.
- [x] Create schema for identity, follows, blocks, chat, statuses, posts, Shorts, notifications and reports.
- [x] Enable RLS and private media buckets.
- [x] Add Nipto ID-to-Auth lookup restricted to service role.
- [x] Add Nipto ID login Edge Function and attempt limiting.
- [ ] Finish Flutter app shell and auth UX.
- [x] Add Android platform scaffolding and verify debug build in CI.
- [x] Add private feedback intake schema and user feedback screen.
- [x] Align design tokens with Nipto logo palette.

## Phase 1 — Identity and discovery
- Registration, email confirmation, Nipto ID login and recovery.
- Profile editing, unique handle checks and search.
- Follow requests, private profiles, blocks and profile visibility.
- Session management and notification preferences.

## Phase 2 — Messaging
- Inbox, direct conversations and group invitations.
- Realtime messages, retries, pagination and receipts.
- Private attachments, upload progress and signed access.
- Message request/unsolicited message settings.

## Phase 3 — Status
- Text/image/video status publishing.
- 24-hour expiry and cleanup.
- Audience controls, close friends and viewer list.

## Phase 4 — Shorts and posts
- Video/image picker and upload validation.
- Thumbnail generation, transcoding and moderation.
- Vertical feed, playback lifecycle, likes and comments.
- Profile posts grid.

## Phase 5 — Feedback, safety operations and production readiness
- Feedback intake, user-owned history and trusted status workflow.
- Staff-only feedback triage and abuse-report review console (not yet implemented).
- Moderation queues and auditable decisions for user-generated content.
- Push delivery and deep links.
- Abuse/report review tools and moderation operations.
- Privacy export/deletion workflows.
- Offline, accessibility, performance and device testing.
- App signing, Play Console policy review and release APK/AAB.

## Definition of done

A feature is done only when its UI, database access, failure handling, authorization tests and Android behavior have been verified. A deployed table or visible screen alone is not a completed feature.
