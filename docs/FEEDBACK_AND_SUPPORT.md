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

## Operational workflow still required
The intake and user history are implemented. A trusted staff-only moderation/triage interface is not yet implemented. Before launch, add:
1. Staff identity/role assignment outside client-controlled profile fields.
2. A staff-only queue for received/reviewing feedback.
3. Audited status changes and internal notes, separate from user-visible message text.
4. Response/notification workflow when a submission is resolved or needs clarification.
5. Retention and deletion policy for feedback records.

Never expose staff credentials or service-role keys in the Android app.