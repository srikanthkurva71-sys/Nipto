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
- [x] Add optional trusted Recovery Nipto ID at signup and consent-based recovery-contact management in Settings; recovery requests and approvals notify both accounts.
- [ ] Complete verified-email password recovery deep-link acceptance and per-device session inventory.
- [x] Add a user-confirmed global sign-out action that revokes refresh sessions; current access tokens may remain valid until expiry.

## Phase 2 — Messaging
- [x] Inbox, direct conversations and group invitations.
- [x] Realtime text messages, image attachments and basic read receipts.
- [x] Batch conversation read-receipt updates through a membership-checked server RPC; avoid per-message client update loops.
- [x] Private chat media and signed access.
- [x] Add newest-first 50-message conversation loading with cursor-based older-page retrieval while retaining the live latest-message stream.
- [ ] Complete message requests, retries, audio/video/file attachments and multi-device delivery.
- [ ] Implement one-to-one WebRTC voice/video calls using private authenticated signaling, short-lived TURN credentials, push wake-up, call lifecycle controls and mobile network recovery; see `docs/WEBRTC_CALLS.md`.
- [ ] Add group calling through an SFU only after one-to-one calling is stable; no production mesh fan-out.

## Phase 3 — Status
- [x] Text/image/video status publishing.
- [x] 24-hour visibility expiry filtering and viewer inserts.
- [x] Follower-only audience default.
- [x] Add owner-only status viewer list with a minimal, server-authorized identity projection.
- [x] Add Close Friends management from accepted connections and per-status audience selection; database visibility checks enforce the selected audience.
- [x] Add owner-controlled status deletion with best-effort private media cleanup.
- [ ] Add scheduled expiry cleanup job for expired status rows and media.

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
- [x] Validate the role-gated staff console through formatting, static analysis, unit/widget tests and Android debug APK CI; production staff-session acceptance testing remains an operational gate.
- [x] Test staff RPCs fail closed for identities without staff roles; moderator/admin acceptance testing remains an operational gate.
- [x] In-app notifications for trusted recovery-contact requests and approvals, with navigation to the recovery-contact manager.
- [ ] Push delivery and notification deep links (also required for incoming-call wake-up).
- [x] Role-gated staff review UI for feedback, abuse reports and pending content; backend authorization and audit logging are deployed.
- Privacy export/deletion workflows.
- Offline, accessibility, performance and device testing, including two-device WebRTC network-transition tests.
- App signing, Play Console policy review and release APK/AAB.

## Definition of done

A feature is done only when its UI, database access, failure handling, authorization tests and Android behavior have been verified. A deployed table or visible screen alone is not a completed feature.
