
-- Keep discovery useful without exposing private-account profile details.
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
  select
    p.id,
    p.nipto_id,
    p.display_name,
    case
      when p.is_private and not private.has_accepted_follow(auth.uid(), p.id) then ''
      else p.bio
    end as bio,
    case
      when p.is_private and not private.has_accepted_follow(auth.uid(), p.id) then null
      else p.avatar_path
    end as avatar_path,
    p.is_private
  from public.profiles p
  where auth.uid() is not null
    and length(trim(coalesce(p_query, ''))) >= 2
    and p.account_state = 'active'
    and p.nipto_id like (lower(trim(p_query)) || '%')
    and not private.is_blocked_between(auth.uid(), p.id)
    and p.id <> auth.uid()
  order by p.nipto_id
  limit least(greatest(coalesce(p_limit, 20), 1), 30);
$$;
revoke all on function public.search_profiles(text, integer) from public, anon;
grant execute on function public.search_profiles(text, integer) to authenticated;

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
    end as bio,
    case
      when p.is_private and not private.has_accepted_follow(auth.uid(), p.id) then null
      else p.avatar_path
    end as avatar_path,
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
  order by f.created_at desc
  limit 200;
$$;
revoke all on function public.list_my_connections(text) from public, anon;
grant execute on function public.list_my_connections(text) to authenticated;
