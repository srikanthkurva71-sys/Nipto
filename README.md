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

1. **Chats** — inbox, Nipto ID search, discovery, following, direct/group chats and 24-hour statuses.
2. **Shorts** — a vertical, swipe-first short-video feed with likes, comments and creator profiles.
3. **You** — personal profile, followers/following, posts, settings, privacy and security.

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

## Current implementation boundary

The schema and first authentication endpoint are provisioned. The Flutter screens are the initial app shell and interaction foundation; chat, status, Shorts publishing, push delivery, video processing, moderation operations, and production hardening still require end-to-end implementation and validation. Do not describe the product as production-ready until those checks pass.
