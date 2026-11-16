
-- Nipto Social v1 hardening: least-privilege writes, private policy helpers and auth rate limiting.
create schema if not exists private;
revoke all on schema private from public, anon;
grant usage on schema private to authenticated, service_role;

-- Move trigger/policy helpers out of the PostgREST-exposed public schema.
alter function public.handle_new_nipto_user() set schema private;
alter function public.is_blocked_between(uuid, uuid) set schema private;
alter function public.has_accepted_follow(uuid, uuid) set schema private;
alter function public.can_view_profile(uuid) set schema private;
alter function public.is_conversation_member(uuid) set schema private;
alter function public.can_view_status(uuid) set schema private;
alter function public.can_view_short(uuid) set schema private;
alter function public.can_view_post(uuid) set schema private;
alter function public.set_updated_at() set schema private;

create or replace function private.handle_new_nipto_user()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_nipto_id text;
  v_display_name text;
begin
  v_nipto_id := lower(coalesce(new.raw_user_meta_data ->> 'nipto_id', ''));
  v_display_name := nullif(trim(coalesce(new.raw_user_meta_data ->> 'display_name', '')), '');
  if v_nipto_id !~ '^[a-z0-9_]{3,24}$'
     or v_nipto_id in ('admin','administrator','support','help','nipto','official','security','moderator') then
    raise exception 'A valid Nipto ID is required';
  end if;
  insert into public.profiles (id, nipto_id, display_name)
  values (new.id, v_nipto_id, coalesce(v_display_name, v_nipto_id));
  return new;
end;
$$;

create or replace function private.is_blocked_between(p_user_a uuid, p_user_b uuid)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select exists (
    select 1 from public.blocked_users b
    where (b.blocker_id = p_user_a and b.blocked_id = p_user_b)
       or (b.blocker_id = p_user_b and b.blocked_id = p_user_a)
  );
$$;

create or replace function private.has_accepted_follow(p_follower uuid, p_following uuid)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select exists (
    select 1 from public.follows f
    where f.follower_id = p_follower and f.following_id = p_following and f.status = 'accepted'
  );
$$;

create or replace function private.can_view_profile(p_profile_id uuid)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select auth.uid() = p_profile_id
    or (
      auth.uid() is not null
      and not private.is_blocked_between(auth.uid(), p_profile_id)
      and exists (
        select 1 from public.profiles p
        where p.id = p_profile_id and p.account_state = 'active'
          and (not p.is_private or private.has_accepted_follow(auth.uid(), p_profile_id))
      )
    );
$$;

create or replace function private.is_conversation_member(p_conversation_id uuid)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select auth.uid() is not null and exists (
    select 1 from public.conversation_members cm
    where cm.conversation_id = p_conversation_id and cm.user_id = auth.uid()
  );
$$;

create or replace function private.can_view_status(p_status_id uuid)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select exists (
    select 1 from public.statuses s
    join public.profiles owner_profile on owner_profile.id = s.owner_id
    where s.id = p_status_id and s.expires_at > now()
      and not private.is_blocked_between(auth.uid(), s.owner_id)
      and (
        s.owner_id = auth.uid()
        or (s.visibility = 'public' and not owner_profile.is_private)
        or (s.visibility = 'followers' and private.has_accepted_follow(auth.uid(), s.owner_id))
        or (s.visibility = 'close_friends' and exists (
          select 1 from public.close_friends cf
          where cf.owner_id = s.owner_id and cf.friend_id = auth.uid()
        ))
      )
  );
$$;

create or replace function private.can_view_short(p_short_id uuid)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select exists (
    select 1 from public.shorts s
    join public.profiles creator on creator.id = s.creator_id
    where s.id = p_short_id and s.moderation_state = 'approved'
      and not private.is_blocked_between(auth.uid(), s.creator_id)
      and (
        s.creator_id = auth.uid()
        or (s.visibility = 'public' and not creator.is_private)
        or (s.visibility = 'followers' and private.has_accepted_follow(auth.uid(), s.creator_id))
      )
  );
