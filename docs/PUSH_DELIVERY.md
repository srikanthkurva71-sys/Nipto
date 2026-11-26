# Nipto push delivery

Nipto uses Firebase Cloud Messaging (FCM) for real Android push delivery. The
Flutter client never contains a service-role key, a Firebase service-account key,
or any dispatch authority. It only registers its own FCM token through a scoped
RPC and consumes ID-only push events.

## Components

- `private.push_delivery_outbox` — durable queue. Inserts into
  `public.notifications` and `private.call_sessions` enqueue rows with opaque
  identifiers only.
- `public.register_device_push_token` / `public.unregister_device_push_token` —
  authenticated RPCs. A caller can only add or remove its own device token.
- `public.nipto_push_*` — worker-only RPCs. They are revoked from `anon`,
  `authenticated`, and `public`; only `service_role` can claim, complete, fail,
  read tokens, or invalidate stale tokens.
- `nipto-push-dispatch/worker/run` — Edge Function that mints an FCM OAuth token
  from a service account, sends HTTP v1 messages, and records retry/invalidation
  outcomes. It is protected by `CRON_SECRET`, which is also used by the privacy
  worker; keep one shared secret in Supabase secrets and in the scheduler.
- `NiptoPushService` — initializes Firebase only when client-safe Firebase
  options are supplied at build time, requests notification permission, registers
  the FCM token after sign-in, unregisters it before sign-out, and exposes
  foreground/tap events to the app shell.

## One-time Firebase setup

1. In Firebase, create or select the project that will send Nipto pushes.
2. Add an Android app with package name `com.nipto.nipto`.
3. Download the generated `google-services.json`.
4. After `scripts/bootstrap_nipto_windows.ps1` (or CI) regenerates
   `mobile/app/android/`, copy that file to:

   `mobile/app/android/app/google-services.json`

   The generated Android tree is gitignored. Do not commit this file. If it is
   absent or malformed, `scripts/configure_android_platform.py` leaves the
   Google Services Gradle plugin disabled so ordinary builds still work.
5. Create a Firebase service account with Firebase Admin / Cloud Messaging
   permissions and download its JSON key. Keep it outside the repository.

## Supabase secrets

Use `python scripts/setup_nipto_credentials.py worker-secret` followed by
`python scripts/setup_nipto_credentials.py push` to keep the values in ignored
local files and out of shell history. See `docs/CREDENTIAL_SETUP.md` for the full
flow. The equivalent CLI command is:

~~~powershell
supabase secrets set --project-ref advmjribduqzyuwktkod `
  FCM_SERVICE_ACCOUNT_JSON='<entire service-account JSON>' `
  CRON_SECRET='<long random worker secret>'
~~~

`NIPTO_PUSH_WORKER_SECRET` is also accepted as an alias for `CRON_SECRET`.
Secret names must not start with `SUPABASE_`. The Edge Function reads the
service-role key from the hosted `SUPABASE_SECRET_KEYS` / legacy
`SUPABASE_SERVICE_ROLE_KEY` injection; do not create a duplicate custom secret
with those names.

## Building with push enabled

Client Firebase values are public mobile-app identifiers, but they are supplied
at build time so an unconfigured checkout never starts Firebase:

~~~powershell
cd mobile/app
flutter build apk --debug `
  --dart-define=NIPTO_FIREBASE_API_KEY='<firebase apiKey>' `
  --dart-define=NIPTO_FIREBASE_PROJECT_ID='<firebase projectId>' `
  --dart-define=NIPTO_FIREBASE_APP_ID='<firebase mobilesdk_app_id>' `
  --dart-define=NIPTO_FIREBASE_MESSAGING_SENDER_ID='<sender id>' `
  --dart-define=NIPTO_FIREBASE_STORAGE_BUCKET='<optional storage bucket>'
~~~

Use the same `--dart-define` values for `flutter run` and
`flutter build appbundle --debug`. Without them, push initialization is a
no-op and the app remains usable with its in-app inbox.

## Running the dispatcher

Invoke the worker after deployment:

~~~bash
curl -X POST \
  -H 'Authorization: Bearer $CRON_SECRET' \
  'https://advmjribduqzyuwktkod.supabase.co/functions/v1/nipto-push-dispatch/worker/run'
~~~

The endpoint also accepts `x-nipto-worker-secret: $CRON_SECRET`. It claims at
most 50 due jobs per invocation. A missing secret returns `503`; a wrong secret
returns `401`. Schedule it externally (for example with a trusted scheduler);
do not embed the worker secret in client code or in a public cron definition.

## Verification checklist

- With no worker secret configured, `POST /worker/run` returns `503`.
- With a wrong secret, it returns `401`.
- After inserting a notification or call session, confirm the outbox row:

  ~~~sql
  select id, user_id, delivery_type, state, payload
  from private.push_delivery_outbox
  order by created_at desc
  limit 5;
  ~~~

- After a successful worker run, the response contains `processed`,
  `delivered`, and `failed`; the outbox row is `sent`.
- FCM `404`, `410`, or `UNREGISTERED` removes that device token from
  `public.device_tokens`; other tokens for the same account remain.
- A foreground push appears through Nipto's local notification channel
  `nipto_default`. A background/terminated tap waits for session restoration,
  then routes to the incoming-call screen, the message conversation with
  authorized header metadata, or the notification inbox. No payload exposes
  message bodies, names, or other private content.
- No payload contains SDP, ICE candidates, message bodies, display names,
  passwords, tokens, or other secrets.

## Current status

The database plumbing, client, and Edge Function are implemented, tested, and
deployed (`nipto-push-dispatch` v2). Live probes confirm unauthenticated worker
requests are rejected. Firebase credentials and `CRON_SECRET` were not supplied,
so live FCM delivery, background/terminated tap routing, and incoming-call
wake-up are not yet verified. With no worker secret configured the dispatcher
fails closed with `503`. Do not claim push is production-ready until the
checklist passes on a physical device.
