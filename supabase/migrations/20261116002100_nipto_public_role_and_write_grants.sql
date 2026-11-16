
-- Explicitly revoke role memberships inherited through the default PUBLIC role.
-- PUBLIC's historical table grants were the source of anon-level access.
revoke all privileges on all tables in schema public from public;
revoke all privileges on all sequences in schema public from public;
revoke all privileges on all tables in schema public from anon;
revoke all privileges on all sequences in schema public from anon;

-- Authenticated APIs do not need table-level DELETE on relationship-driven data.
-- The application uses RLS-scoped row deletes for follow, blocks, likes and content.
-- Grant only the SQL operations requested by the current Flutter screens.
grant insert on public.follows, public.blocked_users, public.close_friends to authenticated;
grant delete on public.follows, public.blocked_users, public.close_friends to authenticated;
grant insert on public.posts, public.post_likes, public.post_comments to authenticated;
grant delete on public.posts, public.post_likes, public.post_comments to authenticated;
grant insert on public.shorts, public.short_likes, public.short_comments to authenticated;
grant delete on public.shorts, public.short_likes, public.short_comments to authenticated;
grant insert on public.statuses, public.status_views to authenticated;
grant delete on public.statuses to authenticated;
grant insert on public.messages to authenticated;
grant delete on public.messages to authenticated;
grant insert on public.device_tokens to authenticated;
grant delete on public.device_tokens to authenticated;
grant insert on public.user_feedback, public.user_reports to authenticated;

-- Set preference rows at account startup; only user preference columns can then change.
grant insert on public.user_preferences to authenticated;
grant update (message_access, message_notifications, follow_notifications, status_notifications, short_notifications)
  on public.user_preferences to authenticated;

-- Existing notification records are created only by trusted database triggers.
revoke insert, delete on public.notifications from authenticated;
revoke insert, delete on public.message_receipts from authenticated;
