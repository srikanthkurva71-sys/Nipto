# Nipto credential setup

This runbook sets the private credentials Nipto needs for real push delivery and
calls. It keeps every secret value out of Git, out of Flutter assets, and out of
chat. The helper script writes only to ignored local files:

- `.env.supabase.local` — server-side secrets pushed to Supabase Edge Functions.
- `.env.firebase.local` — client-safe Firebase identifiers used as Flutter
  `--dart-define` values.
- `mobile/app/android/app/google-services.json` — generated Android tree, already
  gitignored.
- `deploy/turn/.env` — coturn host configuration, already gitignored.

Never commit those files. Never paste a private key, service-account JSON,
worker secret, TURN shared secret, or service-role key into chat.

## Current state

The Nipto OIDC client secret and private signing JWK are already configured as
Supabase Edge Function secrets and must not be regenerated unless you are
intentionally rotating them. The missing credentials are:

1. `CRON_SECRET` — shared worker secret for push and privacy workers.
2. `FCM_SERVICE_ACCOUNT_JSON` — Firebase service account for FCM HTTP v1.
3. Firebase Android app values — client identifiers for the Flutter build.
4. TURN realm, host, and shared secret — needed only for live calls.

## 1. Generate and upload the worker secret

Run from `C:\Nipto`:

~~~powershell
python scripts/setup_nipto_credentials.py worker-secret
python scripts/setup_nipto_credentials.py push
python scripts/setup_nipto_credentials.py check
~~~

`worker-secret` creates a cryptographically random `CRON_SECRET` in
`.env.supabase.local` and prints only a short fingerprint. `push` sends it to the
linked Supabase project with the Supabase CLI. `check` prints only secret names,
never values.

If you ever rotate this secret, also update the trusted scheduler that invokes
the workers. Use `--force` only when you intentionally want a new secret:

~~~powershell
python scripts/setup_nipto_credentials.py worker-secret --force
python scripts/setup_nipto_credentials.py push
~~~

## 2. Create the Firebase Android app

1. Open the [Firebase console](https://console.firebase.google.com/).
2. Create a new Firebase project, or select an existing one you control.
3. In Project overview, choose **Add app** → **Android**.
4. Enter the exact package name: `com.nipto.nipto`. It is case-sensitive and
   cannot be changed later in Firebase.
5. Register the app. An app nickname such as `Nipto Android` is fine.
6. Download `google-services.json`. If the browser adds a suffix such as
   `google-services (1).json`, rename it before importing.
7. Run the Nipto importer with the downloaded file path:

   ~~~powershell
   python scripts/setup_nipto_credentials.py import-google-services "C:\Users\PC\Downloads\google-services.json"
   ~~~

The importer validates that the file contains `com.nipto.nipto`, copies it to
the ignored generated Android tree, and writes the client-safe build defines to
`.env.firebase.local`.

If the generated Android platform tree is missing, recreate it first:

~~~powershell
cd mobile/app
flutter create --platforms=android,web --org com.nipto --project-name nipto .
cd ..\..
python scripts/setup_nipto_credentials.py import-google-services "C:\Users\PC\Downloads\google-services.json"
~~~

## 3. Create the FCM service account

1. In the same Firebase project, open **Project settings** → **Service accounts**.
2. Confirm the Firebase Admin SDK service account exists. Firebase creates it by
   default when the project is created.
3. Click **Generate new private key**, then **Generate Key**. Firebase downloads
   a JSON file containing a private key.
4. Store the downloaded JSON in a secure local location. Do not open it in a
   browser, do not add it to Git, and do not paste it into chat.
5. Import it with the Nipto helper:

   ~~~powershell
   python scripts/setup_nipto_credentials.py import-service-account "C:\Users\PC\Downloads\nipto-firebase-adminsdk-key.json"
   python scripts/setup_nipto_credentials.py push
   python scripts/setup_nipto_credentials.py check
   ~~~

The helper validates that the file is a Google service-account key, minifies it
into `.env.supabase.local`, and uploads it as `FCM_SERVICE_ACCOUNT_JSON`. The
push Edge Function mints short-lived OAuth tokens from it; no service-account
key reaches Flutter.

If a service-account key is ever pasted into chat, a ticket, or a log, treat it
as compromised. Revoke that key in the Firebase console and generate a new one.
The local helper can upload a fresh key from a file, but it cannot create or
revoke Google Cloud keys when the Firebase Admin SDK service account lacks IAM
API permissions.

## 4. Build with push enabled

Client Firebase identifiers are public, but Nipto only enables Firebase when
they are supplied at build time. Use the local env file, which avoids printing
values in shell history:

~~~powershell
cd mobile/app
flutter clean
flutter pub get
flutter create --platforms=android,web --org com.nipto --project-name nipto .
python ..\..\scripts\configure_android_platform.py
flutter build apk --debug --dart-define-from-file=..\..\.env.firebase.local
~~~

`configure_android_platform.py` enables the Google Services Gradle plugin only
when `google-services.json` is present. Without the local files, builds still
work but push initialization is a no-op.

## 5. Verify the workers fail closed, then invoke them

With `CRON_SECRET` set, unauthenticated worker requests must return `401`, not
`503`:

~~~powershell
curl -i -X POST "https://advmjribduqzyuwktkod.supabase.co/functions/v1/nipto-push-dispatch/worker/run"
curl -i -X POST -H "Content-Type: application/json" -d "{""limit"":1}" "https://advmjribduqzyuwktkod.supabase.co/functions/v1/nipto-privacy/worker/run"
~~~

To invoke with the secret kept in the local env file:

~~~powershell
$secret = (Select-String -Path ..\..\.env.supabase.local -Pattern '^CRON_SECRET=').Line.Split('=',2)[1].Trim("'")
curl -i -X POST -H "Authorization: Bearer $secret" "https://advmjribduqzyuwktkod.supabase.co/functions/v1/nipto-push-dispatch/worker/run"
~~~

Do not echo `$secret`. Do not put it in a URL query string.

## 6. TURN credentials for calls

Calls need a host you control. Nipto does not use a public third-party TURN
relay. You need a Linux host, DNS name, public IP, TLS certificate files at
`deploy/turn/certs/fullchain.pem` and `privkey.pem`, and firewall rules for
3478/5349 plus UDP 49160–49200.

Once those exist:

1. Generate a long random shared secret and keep it only in your password
   manager and the local env files.
2. Import it with the helper:

   ~~~powershell
   python scripts/setup_nipto_credentials.py import-turn `
     --realm turn.yourdomain.example `
     --public-ip YOUR_SERVER_PUBLIC_IP `
     --shared-secret YOUR_LONG_RANDOM_SECRET `
     --urls "turn:turn.yourdomain.example:3478,turns:turn.yourdomain.example:5349?transport=tcp" `
     --stun-url "stun:turn.yourdomain.example:3478"
   python scripts/setup_nipto_credentials.py push
   ~~~

3. Copy the `deploy/turn/` directory to the host, place the TLS certs in
   `certs/`, and start coturn with `docker compose up -d`.
4. From a signed-in client, call the authenticated
   `/nipto-identity/turn-credentials` route and confirm `turn_available` is
   `true`. The app receives only a one-hour credential; the shared secret never
   leaves the server.

## What still requires your private access

This helper cannot create a Firebase project, download files from the Firebase
console, create your DNS record, install your TLS certificate, or configure your
scheduler. Those steps must be done by someone with access to those accounts.
Everything after the files exist is handled by the script and the deployed
backend.
