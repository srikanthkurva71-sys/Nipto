
-- User-owned connections and notifications are returned through bounded, owner-scoped RPCs.
create or replace function public.list_my_connections(p_direction text)
returns table (
  user_id uuid,
  nipto_id text,
  display_name text,
  bio text,
  avatar_path text,
  is_private boolean,
  connected_at timestamptz
)
language sql
stable
security definer
set search_path = ''
as $$
  select p.id, p.nipto_id, p.display_name, p.bio, p.avatar_path, p.is_private, f.created_at
  from public.follows f
  join public.profiles p
    on p.id = case when p_direction = 'followers' then f.follower_id else f.following_id end
  where auth.uid() is not null
    and f.status = 'accepted'
    and (
      (p_direction = 'followers' and f.following_id = auth.uid())
      or (p_direction = 'following' and f.follower_id = auth.uid())
    )
    and not private.is_blocked_between(auth.uid(), p.id)
  order by f.created_at desc
  limit 200;
$$;
revoke all on function public.list_my_connections(text) from public, anon;
grant execute on function public.list_my_connections(text) to authenticated;

create or replace function public.list_my_notifications()
returns table (
  id uuid,
  actor_id uuid,
  actor_nipto_id text,
  actor_display_name text,
  notification_type text,
  entity_id uuid,
  payload jsonb,
  read_at timestamptz,
  created_at timestamptz
)
language sql
stable
security definer
set search_path = ''
as $$
  select n.id, n.actor_id, p.nipto_id, p.display_name,
         n.notification_type, n.entity_id, n.payload, n.read_at, n.created_at
  from public.notifications n
  left join public.profiles p on p.id = n.actor_id
  where auth.uid() is not null and n.recipient_id = auth.uid()
  order by n.created_at desc
  limit 100;
$$;
revoke all on function public.list_my_notifications() from public, anon;
grant execute on function public.list_my_notifications() to authenticated;

create or replace function private.notify_follow_insert()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_enabled boolean;
  v_type text;
begin
  select coalesce(up.follow_notifications, true) into v_enabled
  from public.user_preferences up where up.user_id = new.following_id;
  if coalesce(v_enabled, true) then
    v_type := case when new.status = 'pending' then 'follow_request' else 'follow' end;
    insert into public.notifications (recipient_id, actor_id, notification_type, payload)
    values (
      new.following_id,
      new.follower_id,
      v_type,
      jsonb_build_object('follower_id', new.follower_id)
    );
  end if;
  return new;
end;
$$;
revoke all on function private.notify_follow_insert() from public, anon, authenticated;
create trigger follows_after_insert_notify
after insert on public.follows
for each row execute function private.notify_follow_insert();

create or replace function private.notify_follow_accept()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_enabled boolean;
begin
  if old.status <> 'pending' or new.status <> 'accepted' then return new; end if;
  select coalesce(up.follow_notifications, true) into v_enabled
  from public.user_preferences up where up.user_id = new.follower_id;
  if coalesce(v_enabled, true) then
    insert into public.notifications (recipient_id, actor_id, notification_type, payload)
    values (
      new.follower_id,
      new.following_id,
      'follow_accepted',
      jsonb_build_object('following_id', new.following_id)
    );
  end if;
  return new;
end;
$$;
revoke all on function private.notify_follow_accept() from public, anon, authenticated;
create trigger follows_after_accept_notify
after update of status on public.follows
for each row execute function private.notify_follow_accept();

create or replace function private.on_message_created()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  update public.conversations
  set updated_at = now()
  where id = new.conversation_id;

  insert into public.message_receipts (message_id, conversation_id, user_id)
  select new.id, new.conversation_id, cm.user_id
  from public.conversation_members cm
  where cm.conversation_id = new.conversation_id
    and cm.user_id <> new.sender_id
    and cm.membership_state = 'accepted'
  on conflict do nothing;

  insert into public.notifications (recipient_id, actor_id, notification_type, entity_id, payload)
  select cm.user_id, new.sender_id, 'message', new.id,
         jsonb_build_object('conversation_id', new.conversation_id)
  from public.conversation_members cm
  left join public.user_preferences up on up.user_id = cm.user_id
  where cm.conversation_id = new.conversation_id
    and cm.user_id <> new.sender_id
    and cm.membership_state = 'accepted'
    and coalesce(up.message_notifications, true);

  return new;
end;
$$;

create or replace function private.notify_short_like()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_creator uuid;
  v_enabled boolean;
begin
  select s.creator_id into v_creator from public.shorts s where s.id = new.short_id;
  if v_creator is null or v_creator = new.user_id then return new; end if;
  select coalesce(up.short_notifications, true) into v_enabled
  from public.user_preferences up where up.user_id = v_creator;
  if coalesce(v_enabled, true) then
    insert into public.notifications (recipient_id, actor_id, notification_type, entity_id, payload)
    values (v_creator, new.user_id, 'like', new.short_id, jsonb_build_object('content_type','short'));
  end if;
  return new;
end;
$$;
revoke all on function private.notify_short_like() from public, anon, authenticated;
create trigger short_likes_after_insert_notify
after insert on public.short_likes
for each row execute function private.notify_short_like();

create or replace function private.notify_short_comment()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_creator uuid;
  v_enabled boolean;
begin
  select s.creator_id into v_creator from public.shorts s where s.id = new.short_id;
  if v_creator is null or v_creator = new.author_id then return new; end if;
  select coalesce(up.short_notifications, true) into v_enabled
  from public.user_preferences up where up.user_id = v_creator;
  if coalesce(v_enabled, true) then
    insert into public.notifications (recipient_id, actor_id, notification_type, entity_id, payload)
    values (v_creator, new.author_id, 'comment', new.short_id, jsonb_build_object('content_type','short'));
  end if;
  return new;
end;
$$;
revoke all on function private.notify_short_comment() from public, anon, authenticated;
create trigger short_comments_after_insert_notify
after insert on public.short_comments
for each row execute function private.notify_short_comment();
