
-- Migration 20261116002100 intentionally granted table-wide INSERT for the
-- tables used by the Flutter client. That re-opened server-owned columns which
-- migrations 20261116001600 and 20261116002000 had protected with column-level
-- grants: clients could supply ids, timestamps, expiry values and moderation
-- fields even though the RLS policies could not authorize those writes.
--
-- Revoke only the table-wide INSERT privilege. Column-level INSERT grants are
-- separate privileges in Postgres, so the explicit lists below remain in
-- force, and columns with defaults continue to work when omitted.

revoke insert on public.follows, public.blocked_users, public.close_friends from authenticated;
revoke insert on public.posts, public.post_likes, public.post_comments from authenticated;
revoke insert on public.shorts, public.short_likes, public.short_comments from authenticated;
revoke insert on public.statuses, public.status_views from authenticated;
revoke insert on public.messages from authenticated;
revoke insert on public.device_tokens from authenticated;
revoke insert on public.user_feedback, public.user_reports from authenticated;
revoke insert on public.user_preferences from authenticated;

grant insert (follower_id, following_id) on public.follows to authenticated;
grant insert (blocker_id, blocked_id) on public.blocked_users to authenticated;
grant insert (owner_id, friend_id) on public.close_friends to authenticated;

grant insert (author_id, caption, media_path, media_type, visibility)
  on public.posts to authenticated;
grant insert (post_id, user_id) on public.post_likes to authenticated;
grant insert (post_id, author_id, body) on public.post_comments to authenticated;

grant insert (creator_id, video_path, thumbnail_path, caption, duration_seconds, visibility)
  on public.shorts to authenticated;
grant insert (short_id, user_id) on public.short_likes to authenticated;
grant insert (short_id, author_id, body) on public.short_comments to authenticated;

grant insert (owner_id, status_type, text_content, media_path, background_color, visibility)
  on public.statuses to authenticated;
grant insert (status_id, viewer_id) on public.status_views to authenticated;

grant insert (conversation_id, sender_id, message_type, body, media_path, reply_to_id)
  on public.messages to authenticated;

grant insert (user_id, token, platform) on public.device_tokens to authenticated;

grant insert (user_id, category, rating, subject, message, platform)
  on public.user_feedback to authenticated;
grant insert (reporter_id, reported_user_id, content_type, content_id, reason, details)
  on public.user_reports to authenticated;

grant insert (user_id, message_access, message_notifications, follow_notifications, status_notifications, short_notifications)
  on public.user_preferences to authenticated;

-- list_my_notifications returns the whole inbox newest-first, not only unread
-- rows. The old partial index cannot serve that ordering.
create index if not exists notifications_inbox_all_idx
  on public.notifications (recipient_id, created_at desc);

comment on table public.user_feedback is
  'Product feedback submitted by authenticated Nipto Android users. Clients cannot supply moderation state, staff notes or created_at.';
comment on table public.user_reports is
  'User reports submitted by authenticated Nipto members. Clients cannot supply moderation state, reviewer, review timestamp or created_at.';

-- Search input is interpolated into a LIKE prefix. Escape wildcard characters
-- so a query such as "%" cannot enumerate every active profile.
create or replace function public.search_profiles(p_query text, p_limit integer default 20)
returns table (
  id uuid,
  nipto_id text,
  display_name text,
  bio text,
  avatar_path text,
  is_private boolean
)
language sql
stable
security definer
set search_path = ''
as $$
  with input as (
    select replace(
      replace(
        replace(lower(trim(p_query)), '!', '!!'),
        '%',
        '!%'
      ),
      '_',
      '!_'
    ) as prefix
  )
  select
    p.id,
    p.nipto_id,
    p.display_name,
    case
      when not p.is_private or private.has_accepted_follow(auth.uid(), p.id) or p.id = auth.uid()
      then p.bio
      else ''
    end,
    case
      when not p.is_private or private.has_accepted_follow(auth.uid(), p.id) or p.id = auth.uid()
      then p.avatar_path
      else null
    end,
    p.is_private
  from public.profiles p
  cross join input i
  where auth.uid() is not null
    and p.account_state = 'active'
    and (
      lower(p.nipto_id) like (i.prefix || '%') escape '!'
      or lower(p.display_name) like (i.prefix || '%') escape '!'
    )
    and not private.is_blocked_between(auth.uid(), p.id)
    and p.id <> auth.uid()
  order by p.nipto_id
  limit least(greatest(coalesce(p_limit, 20), 1), 30);
$$;
