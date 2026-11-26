# Nipto media and privacy operations

This document covers the server-side media validation pipeline and the privacy
request worker. Both are deployed to the linked Nipto project. Neither claims a
scanner verdict, a completed export, or a finished deletion without a real
backend result.

## Deployed functions

| Function | Live version | JWT verification | Purpose |
|---|---:|---:|---|
| `nipto-media` | 2 | enabled | Authenticated media inspection and honest pending states |
| `nipto-privacy` | 2 | disabled (self-verifies) | User privacy routes plus a secret-protected worker route |

`nipto-privacy` must keep `verify_jwt = false` because its worker route has no
user JWT. The user routes validate the caller with `/auth/v1/user`; the worker
route requires the exact `CRON_SECRET` bearer token.

## Media validation

The app calls `POST /functions/v1/nipto-media/inspect` with a signed-in user JWT
and a JSON body:

~~~json
{ "bucket": "chat-media", "path": "chat-media/<conversation>/<owner>/<file>" }
~~~

The function re-checks the signed-in owner, the canonical path, object presence,
declared MIME type and size, computes SHA-256 over the downloaded bytes, and
verifies magic bytes. Results are written to `private.media_assets`:

- Images without an external scanner verdict become `needs_review`.
- Videos without a processor verdict become `processing`.
- Magic-byte or size mismatches become `rejected`.
- No code path invents a `clean` or `ready` verdict.

Staff approval uses
`public.staff_review_content(p_kind, p_id, p_decision, p_reason, p_override)`.
Approving without a `clean`/`ready` decision requires `p_override = true`, which
is recorded in the staff audit trail.

### Media cleanup scheduling

`private.nipto_media_cleanup(p_retention interval, p_pending_retention interval)`
is service-role only and removes expired media records and stale pending jobs.
There is no public HTTP route for it, and it lives in the `private` schema, so
PostgREST cannot call it from a client. A trusted scheduler with a server-side
database connection must invoke it:

~~~sql
select private.nipto_media_cleanup(interval '30 days', interval '7 days');
~~~

Never expose this function to `anon` or `authenticated`, and never place a
service-role key in Flutter. Scheduling is an operator task and is not yet
configured.

## Privacy requests

Signed-in users can call these routes with their Supabase user JWT:

- `POST /privacy/status` — current export/deletion requests.
- `POST /privacy/request` with `{"kind":"export"}` or `{"kind":"deletion"}`.
- `POST /privacy/cancel` — cancels a pending deletion inside the 14-day window.
- `POST /privacy/export-url` with `{"request_id":"<uuid>"}` — returns a signed
  URL only for a completed, unexpired export.

Exports are written to the private `privacy-exports` bucket at
`{user_id}/{request_id}.json` and expire after seven days. Deletion waits
fourteen days for cancellation, anonymizes retained audit/message attribution,
revokes all Nipto sessions and then hard-deletes the auth user.

### Privacy worker scheduling

`POST /privacy/worker/run` requires `Authorization: Bearer $CRON_SECRET` and
accepts an optional body `{"limit":5}` (1–10, default 5):

~~~bash
curl -X POST \
  -H "Authorization: Bearer $CRON_SECRET" \
  -H 'Content-Type: application/json' \
  -d '{"limit":5}' \
  'https://advmjribduqzyuwktkod.supabase.co/functions/v1/nipto-privacy/worker/run'
~~~

The worker claims due requests, creates/purges exports, anonymizes and deletes
accounts, and purges expired export objects. A missing `CRON_SECRET` returns
`503`; a wrong secret returns `401`. Store the secret only in Supabase secrets
and in the trusted scheduler's environment. The same `CRON_SECRET` can protect
the push dispatcher; no secret belongs in Flutter, Git, or a public cron URL.

## Verification checklist

- Unauthenticated `POST /nipto-media/inspect` returns `401`; unauthenticated
  `POST /privacy/status` returns `401`; unauthenticated `POST /privacy/worker/run`
  returns `401` (and `503` when `CRON_SECRET` is absent).
- Uploaded images/videos with valid magic bytes reach `needs_review`/`processing`;
  mismatched bytes reach `rejected` with an error code.
- Staff approval requires an explicit decision and records the override.
- An export request produces a scoped private object and a signed URL that stops
  working after its TTL; an expired export is purged by the worker.
- Deletion can be cancelled within 14 days; an uncancelled request anonymizes
  attribution, revokes sessions and removes the auth user.
- No email, phone, password, service-role key, or other credential appears in
  request bodies, export paths, or logs.

## Current status

Migrations, functions, grants, RLS and fail-closed probes are live and verified.
No external scanner/processor is configured, no worker schedule is configured,
and no end-to-end device/export/deletion run has been performed. Treat media
approval automation and privacy request fulfillment as gated until the checklist
passes with real operator credentials and test accounts.
