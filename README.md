# Nipto Social

**Nipto is an Android-first social communication app built around one Nipto ID.** It brings private messaging, status updates, social discovery, profiles and short-form video into one simple, fast experience.

This repository is the first implementation of Nipto Social. The former ride-hailing direction is out of scope.

## Product principles

- **One identity:** people register with a unique Nipto ID and sign in with that ID and their password.
- **Private by default where it matters:** private accounts, message membership checks, blocked-user enforcement and private media buckets.
- **Fast and calm:** three primary destinations, lightweight chat lists, paginated feeds and lazy video playback.
- **Creator-friendly:** simple status and short-video publishing, with content moderation before public distribution.
- **Android first:** Flutter + Dart. No web product is planned for v1.

## Main navigation

1. **Home** — paginated feed of approved posts, likes and comments from accounts visible to the signed-in user.
2. **Chats** — inbox, Nipto ID search, discovery, following, direct/group chats, 24-hour statuses and activity notifications.
3. **Shorts** — a vertical, swipe-first short-video feed with likes, comments and creator profiles.
4. **You** — personal profile, followers/following, photo posts, settings, privacy and security.

## Technology

| Layer | Choice |
|---|---|
| Android app | Flutter + Dart |
| Authentication | Supabase Auth + Nipto ID lookup Edge Function |
| Database | Supabase PostgreSQL |
| Authorization | PostgreSQL Row Level Security |
| Live messaging | Supabase Realtime |
| Media | Private Supabase Storage buckets |
| Server-side logic | Supabase Edge Functions |

Connected Supabase project: Nipto  
Project ref: advmjribduqzyuwktkod  
Project URL: https://advmjribduqzyuwktkod.supabase.co

The Android app must use a **publishable key only**. Never place a service-role/secret key in Flutter, Android resources, GitHub, or a client-side environment file.

## Repository layout

- lib/ — Flutter application.
- supabase/migrations/ — versioned PostgreSQL schema and policy migrations.
- supabase/functions/nipto-login/ — Nipto ID password sign-in.
- docs/ — product, UX and security decisions.

## Local Android setup

Install the Flutter stable SDK and Android SDK, then generate the Android platform folder if it is not present:

~~~bash
flutter create --platforms=android --org app.nipto --project-name nipto .
flutter pub get
flutter analyze
flutter test
~~~

Run with the Nipto Supabase project:

~~~bash
flutter run --dart-define=SUPABASE_URL=https://advmjribduqzyuwktkod.supabase.co --dart-define=SUPABASE_PUBLISHABLE_KEY=YOUR_SUPABASE_PUBLISHABLE_KEY
~~~

Build a release APK:

~~~bash
flutter build apk --release --dart-define=SUPABASE_URL=https://advmjribduqzyuwktkod.supabase.co --dart-define=SUPABASE_PUBLISHABLE_KEY=YOUR_SUPABASE_PUBLISHABLE_KEY
~~~

The publishable key is intended for client applications; RLS is the security boundary. Secret/service-role keys are backend-only.

## Supabase state

The initial social schema and security migrations are applied to the connected Nipto Supabase project. See supabase/migrations/. The nipto-login Edge Function is deployed with JWT verification disabled because it is the unauthenticated sign-in endpoint; it has its own input validation and database-backed attempt limiting.

New users register with a recovery email, a Nipto ID and a password. Supabase Auth verifies and stores credentials. The profile trigger stores only the public Nipto ID and display name. Login resolves the Nipto ID to the private Auth email on the server, then delegates password verification to Supabase Auth. The recovery email is never returned by the lookup function.

## Current implementation status

The repository contains a Flutter Android app foundation and a live Supabase schema. Implemented app areas include Nipto ID registration/sign-in, profile editing and avatar uploads, photo posts, Nipto ID discovery and follow requests, direct/group conversation flows, text messages and basic media attachments, 24-hour statuses, Shorts upload/feed interactions, Home feed, in-app notifications, privacy controls, blocking/reporting, and private user feedback intake/history. Some flows still need deeper end-to-end, device and moderation validation.

The feedback subsystem is separate from abuse reports. Signed-in users can submit app-experience ratings, bug reports, feature ideas or support requests and view their own submission status. Feedback is protected by RLS and limited to five submissions per account per 24 hours. A trusted staff-only triage console and response workflow remain outstanding.

All 21 public application tables currently have Row Level Security enabled. Anonymous table privileges were revoked and client writes were narrowed. Nine intentionally exposed SECURITY DEFINER RPCs remain authenticated-only and are monitored by the Supabase security advisor.

GitHub Actions runs Dart formatting, static analysis, tests and an Android debug APK build. A passing CI run proves that the checked commit builds; it does not prove complete device-level or production readiness.

## Remaining production gates

- Verify the latest commit's full CI run and test critical flows on physical Android devices.
- Configure and test verified email recovery, Android deep links and production Auth policies.
- Implement push delivery and notification routing.
- Implement video scanning/transcoding, thumbnails and resilient upload processing.
- Build staff-only feedback triage, abuse-report review and content-moderation operations.
- Complete account deletion, data export and retention workflows.
- Add automated multi-user RLS/storage tests, accessibility checks, performance tests and independent security review.
- Configure release signing, Play Console compliance and a production AAB.

Do not describe Nipto as production-ready until these gates have passed.
