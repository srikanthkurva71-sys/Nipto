# Native Nipto Authentication Session Bridge

Status: proposal for review; not a frozen architecture decision.

## Objective
Allow Flutter to present native Nipto ID/password screens while preserving the existing custom OIDC authorization-code + PKCE flow and Supabase Auth session broker.

## Non-negotiable invariants
- Never treat a successful password-check API response as an app session.
- Never return a Supabase service-role key, OIDC client secret, signing key, or password hash to the client.
- Do not write credential hashes from Flutter.
- Preserve user UUIDs, RLS, Storage, Realtime, and existing identity-linking behavior.
- Passwords must never be logged or included in analytics, crash reports, URL query strings, or persistent client storage.
- Browser/hosted OIDC authentication remains available as a fallback until the native flow is verified.

## Current boundary
The existing provider owns credential verification and the OIDC transaction. Flutter currently starts the provider through `signInWithOAuth(OAuthProvider('custom:nipto'))`. The current ID-availability API is advisory; registration must re-check availability atomically server-side.

## Flow option to evaluate
A native form may submit Nipto ID, password, display name, optional recovery Nipto ID, and a PKCE challenge to a server endpoint. The server must create a short-lived, one-time authorization transaction and return only the authorization URL/transaction identifier needed for the next step. Flutter then completes the existing Supabase OAuth callback/session exchange through supported Supabase Auth APIs. Any design that bypasses the Supabase Auth callback must be rejected unless it is formally reviewed and independently verifies token claims, signature, issuer, audience, expiry, nonce, PKCE, and one-time code consumption.

## Required abuse protections
- Rate limits for both account/IP dimensions, including ID availability checks.
- Generic login failure responses to avoid account enumeration.
- Strict request size and content-type checks.
- Argon2id or another reviewed password-hashing scheme on the server.
- CSRF/state, nonce, PKCE S256, short-lived authorization codes, and one-time consumption.
- Reserved-ID and normalization checks shared across UI and backend.
- Server-side uniqueness enforcement for IDs and recovery links.
- Security event logging that excludes passwords, tokens, codes, and recovery secrets.

## Acceptance tests before integration
1. Registration creates one identity and one Supabase user without exposing credential material.
2. Duplicate ID race returns a safe conflict and no partial account.
3. Native login returns a valid Supabase Auth session only after the full OIDC flow.
4. Wrong password and unknown ID produce indistinguishable public errors.
5. PKCE mismatch, nonce mismatch, expired code, replayed code, and altered state fail.
6. Session restore and local/global sign-out work.
7. Legacy identity migration preserves the original user UUID and app data.
8. Recovery grant is one-time and cannot be used to sign in directly.
9. Android and Web callback paths both work.
10. Flutter unit/widget/integration tests and server tests pass before release.

## Rollout
Keep native form behind an explicit feature flag until all acceptance tests pass. Do not replace the hosted flow by default before verification.
