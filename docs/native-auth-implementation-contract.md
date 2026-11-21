# Native Nipto Authentication Implementation Contract

Status: implementation guidance; not a frozen architecture decision.

## Current verified design
- Nipto identity is handled by the custom OIDC provider hosted by the `nipto-identity` Edge Function.
- Flutter currently starts authentication through Supabase OAuth (`custom:nipto`).
- The provider supports authorization-code flow, PKCE S256, transaction state/nonce, CSRF checks, rate limiting, password hashing/verification, ID availability checks, and recovery infrastructure.
- Supabase Auth brokers the session used by app services. Do not bypass this or create client-side credential records.

## Native UI requirements
Registration fields:
- Display name
- Nipto ID (normalized to lowercase; 3–24 characters; valid ID grammar and reserved names rejected)
- Password
- Confirm password
- Optional recovery Nipto ID

Sign-in fields:
- Nipto ID
- Password

Registration UX:
- Debounced availability check through existing `POST /id/check`
- Show up to five backend suggestions when unavailable
- Do not reveal credential secrets in logs
- Password confirmation and password policy checks before submission
- Loading, retry, success and accessible error states

## Secure native session requirement
A native credential form must not simply call a password-verification endpoint and treat the result as an authenticated app session. It must complete an OAuth/OIDC authorization flow and obtain a real Supabase Auth session. The existing authorization-code + PKCE implementation is the supported session bridge unless a reviewed, tested alternative is added.

## Implementation sequence
1. Add native form widgets and validation.
2. Add ID-availability service wrapper with safe cancellation/debouncing at the UI layer.
3. Preserve browser/OIDC sign-in as a fallback.
4. Connect form submission to an OIDC-compatible native flow (not a password-only endpoint).
5. Add integration tests for ID check, registration, login, session restoration, recovery, legacy account migration, and failure handling.
6. Verify Android and Web builds and auth integration tests before declaring complete.

## Compatibility/security invariants
- Never store plaintext credentials or send passwords to client-visible logs.
- Never let the Flutter client write credential hashes directly to the database.
- Keep OIDC transaction state, nonce, CSRF, PKCE, rate limits, password hashing, and token verification on the server.
- Do not break existing Supabase user UUIDs, profiles, RLS, Realtime, Storage, chats, calls, or recovery.
- Keep browser authentication as a fallback.
- Do not change production schema or deployment settings without reviewed migrations and verification.
