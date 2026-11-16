
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
  where auth.uid() is not null
    and n.recipient_id = auth.uid()
    and not exists (
      select 1
      from public.blocked_users b
      where (b.blocker_id = auth.uid() and b.blocked_id = n.actor_id)
         or (b.blocker_id = n.actor_id and b.blocked_id = auth.uid())
    )
  order by n.created_at desc
  limit 100;
$$;
revoke all on function public.list_my_notifications() from public, anon;
grant execute on function public.list_my_notifications() to authenticated;

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
  select
    p.id,
    p.nipto_id,
    p.display_name,
    case
      when p.is_private and not private.has_accepted_follow(auth.uid(), p.id) then ''
      else p.bio
    end,
    case
      when p.is_private and not private.has_accepted_follow(auth.uid(), p.id) then null
      else p.avatar_path
    end,
    p.is_private,
    f.created_at
  from public.follows f
  join public.profiles p
    on p.id = case when p_direction = 'followers' then f.follower_id else f.following_id end
  where auth.uid() is not null
    and p_direction in ('followers','following')
    and f.status = 'accepted'
    and (
      (p_direction = 'followers' and f.following_id = auth.uid())
      or (p_direction = 'following' and f.follower_id = auth.uid())
    )
    and not private.is_blocked_between(auth.uid(), p.id)
    and (
      not p.is_private
      or private.has_accepted_follow(auth.uid(), p.id)
      or p.id = auth.uid()
    )
  order by f.created_at desc
  limit 200;
$$;
revoke all on function public.list_my_connections(text) from public, anon;
grant execute on function public.list_my_connections(text) to authenticated;
