
-- Client roles may acknowledge a notification, but cannot rewrite notification identity or payload.
revoke update on public.notifications from authenticated;
grant update (read_at) on public.notifications to authenticated;

-- Preferences are mutable, but their user_id ownership key is immutable to clients.
revoke update on public.user_preferences from authenticated;
grant update (
  message_access,
  message_notifications,
  follow_notifications,
  status_notifications,
  short_notifications,
  updated_at
) on public.user_preferences to authenticated;
