
-- Revoke broad row-level write grants and re-grant only user-editable columns.
-- This prevents clients from changing identity keys, moderation decisions,
-- ownership, timestamps, message routing or private media object references.

revoke insert, update on public.profiles from authenticated;
grant update (display_name, bio, avatar_path, is_private, updated_at)
  on public.profiles to authenticated;

revoke insert, update on public.follows from authenticated;
grant insert (follower_id, following_id) on public.follows to authenticated;
grant update (status, updated_at) on public.follows to authenticated;

revoke insert, update on public.conversations from authenticated;
grant update (title, updated_at) on public.conversations to authenticated;

revoke insert, update on public.messages from authenticated;
grant insert (conversation_id, sender_id, message_type, body, media_path, reply_to_id)
  on public.messages to authenticated;
grant update (body, edited_at, deleted_at) on public.messages to authenticated;

revoke insert, update on public.message_receipts from authenticated;
grant insert (message_id, conversation_id, user_id) on public.message_receipts to authenticated;
grant update (delivered_at, read_at) on public.message_receipts to authenticated;

revoke insert, update on public.statuses from authenticated;
grant insert (owner_id, status_type, text_content, media_path, background_color, visibility)
  on public.statuses to authenticated;
-- Statuses are immutable after creation; owners may delete them.

revoke insert, update on public.status_views from authenticated;
grant insert (status_id, viewer_id) on public.status_views to authenticated;

revoke insert, update on public.posts from authenticated;
grant insert (author_id, caption, media_path, media_type, visibility)
  on public.posts to authenticated;
grant update (caption, visibility, updated_at) on public.posts to authenticated;

revoke insert, update on public.post_likes from authenticated;
grant insert (post_id, user_id) on public.post_likes to authenticated;

revoke insert, update on public.post_comments from authenticated;
grant insert (post_id, author_id, body) on public.post_comments to authenticated;

revoke insert, update on public.shorts from authenticated;
grant insert (creator_id, video_path, thumbnail_path, caption, duration_seconds, visibility)
  on public.shorts to authenticated;
grant update (caption, visibility) on public.shorts to authenticated;

revoke insert, update on public.short_likes from authenticated;
grant insert (short_id, user_id) on public.short_likes to authenticated;

revoke insert, update on public.short_comments from authenticated;
grant insert (short_id, author_id, body) on public.short_comments to authenticated;

revoke insert, update on public.blocked_users from authenticated;
grant insert (blocker_id, blocked_id) on public.blocked_users to authenticated;

revoke insert, update on public.close_friends from authenticated;
grant insert (owner_id, friend_id) on public.close_friends to authenticated;

revoke insert, update on public.device_tokens from authenticated;
grant insert (user_id, token, platform) on public.device_tokens to authenticated;
grant update (token, updated_at) on public.device_tokens to authenticated;

revoke insert, update, delete on public.user_feedback from authenticated;
grant insert (user_id, category, rating, subject, message, platform)
  on public.user_feedback to authenticated;
grant select on public.user_feedback to authenticated;

revoke insert, update, delete on public.user_reports from authenticated;
grant insert (reporter_id, reported_user_id, content_type, content_id, reason, details)
  on public.user_reports to authenticated;
grant select on public.user_reports to authenticated;
