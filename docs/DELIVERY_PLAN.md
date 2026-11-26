# Nipto Social Delivery Plan

## Phase 0 — Foundation
- [x] Verify clean GitHub repository and intended Supabase project.
- [x] Establish product scope and three-tab navigation.
- [x] Create schema for identity, follows, blocks, chat, statuses, posts, Shorts, notifications and reports.
- [x] Enable RLS and private media buckets.
- [x] Add Nipto ID-to-Auth lookup restricted to service role (legacy flow; to be retired).
- [x] Add Nipto ID login Edge Function and attempt limiting.
- [x] Implement four-destination Flutter app shell (Home, Chats, Shorts, You) and initial Nipto ID auth UX.
- [x] Add Android platform scaffolding and verify debug build in CI.
- [x] Add private feedback intake schema and user feedback screen.
- [x] Align design tokens with Nipto logo palette.

## Phase 1 — Identity and discovery
- [x] Legacy registration and Nipto ID sign-in endpoint retained only as a migration bridge; it is not compliant with the current no-email requirement and must be retired after cutover.
- [x] Profile editing, unique handle validation and prefix search.
- [x] Follow requests, private profiles, blocks and profile visibility.
- [x] Message privacy and notification preference controls.
- [x] Add consent-based optional Recovery Nipto ID management after sign-in in Settings; registration does not collect a recovery account.
- [x] Implement the email-free in-app recovery request, accepted recovery-account approval, and short-lived one-time password-reset grant path; staging replay/rate-limit/device validation remains open.
- [x] Add a user-confirmed global sign-out action that revokes refresh sessions; current access tokens may remain valid until expiry.

## Phase 2 — Messaging
- [x] Inbox, direct conversations and group invitations.
- [x] Realtime text messages, image attachments and basic read receipts.
- [x] Batch conversation read-receipt updates through a membership-checked server RPC; avoid per-message client update loops.
- [x] Private chat media and signed access.
- [x] Add newest-first 50-message conversation loading with cursor-based older-page retrieval while retaining the live latest-message stream.
- [ ] Complete message requests, retries, audio/video/file attachments and multi-device delivery.
- [ ] Validate the new author-scoped message edit/delete RPCs and long-press UI in CI and a disposable staging database before marking this slice complete.
- [ ] Implement one-to-one WebRTC voice/video calls using private authenticated signaling, short-lived TURN credentials, push wake-up, call lifecycle controls and mobile network recovery; see `docs/WEBRTC_CALLS.md`.
- [ ] Add group calling through an SFU only after one-to-one calling is stable; no production mesh fan-out.

## WebRTC implementation checkpoint (in progress)
- [x] Add Flutter WebRTC dependency and Android microphone, camera and network permissions to the generated Android manifest in CI.
- [x] Add a call service for local media capture, peer connections, SDP offer/answer exchange, trickled ICE, serialized signaling, mute/camera controls and resource cleanup.
- [x] Add a one-to-one call screen and voice/video entry points in direct conversations.
- [x] Add foreground incoming-call polling while the relevant conversation is open, with accept/decline actions.
- [ ] Verify the Flutter implementation with passing CI, including analyzer, tests and Android build.
- [ ] Configure production TURN with short-lived credentials minted server-side; the current STUN-only development configuration is not sufficient for reliable production NAT traversal.
- [ ] Add push notifications and app-wide incoming-call handling when the recipient is outside the conversation screen.
- [ ] Add audio routing/Bluetooth controls, network handoff recovery, connection timeout handling and comprehensive automated tests.
- [ ] Complete two-device real-network tests before enabling calls for production users.

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
- [x] Push delivery plumbing and notification deep links, including incoming-call tap routing. Firebase credentials, worker secret and physical-device verification remain operational gates.
- [x] Role-gated staff review UI for feedback, abuse reports and pending content; backend authorization and audit logging are deployed.
- [x] Privacy export/deletion request workflows with a secret-protected fulfillment worker. End-to-end export/deletion runs with real accounts remain an operational gate.
- Offline, accessibility, performance and device testing, including two-device WebRTC network-transition tests.
- App signing, Play Console policy review and release APK/AAB.

## Definition of done

A feature is done only when its UI, database access, failure handling, authorization tests and Android behavior have been verified. A deployed table or visible screen alone is not a completed feature.


## Updated critical path — email-free Nipto identity