$$;

create or replace function private.can_view_post(p_post_id uuid)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select exists (
    select 1 from public.posts p
    join public.profiles owner_profile on owner_profile.id = p.author_id
    where p.id = p_post_id and p.moderation_state = 'approved'
      and not private.is_blocked_between(auth.uid(), p.author_id)
      and (
        p.author_id = auth.uid()
        or (p.visibility = 'public' and not owner_profile.is_private)
        or (p.visibility = 'followers' and private.has_accepted_follow(auth.uid(), p.author_id))
      )
  );
$$;

-- Use a trigger so the client cannot mark a follow to a private account as accepted.
create or replace function private.assign_follow_status()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_private boolean;
  v_state text;
begin
  select p.is_private, p.account_state into v_private, v_state
  from public.profiles p where p.id = new.following_id;
  if not found or v_state <> 'active' then
    raise exception 'Account is unavailable';
  end if;
  if private.is_blocked_between(new.follower_id, new.following_id) then
    raise exception 'This account is unavailable';
  end if;
  new.status := case when v_private then 'pending' else 'accepted' end;
  return new;
end;
$$;
create trigger follows_assign_status before insert on public.follows
for each row execute function private.assign_follow_status();

drop policy "follows_create_self" on public.follows;
create policy "follows_create_self" on public.follows for insert to authenticated
with check (
  follower_id = (select auth.uid())
  and not private.is_blocked_between(follower_id, following_id)
  and exists (
    select 1 from public.profiles target
    where target.id = following_id and target.account_state = 'active'
      and ((target.is_private and status = 'pending') or (not target.is_private and status = 'accepted'))
  )
);

-- Restrict users to editable profile fields; IDs and moderation state are server-owned.
revoke update on public.profiles from authenticated;
grant update (display_name, bio, avatar_path, is_private) on public.profiles to authenticated;

-- Messages may only be edited/deleted, never reassigned to another sender or conversation.
revoke update on public.messages from authenticated;
grant update (body, edited_at, deleted_at) on public.messages to authenticated;

-- Prevent user uploads from approving their own posts or short videos.
revoke update on public.posts from authenticated;
grant update (caption, media_path, media_type, visibility) on public.posts to authenticated;
revoke update on public.shorts from authenticated;
grant update (video_path, thumbnail_path, caption, duration_seconds, visibility) on public.shorts to authenticated;

-- Server-owned expiry and ownership fields cannot be rewritten by a status owner.
revoke update on public.statuses from authenticated;
grant update (status_type, text_content, media_path, background_color, visibility) on public.statuses to authenticated;

-- Group metadata can be edited, but membership and conversation identity cannot.
revoke update on public.conversations from authenticated;
grant update (title) on public.conversations to authenticated;

-- Private schema policy helpers are callable by authenticated queries/policies but are not exposed by PostgREST.
revoke all on function private.handle_new_nipto_user() from public, anon, authenticated;
revoke all on function private.is_blocked_between(uuid, uuid) from public, anon, authenticated;
revoke all on function private.has_accepted_follow(uuid, uuid) from public, anon, authenticated;
revoke all on function private.can_view_profile(uuid) from public, anon, authenticated;
revoke all on function private.is_conversation_member(uuid) from public, anon, authenticated;
revoke all on function private.can_view_status(uuid) from public, anon, authenticated;
revoke all on function private.can_view_short(uuid) from public, anon, authenticated;
revoke all on function private.can_view_post(uuid) from public, anon, authenticated;
revoke all on function private.assign_follow_status() from public, anon, authenticated;
revoke all on function private.set_updated_at() from public, anon, authenticated;
grant execute on function private.is_blocked_between(uuid, uuid) to authenticated;
grant execute on function private.has_accepted_follow(uuid, uuid) to authenticated;
grant execute on function private.can_view_profile(uuid) to authenticated;
grant execute on function private.is_conversation_member(uuid) to authenticated;
grant execute on function private.can_view_status(uuid) to authenticated;
grant execute on function private.can_view_short(uuid) to authenticated;
grant execute on function private.can_view_post(uuid) to authenticated;

