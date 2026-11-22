# Nipto Account Recovery Protocol

Status: protocol specification; recovery password reset is **not enabled** until the redemption service is implemented and security-tested.

## Goals

- Recovery remains optional and Nipto-to-Nipto. No email, phone number, or third-party identity provider is required.
- A recovery contact must explicitly accept the relationship.
- Knowing a Nipto ID or being an accepted recovery contact must never be enough to reset an account.
- Recovery authorizations are short-lived, single-use, and rate-limited.
- Responses should not reveal whether a target account exists.

## Threat model

Protect against someone who knows the target Nipto ID, can create repeated requests, or can access a recovery-contact account without being authorized to perform a password reset. Do not treat a recovery-contact approval as proof that the account owner is present.

## Required protocol before implementation

1. **Initiation:** unauthenticated user submits their Nipto ID and a high-entropy recovery secret/code created by the recovery service. Responses must be generic to avoid account enumeration.
2. **Approval:** notify the accepted recovery contact. The recovery-contact owner must authenticate normally and explicitly approve a specific recovery attempt. Approval must be bound to that attempt, target account, and expiry.
3. **Proof delivery:** approval generates a high-entropy one-time proof. The recovery contact must communicate this proof to the account owner through a separate trusted channel. Nipto must not expose the proof to the initiating browser/device or return it in an unauthenticated API response.
4. **Redeem:** the account owner submits Nipto ID, proof, and a new password. The server hashes the proof, checks target binding, expiry, attempt limits, and unused status, then atomically consumes the proof and updates the Supabase Auth password. The operation must be single-use even under concurrent requests.
5. **Invalidation:** invalidate existing sessions/refresh tokens where supported, expire pending attempts, and record a minimal security audit event. Notify the recovery contact and target account through authenticated notification channels.
6. **Abuse controls:** per-account, per-IP, and per-attempt rate limits; generic failure messages; strict input limits; no raw proof in logs; short expiry; and no reusable authorization.

## Data handling

- Store only a cryptographic hash of the one-time proof (SHA-256 or stronger keyed hash where appropriate); never store plaintext proof.
- Use cryptographically secure random bytes for proof generation.
- Bind each proof to a single target user and recovery request.
- Require atomic redemption (row lock or equivalent) to prevent double-use.
- Use a server-only service role for privileged Auth Admin password updates. Never expose service-role credentials to Flutter.
- Keep recovery attempt metadata minimal and access-controlled. Enable RLS and revoke client table access.

## Recovery contact management

- Only one selected pending/accepted recovery contact at a time.
- Both accounts must be active and not blocked.
- Recovery contact approval/rejection is authenticated and scoped to the recovery-contact owner.
- Removal by either party revokes the relationship for future recovery.
- Approval must not silently renew or create additional recovery relationships.

## Implementation acceptance criteria

- [ ] Edge Functions for initiation, recovery-contact approval, and redemption.
- [ ] Proof is random, hashed at rest, bound to the target, and expires within a short fixed window (recommended 15 minutes).
- [ ] Proof is revealed only to the recovery contact through an authenticated session and is never returned to the unauthenticated requester.
- [ ] Redemption uses atomic single-use consumption and password update.
- [ ] Existing sessions are invalidated or revoked as supported by Supabase Auth.
- [ ] Generic responses prevent Nipto-ID enumeration.
- [ ] Rate limits apply independently to initiation, approval, and redemption.
- [ ] Tests cover expired, invalid, reused, wrong-target, concurrent, blocked, and rate-limited attempts.
- [ ] Flutter recovery UI explains the separate-channel proof step and never requests email/phone.
- [ ] Supabase migration and Edge Function deployment are verified in a non-production environment before rollout.

## Current state

The consent-based recovery-contact request/accept/reject/remove database functions and notifications already exist. The password-reset authorization and redemption service is not yet implemented. Keep recovery disabled in the UI until all acceptance criteria above are satisfied.
