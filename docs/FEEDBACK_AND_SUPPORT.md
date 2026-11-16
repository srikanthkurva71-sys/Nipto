# Nipto Feedback and Support

## Purpose
Feedback is a first-class product subsystem. It is separate from safety reports:
- Feedback improves product quality and gathers feature ideas.
- Safety reports flag abuse, harassment, impersonation or unsafe content and use public.user_reports.

## Android user experience
The entry point is Settings → Help & Feedback → Feedback & support.

Users can submit:
- Category: app experience, problem/bug, feature idea, account/support.
- Optional 1–5 experience rating.
- Required short subject (3–100 characters).
- Required message (10–4,000 characters).

The screen shows the user's last 20 submissions and their status: received, reviewing, planned, resolved or closed.
The app never asks for a password, OTP or recovery secret in feedback.

## Data and authorization
public.user_feedback stores the authenticated user UUID, category, optional rating, subject, message, Android platform, status and creation time.

RLS rules:
- A signed-in user may insert only a row with their own user_id, Android platform and initial received status.
- A user may read only their own feedback.
- Client roles cannot update or delete feedback and cannot set staff workflow status.
- Feedback is not publicly visible and is not mixed into public.user_reports.

## Trusted staff workflow

The backend is implemented; the staff-facing review console is still pending.

- Staff identities live in `private.staff_roles`, outside the exposed public schema.
- Roles are `moderator` or `admin`; there are no staff accounts by default.
- The table is not readable by anonymous or authenticated client roles. Staff assignment must be performed by the trusted Supabase project owner through project controls, never by an Android client.
- `staff_can_access()` fails closed when a user has no active staff role.
- `staff_list_feedback()` and `staff_review_feedback()` provide bounded feedback triage and status/response updates.
- `staff_list_reports()` and `staff_review_report()` provide safety-report triage.
- `staff_list_pending_content()` and `staff_review_content()` provide pending post/Short review.
- All review operations write to the private `staff_action_log` audit table.
- User-facing status changes and responses are delivered through in-app notifications; the Feedback screen shows the user's own response.

Only trusted, appropriately assigned adult moderators should review safety reports and potentially distressing user-generated content. Do not assign a minor account to a moderation role.

## Remaining operations and release requirements
1. Build the role-gated staff console for an appropriately staffed operations team.
2. Define the staff identity verification and role-provisioning process, with separation of admin and moderator duties.
3. Add retention/deletion policy and an appeal/escalation workflow.
4. Test staff RPCs with no-role, moderator and admin sessions, and verify audit records.
5. Configure push delivery for feedback and report updates.

Never expose staff credentials or service-role keys in the Android app.