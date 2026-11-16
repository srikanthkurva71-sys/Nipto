
-- Remove inherited broad grants from Supabase API roles.
-- RLS remains enabled; these grants define which SQL operations a client can attempt.
revoke all privileges on all tables in schema public from anon;
revoke all privileges on all tables in schema public from authenticated;

-- Authenticated users receive read access to social objects; writes are deliberately narrow.
grant select on
  public.profiles,
  public.follows,
  public.blocked_users,
  public.close_friends,
  public.conversations,
  public.conversation_members,
  public.messages,
  public.message_receipts,
  public.statuses,
  public.status_views,
  public.posts,
  public.post_likes,
  public.post_comments,
  public.shorts,
  public.short_likes,
  public.short_comments,
  public.notifications,
  public.device_tokens,
  public.user_reports,
  public.user_preferences,
  public.user_feedback
to authenticated;

-- User-owned CRUD tables with policies that scope each row.
grant insert, delete on public.follows, public.blocked_users, public.close_friends to authenticated;
grant update (status) on public.follows to authenticated;

grant update (display_name, bio, avatar_path, is_private) on public.profiles to authenticated;

grant update (title) on public.conversations to authenticated;

grant insert (conversation_id, sender_id, message_type, body, media_path, reply_to_id)
  on public.messages to authenticated;
grant update (body, edited_at, deleted_at) on public.messages to authenticated;
grant delete on public.messages to authenticated;

grant update (delivered_at, read_at) on public.message_receipts to authenticated;

grant insert (owner_id, status_type, text_content, media_path, background_color, visibility)
  on public.statuses to authenticated;
grant delete on public.statuses to authenticated;

grant insert (status_id, viewer_id) on public.status_views to authenticated;

grant insert (author_id, caption, media_path, media_type, visibility)
  on public.posts to authenticated;
grant update (caption, visibility) on public.posts to authenticated;
grant delete on public.posts to authenticated;

grant insert (post_id, user_id) on public.post_likes to authenticated;
grant delete on public.post_likes to authenticated;
grant insert (post_id, author_id, body) on public.post_comments to authenticated;
grant delete on public.post_comments to authenticated;

grant insert (creator_id, video_path, thumbnail_path, caption, duration_seconds, visibility)
  on public.shorts to authenticated;
grant update (caption, visibility) on public.shorts to authenticated;
grant delete on public.shorts to authenticated;

grant insert (short_id, user_id) on public.short_likes to authenticated;
grant delete on public.short_likes to authenticated;
grant insert (short_id, author_id, body) on public.short_comments to authenticated;
grant delete on public.short_comments to authenticated;

grant update (read_at) on public.notifications to authenticated;

grant insert (user_id, token, platform) on public.device_tokens to authenticated;
grant update (token) on public.device_tokens to authenticated;
grant delete on public.device_tokens to authenticated;

grant insert (user_id, category, rating, subject, message, platform)
  on public.user_feedback to authenticated;
grant insert (reporter_id, reported_user_id, content_type, content_id, reason, details)
  on public.user_reports to authenticated;

grant insert (user_id, message_access, message_notifications, follow_notifications, status_notifications, short_notifications)
  on public.user_preferences to authenticated;
grant update (message_access, message_notifications, follow_notifications, status_notifications, short_notifications)
  on public.user_preferences to authenticated;

-- Keep public identity lookup functions non-executable by anonymous and PUBLIC roles.
revoke all on function public.resolve_nipto_login(text) from public, anon, authenticated;
grant execute on function public.resolve_nipto_login(text) to service_role;