create or replace function public.search_profiles(p_query text, p_limit integer default 20)
returns table (id uuid, nipto_id text, display_name text, bio text, avatar_path text, is_private boolean)
language sql
stable
security definer
set search_path = ''
as $$
  select p.id, p.nipto_id, p.display_name, p.bio, p.avatar_path, p.is_private
  from public.profiles p
  where auth.uid() is not null and p.account_state = 'active'
    and p.nipto_id like (lower(trim(p_query)) || '%')
    and not private.is_blocked_between(auth.uid(), p.id)
    and p.id <> auth.uid()
  order by p.nipto_id
  limit least(greatest(coalesce(p_limit, 20), 1), 30);
$$;

create or replace function public.create_or_get_direct_conversation(p_other_user uuid)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_me uuid := auth.uid();
  v_a uuid;
  v_b uuid;
  v_conversation_id uuid;
begin
  if v_me is null then raise exception 'Authentication required'; end if;
  if p_other_user is null or p_other_user = v_me then raise exception 'Invalid recipient'; end if;
  if private.is_blocked_between(v_me, p_other_user) then raise exception 'This conversation is unavailable'; end if;
  if not exists (select 1 from public.profiles p where p.id = p_other_user and p.account_state = 'active') then
    raise exception 'User not found';
  end if;
  v_a := least(v_me, p_other_user);
  v_b := greatest(v_me, p_other_user);
  insert into public.conversations (conversation_type, created_by, direct_user_a, direct_user_b)
  values ('direct', v_me, v_a, v_b)
  on conflict (direct_user_a, direct_user_b) do nothing;
  select c.id into v_conversation_id from public.conversations c
  where c.direct_user_a = v_a and c.direct_user_b = v_b;
  insert into public.conversation_members (conversation_id, user_id, member_role)
  values (v_conversation_id, v_a, case when v_a = v_me then 'owner' else 'member' end),
         (v_conversation_id, v_b, case when v_b = v_me then 'owner' else 'member' end)
  on conflict do nothing;
  return v_conversation_id;
end;
$$;
revoke all on function public.create_or_get_direct_conversation(uuid) from public, anon;
grant execute on function public.create_or_get_direct_conversation(uuid) to authenticated;

-- Server-only fixed-window rate limiter stores a digest, never a raw Nipto ID or IP address.
create table private.nipto_auth_attempts (
  key_hash text not null check (key_hash ~ '^[a-f0-9]{64}$'),
  attempted_at timestamptz not null default now()
);
create index nipto_auth_attempts_key_time_idx on private.nipto_auth_attempts(key_hash, attempted_at desc);
revoke all on private.nipto_auth_attempts from public, anon, authenticated;
grant all on private.nipto_auth_attempts to service_role;

create or replace function public.consume_nipto_login_attempt(p_key_hash text)
returns boolean
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_count integer;
begin
  if p_key_hash !~ '^[a-f0-9]{64}$' then return false; end if;
  insert into private.nipto_auth_attempts(key_hash) values (p_key_hash);
  select count(*) into v_count
  from private.nipto_auth_attempts
  where key_hash = p_key_hash and attempted_at > now() - interval '15 minutes';
  delete from private.nipto_auth_attempts where attempted_at < now() - interval '2 days';
  return v_count <= 10;
end;
$$;
revoke all on function public.consume_nipto_login_attempt(text) from public, anon, authenticated;
grant execute on function public.consume_nipto_login_attempt(text) to service_role;

comment on schema private is 'Internal Nipto policy and trigger helpers. Do not add this schema to PostgREST exposed schemas.';