- [x] Add Nipto identity issuer source: Nipto ID/password, Argon2id, asymmetric ES256 JWT, JWKS/discovery, refresh rotation and recovery endpoints. Runtime validation and key deployment remain open.
- [ ] Build a hosted Supabase project with Custom OIDC and configure its Auth service with the Nipto custom OIDC provider; no email or phone claim may be collected.
- [ ] Prove no-email user provisioning, stable UUID mapping, RLS, PostgREST, Storage, Realtime and RPC behavior in staging.
- [x] Implement optional recovery Nipto account linking after sign-in in Settings, with explicit acceptance. Registration does not request recovery details. End-to-end backend and device tests remain open.
- [x] Add in-app forgot-password request, approval inbox, one-time expiring reset-grant and password-reset code paths. End-to-end security tests, notification delivery and replay/rate-limit validation remain open.
- [ ] Migrate existing accounts/data with backups, preserve profile UUIDs, and retain a tested rollback path.
- [ ] Remove legacy email fields, email lookup, email reset UI and old login Edge Function only after the replacement is proven.

The existing hosted Supabase project remains the target. Its Custom OIDC integration must be configured before Nipto-issued JWTs are used. The Nipto OIDC issuer runs as a Nipto-controlled Edge Function in the existing Supabase project; signing-key secrets must be configured outside source control.


## Current native-auth engineering checkpoint

- [x] Replace email-based registration/sign-in UI with Nipto ID and password UI in the review branch.
- [x] Add Android secure refresh-token storage and a Nipto session manager.
- [x] Route Supabase client requests through the Nipto JWT access-token callback.
- [x] Replace application reads of Supabase Auth current-user state with the Nipto session identity.
- [x] Add in-app recovery request, approval inbox, and one-time password reset screen.
- [x] Add OIDC key-generation utility; key material is generated locally and never committed.
- [x] Implement the legacy-account migration bridge, preserving existing profile UUIDs and clearing legacy Auth email/phone identities only after the Nipto identity is linked; staging and rollback validation remain open.
- [ ] Validate the SQL migration in a disposable staging database; do not apply it to production yet.
- [ ] Configure Edge Function secrets and the Supabase Custom OIDC trust integration.
- [x] Run Deno Edge Function tests, Flutter analysis/tests, Android debug APK build and artifact upload on the latest validated auth checkpoint.
- [ ] Re-run CI for the follow-up comment-editing commits; two-device security tests remain open.


## Latest implementation review — 2026-11-17

- [x] Build and upload a CI debug APK artifact on commit `78794b2d83e5bb7f7b1019ad79def96ceb684812`; this is a debug artifact, not a signed release.
- [x] Audit the deployed auth trigger and normalize it to the private `auth.users` handler so new users are provisioned from `custom:nipto`.
- [x] Serialize parallel password-recovery starts per Nipto identity.
- [x] Restrict OIDC scopes to `openid` and optional `profile`; reject email and all unsupported scopes.
- [x] Add static migration regression tests for trigger wiring, recovery serialization, single-use reset grants and service-role-only identity RPCs.
- [ ] Re-run CI on the latest follow-up commits and verify the newly added regression tests.
- [ ] Apply migrations only to a disposable staging Supabase project, configure OIDC secrets/provider, and complete end-to-end registration, login, legacy migration, recovery, RLS, Storage and Realtime tests.
- [ ] Keep production Supabase unchanged until staging, rollback, security and physical-device acceptance tests pass.

## Social discovery and connected chat access checkpoint

- [x] Keep account search available for all active accounts, independent of follow state; add Nipto ID/display-name prefix search.
- [x] Hide Message action for accounts with no accepted follow in either direction; private follow requests do not enable chat.
- [x] Filter direct conversations in the inbox to accepted follower/following connections; group chats remain separately membership-based.
- [x] Enforce direct-chat creation, message reads/writes, and private chat-media access in database policies/RPC, not only Flutter UI.
- [x] Return limited identity fields for unapproved viewers of private accounts.
- [x] Limit ordinary message update grants to body and edited timestamp; disable hard-delete from client role.
- [ ] Run CI/static tests and validate migration on a disposable staging database with both follow directions, pending private follow, unfollow, block, and direct RPC bypass cases.

## Calling infrastructure checkpoint

- [x] Replace the public third-party STUN dependency with authenticated Nipto-managed ICE configuration.
- [x] Add short-lived HMAC TURN credential issuance from the Nipto identity Edge Function.
- [x] Add a self-hosted coturn Docker Compose deployment template.
- [ ] Provision the TURN host, DNS and TLS certificate; configure the same shared secret in coturn and Supabase Edge Function Secrets.
- [ ] Verify UDP and TCP/TLS relay across independent mobile networks and complete two-device call tests.


## Registration/recovery UX contract fix — 2026-11-22

- [x] Remove recovery-account collection from the registration screen; recovery linking belongs in Settings after account creation, as defined by the native-auth contract.
- [x] Add a Flutter widget regression test ensuring the registration screen does not collect recovery-account details.
- [ ] Verify the regression test and Android build in GitHub Actions.
