
-- Nipto Social v1.0 foundation
-- Supabase Auth owns credentials; profiles contain only public identity metadata.
create table public.profiles (
  id uuid primary key references auth.users(id) on delete cascade,
  nipto_id text not null unique,
  display_name text not null,
  bio text not null default '' check (char_length(bio) <= 160),
  avatar_path text,
  is_private boolean not null default false,
  account_state text not null default 'active' check (account_state in ('active','suspended','deactivated')),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint profiles_nipto_id_format check (
    nipto_id = lower(nipto_id)
    and nipto_id ~ '^[a-z0-9_]{3,24}$'
    and nipto_id not in ('admin','administrator','support','help','nipto','official','security','moderator')
  ),
  constraint profiles_display_name_length check (char_length(display_name) between 1 and 50)
);

create table public.follows (
  follower_id uuid not null references public.profiles(id) on delete cascade,
  following_id uuid not null references public.profiles(id) on delete cascade,
  status text not null default 'accepted' check (status in ('pending','accepted')),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  primary key (follower_id, following_id),
  constraint follows_no_self check (follower_id <> following_id)
);
create index follows_following_status_idx on public.follows(following_id, status, created_at desc);
create index follows_follower_status_idx on public.follows(follower_id, status, created_at desc);

create table public.blocked_users (
  blocker_id uuid not null references public.profiles(id) on delete cascade,
  blocked_id uuid not null references public.profiles(id) on delete cascade,
  created_at timestamptz not null default now(),
  primary key (blocker_id, blocked_id),
  constraint blocked_users_no_self check (blocker_id <> blocked_id)
);

create table public.close_friends (
  owner_id uuid not null references public.profiles(id) on delete cascade,
  friend_id uuid not null references public.profiles(id) on delete cascade,
  created_at timestamptz not null default now(),
  primary key (owner_id, friend_id),
  constraint close_friends_no_self check (owner_id <> friend_id)
);

create table public.conversations (
  id uuid primary key default gen_random_uuid(),
  conversation_type text not null check (conversation_type in ('direct','group')),
  title text,
  created_by uuid not null references public.profiles(id) on delete restrict,
  direct_user_a uuid references public.profiles(id) on delete cascade,
  direct_user_b uuid references public.profiles(id) on delete cascade,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint conversations_direct_pair check (
    (conversation_type = 'direct' and direct_user_a is not null and direct_user_b is not null and direct_user_a < direct_user_b)
    or (conversation_type = 'group' and direct_user_a is null and direct_user_b is null)
  ),
  constraint conversations_title_length check (title is null or char_length(title) between 1 and 80),
  unique (direct_user_a, direct_user_b)
);

create table public.conversation_members (
  conversation_id uuid not null references public.conversations(id) on delete cascade,
  user_id uuid not null references public.profiles(id) on delete cascade,
  member_role text not null default 'member' check (member_role in ('owner','admin','member')),
  joined_at timestamptz not null default now(),
  last_read_at timestamptz,
  muted_until timestamptz,
  primary key (conversation_id, user_id)
);
create index conversation_members_user_idx on public.conversation_members(user_id, joined_at desc);

create table public.messages (
  id uuid primary key default gen_random_uuid(),
  conversation_id uuid not null references public.conversations(id) on delete cascade,
  sender_id uuid not null references public.profiles(id) on delete restrict,
  message_type text not null default 'text' check (message_type in ('text','image','video','audio','file')),
  body text check (body is null or char_length(body) <= 10000),
  media_path text,
  reply_to_id uuid references public.messages(id) on delete set null,
  edited_at timestamptz,
  deleted_at timestamptz,
  created_at timestamptz not null default now(),
  constraint messages_content_required check (
    (message_type = 'text' and body is not null and char_length(trim(body)) > 0)
    or (message_type <> 'text' and (body is not null or media_path is not null))
  )
);
create index messages_conversation_created_idx on public.messages(conversation_id, created_at desc);
create index messages_sender_created_idx on public.messages(sender_id, created_at desc);

create table public.message_receipts (
  message_id uuid not null references public.messages(id) on delete cascade,
  conversation_id uuid not null references public.conversations(id) on delete cascade,
  user_id uuid not null references public.profiles(id) on delete cascade,
  delivered_at timestamptz,
  read_at timestamptz,
  primary key (message_id, user_id)
);
create index message_receipts_user_idx on public.message_receipts(user_id, read_at);

create table public.statuses (
  id uuid primary key default gen_random_uuid(),
  owner_id uuid not null references public.profiles(id) on delete cascade,
  status_type text not null check (status_type in ('text','image','video')),
  text_content text check (text_content is null or char_length(text_content) <= 700),
  media_path text,
  background_color text,
  visibility text not null default 'followers' check (visibility in ('public','followers','close_friends')),
  expires_at timestamptz not null default (now() + interval '24 hours'),
  created_at timestamptz not null default now(),
  constraint statuses_content_required check (
    (status_type = 'text' and text_content is not null and char_length(trim(text_content)) > 0)
    or (status_type in ('image','video') and media_path is not null)
  )
);
create index statuses_owner_created_idx on public.statuses(owner_id, created_at desc);
create index statuses_expiry_idx on public.statuses(expires_at);

create table public.status_views (
  status_id uuid not null references public.statuses(id) on delete cascade,
  viewer_id uuid not null references public.profiles(id) on delete cascade,
  viewed_at timestamptz not null default now(),
  primary key (status_id, viewer_id)
);

create table public.posts (
  id uuid primary key default gen_random_uuid(),
  author_id uuid not null references public.profiles(id) on delete cascade,
  caption text not null default '' check (char_length(caption) <= 2200),
  media_path text not null,
  media_type text not null check (media_type in ('image','video','carousel')),
  visibility text not null default 'public' check (visibility in ('public','followers')),
  moderation_state text not null default 'pending' check (moderation_state in ('pending','approved','rejected')),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
create index posts_feed_idx on public.posts(moderation_state, visibility, created_at desc);
create index posts_author_idx on public.posts(author_id, created_at desc);

create table public.post_likes (
  post_id uuid not null references public.posts(id) on delete cascade,
  user_id uuid not null references public.profiles(id) on delete cascade,
  created_at timestamptz not null default now(),
  primary key (post_id, user_id)
);

create table public.post_comments (
  id uuid primary key default gen_random_uuid(),
  post_id uuid not null references public.posts(id) on delete cascade,
  author_id uuid not null references public.profiles(id) on delete cascade,
  body text not null check (char_length(trim(body)) between 1 and 2000),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
create index post_comments_post_created_idx on public.post_comments(post_id, created_at);

create table public.shorts (
  id uuid primary key default gen_random_uuid(),
  creator_id uuid not null references public.profiles(id) on delete cascade,
  video_path text not null,
  thumbnail_path text,
  caption text not null default '' check (char_length(caption) <= 2200),
  duration_seconds numeric(6,2) not null check (duration_seconds > 0 and duration_seconds <= 180),
  visibility text not null default 'public' check (visibility in ('public','followers')),
  moderation_state text not null default 'pending' check (moderation_state in ('pending','approved','rejected')),
  created_at timestamptz not null default now()
);
create index shorts_feed_idx on public.shorts(moderation_state, visibility, created_at desc);
create index shorts_creator_idx on public.shorts(creator_id, created_at desc);

create table public.short_likes (
  short_id uuid not null references public.shorts(id) on delete cascade,
  user_id uuid not null references public.profiles(id) on delete cascade,
  created_at timestamptz not null default now(),
  primary key (short_id, user_id)
);

create table public.short_comments (
  id uuid primary key default gen_random_uuid(),
  short_id uuid not null references public.shorts(id) on delete cascade,
  author_id uuid not null references public.profiles(id) on delete cascade,
  body text not null check (char_length(trim(body)) between 1 and 2000),
  created_at timestamptz not null default now()
);
create index short_comments_short_created_idx on public.short_comments(short_id, created_at);

create table public.notifications (
  id uuid primary key default gen_random_uuid(),
  recipient_id uuid not null references public.profiles(id) on delete cascade,
  actor_id uuid references public.profiles(id) on delete set null,
  notification_type text not null check (notification_type in ('follow','follow_request','follow_accepted','like','comment','message','status_view','system')),
  entity_id uuid,
  payload jsonb not null default '{}'::jsonb,
  read_at timestamptz,
  created_at timestamptz not null default now()
);
create index notifications_inbox_idx on public.notifications(recipient_id, created_at desc) where read_at is null;

create table public.device_tokens (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references public.profiles(id) on delete cascade,
  token text not null unique,
  platform text not null default 'android' check (platform in ('android')),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
create index device_tokens_user_idx on public.device_tokens(user_id);

create table public.user_reports (
  id uuid primary key default gen_random_uuid(),
  reporter_id uuid not null references public.profiles(id) on delete cascade,
  reported_user_id uuid references public.profiles(id) on delete set null,
  content_type text check (content_type is null or content_type in ('profile','post','short','message','status')),
  content_id uuid,
  reason text not null check (reason in ('spam','harassment','hate','impersonation','unsafe_content','other')),
  details text check (details is null or char_length(details) <= 1000),
  created_at timestamptz not null default now(),
  constraint user_reports_target_required check (reported_user_id is not null or content_id is not null)
);

-- Shared timestamp trigger.
create or replace function public.set_updated_at()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  new.updated_at = now();
  return new;
end;
$$;

create trigger profiles_updated_at before update on public.profiles
for each row execute function public.set_updated_at();
create trigger follows_updated_at before update on public.follows
for each row execute function public.set_updated_at();
create trigger conversations_updated_at before update on public.conversations
for each row execute function public.set_updated_at();
create trigger posts_updated_at before update on public.posts
for each row execute function public.set_updated_at();
create trigger post_comments_updated_at before update on public.post_comments
for each row execute function public.set_updated_at();
create trigger device_tokens_updated_at before update on public.device_tokens
for each row execute function public.set_updated_at();

-- Create a public profile in the same transaction as Auth registration.
create or replace function public.handle_new_nipto_user()
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

create trigger on_auth_user_created_nipto
after insert on auth.users
for each row execute function public.handle_new_nipto_user();

-- Internal identity lookup: only the Edge Function's service role may call this.
create or replace function public.resolve_nipto_login(p_nipto_id text)
returns text
language sql
stable
security definer
set search_path = ''
as $$
  select u.email
  from auth.users u
  join public.profiles p on p.id = u.id
  where p.nipto_id = lower(trim(p_nipto_id))
    and p.account_state = 'active'
    and u.deleted_at is null
  limit 1;
$$;
revoke all on function public.resolve_nipto_login(text) from public, anon, authenticated;
grant execute on function public.resolve_nipto_login(text) to service_role;

-- Security-definer predicates avoid recursive RLS policies.
create or replace function public.is_blocked_between(p_user_a uuid, p_user_b uuid)
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

create or replace function public.has_accepted_follow(p_follower uuid, p_following uuid)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select exists (
    select 1 from public.follows f
    where f.follower_id = p_follower
      and f.following_id = p_following
      and f.status = 'accepted'
  );
$$;

create or replace function public.can_view_profile(p_profile_id uuid)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select auth.uid() = p_profile_id
    or (
      auth.uid() is not null
      and not public.is_blocked_between(auth.uid(), p_profile_id)
      and exists (
        select 1 from public.profiles p
        where p.id = p_profile_id
          and p.account_state = 'active'
          and (not p.is_private or public.has_accepted_follow(auth.uid(), p_profile_id))
      )
    );
$$;

create or replace function public.is_conversation_member(p_conversation_id uuid)
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

create or replace function public.can_view_status(p_status_id uuid)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select exists (
    select 1
    from public.statuses s
    where s.id = p_status_id
      and s.expires_at > now()
      and not public.is_blocked_between(auth.uid(), s.owner_id)
      and (
        s.owner_id = auth.uid()
        or s.visibility = 'public'
        or (s.visibility = 'followers' and public.has_accepted_follow(auth.uid(), s.owner_id))
        or (s.visibility = 'close_friends' and exists (
          select 1 from public.close_friends cf
          where cf.owner_id = s.owner_id and cf.friend_id = auth.uid()
        ))
      )
  );
$$;

create or replace function public.can_view_short(p_short_id uuid)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select exists (
    select 1 from public.shorts s
    where s.id = p_short_id
      and s.moderation_state = 'approved'
      and not public.is_blocked_between(auth.uid(), s.creator_id)
      and (
        s.creator_id = auth.uid()
        or s.visibility = 'public'
        or (s.visibility = 'followers' and public.has_accepted_follow(auth.uid(), s.creator_id))
      )
  );
$$;

create or replace function public.can_view_post(p_post_id uuid)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select exists (
    select 1 from public.posts p
    where p.id = p_post_id
      and p.moderation_state = 'approved'
      and not public.is_blocked_between(auth.uid(), p.author_id)
      and (
        p.author_id = auth.uid()
        or (p.visibility = 'public' and not exists (
          select 1 from public.profiles pr where pr.id = p.author_id and pr.is_private
        ))
        or (p.visibility = 'followers' and public.has_accepted_follow(auth.uid(), p.author_id))
      )
  );
$$;

-- Nipto ID discovery returns no email, phone number, or private account metadata.
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
  select p.id, p.nipto_id, p.display_name, p.bio, p.avatar_path, p.is_private
  from public.profiles p
  where auth.uid() is not null
    and p.account_state = 'active'
    and p.nipto_id like (lower(trim(p_query)) || '%')
    and not public.is_blocked_between(auth.uid(), p.id)
    and p.id <> auth.uid()
  order by p.nipto_id
  limit least(greatest(coalesce(p_limit, 20), 1), 30);
$$;
revoke all on function public.search_profiles(text, integer) from public, anon;
grant execute on function public.search_profiles(text, integer) to authenticated;

-- Atomic direct-chat creation prevents duplicate one-to-one threads.
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
  if public.is_blocked_between(v_me, p_other_user) then raise exception 'This conversation is unavailable'; end if;
  if not exists (select 1 from public.profiles p where p.id = p_other_user and p.account_state = 'active') then
    raise exception 'User not found';
  end if;
  v_a := least(v_me, p_other_user);
  v_b := greatest(v_me, p_other_user);
  insert into public.conversations (conversation_type, created_by, direct_user_a, direct_user_b)
  values ('direct', v_me, v_a, v_b)
  on conflict (direct_user_a, direct_user_b) do nothing;
  select c.id into v_conversation_id
  from public.conversations c
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

-- Enable RLS across all user-facing tables.
alter table public.profiles enable row level security;
alter table public.follows enable row level security;
alter table public.blocked_users enable row level security;
alter table public.close_friends enable row level security;
alter table public.conversations enable row level security;
alter table public.conversation_members enable row level security;
alter table public.messages enable row level security;
alter table public.message_receipts enable row level security;
alter table public.statuses enable row level security;
alter table public.status_views enable row level security;
alter table public.posts enable row level security;
alter table public.post_likes enable row level security;
alter table public.post_comments enable row level security;
alter table public.shorts enable row level security;
alter table public.short_likes enable row level security;
alter table public.short_comments enable row level security;
alter table public.notifications enable row level security;
alter table public.device_tokens enable row level security;
alter table public.user_reports enable row level security;

create policy "profiles_read_visible" on public.profiles for select to authenticated
using (public.can_view_profile(id));
create policy "profiles_update_self" on public.profiles for update to authenticated
using (id = auth.uid()) with check (id = auth.uid());

create policy "follows_read_involved" on public.follows for select to authenticated
using (follower_id = auth.uid() or following_id = auth.uid());
create policy "follows_create_self" on public.follows for insert to authenticated
with check (follower_id = auth.uid() and not public.is_blocked_between(follower_id, following_id));
create policy "follows_accept_owner" on public.follows for update to authenticated
using (following_id = auth.uid() and status = 'pending')
with check (following_id = auth.uid() and status = 'accepted');
create policy "follows_remove_involved" on public.follows for delete to authenticated
using (follower_id = auth.uid() or following_id = auth.uid());

create policy "blocks_read_self" on public.blocked_users for select to authenticated using (blocker_id = auth.uid());
create policy "blocks_create_self" on public.blocked_users for insert to authenticated with check (blocker_id = auth.uid());
create policy "blocks_delete_self" on public.blocked_users for delete to authenticated using (blocker_id = auth.uid());

create policy "close_friends_read_owner" on public.close_friends for select to authenticated using (owner_id = auth.uid());
create policy "close_friends_add_owner" on public.close_friends for insert to authenticated with check (owner_id = auth.uid());
create policy "close_friends_remove_owner" on public.close_friends for delete to authenticated using (owner_id = auth.uid());

create policy "conversations_read_members" on public.conversations for select to authenticated
using (public.is_conversation_member(id));
create policy "conversations_create_group_owner" on public.conversations for insert to authenticated
with check (conversation_type = 'group' and created_by = auth.uid());
create policy "conversations_update_group_admin" on public.conversations for update to authenticated
using (conversation_type = 'group' and exists (
  select 1 from public.conversation_members cm
  where cm.conversation_id = id and cm.user_id = auth.uid() and cm.member_role in ('owner','admin')
))
with check (conversation_type = 'group');

create policy "conversation_members_read_members" on public.conversation_members for select to authenticated
using (public.is_conversation_member(conversation_id));

create policy "messages_read_members" on public.messages for select to authenticated
using (public.is_conversation_member(conversation_id));
create policy "messages_send_as_self" on public.messages for insert to authenticated
with check (
  sender_id = auth.uid()
  and public.is_conversation_member(conversation_id)
  and not exists (
    select 1 from public.conversation_members cm
    where cm.conversation_id = messages.conversation_id
      and cm.user_id <> auth.uid()
      and public.is_blocked_between(auth.uid(), cm.user_id)
  )
);
create policy "messages_edit_own_recent" on public.messages for update to authenticated
using (sender_id = auth.uid() and created_at > now() - interval '15 minutes')
with check (sender_id = auth.uid());
create policy "messages_delete_own" on public.messages for delete to authenticated
using (sender_id = auth.uid());

create policy "message_receipts_read_members" on public.message_receipts for select to authenticated
using (public.is_conversation_member(conversation_id));
create policy "message_receipts_write_self" on public.message_receipts for insert to authenticated
with check (user_id = auth.uid() and public.is_conversation_member(conversation_id));
create policy "message_receipts_update_self" on public.message_receipts for update to authenticated
using (user_id = auth.uid() and public.is_conversation_member(conversation_id))
with check (user_id = auth.uid() and public.is_conversation_member(conversation_id));

create policy "statuses_read_visible" on public.statuses for select to authenticated
using (public.can_view_status(id));
create policy "statuses_create_self" on public.statuses for insert to authenticated
with check (owner_id = auth.uid());
create policy "statuses_update_self" on public.statuses for update to authenticated
using (owner_id = auth.uid()) with check (owner_id = auth.uid());
create policy "statuses_delete_self" on public.statuses for delete to authenticated
using (owner_id = auth.uid());

create policy "status_views_read_owner_or_viewer" on public.status_views for select to authenticated
using (viewer_id = auth.uid() or exists (
  select 1 from public.statuses s where s.id = status_id and s.owner_id = auth.uid()
));
create policy "status_views_create_self" on public.status_views for insert to authenticated
with check (viewer_id = auth.uid() and public.can_view_status(status_id));

create policy "posts_read_visible" on public.posts for select to authenticated using (public.can_view_post(id));
create policy "posts_create_self" on public.posts for insert to authenticated
with check (author_id = auth.uid() and moderation_state = 'pending');
create policy "posts_update_self" on public.posts for update to authenticated
using (author_id = auth.uid()) with check (author_id = auth.uid());
create policy "posts_delete_self" on public.posts for delete to authenticated using (author_id = auth.uid());

create policy "post_likes_read_visible" on public.post_likes for select to authenticated
using (public.can_view_post(post_id));
create policy "post_likes_create_self" on public.post_likes for insert to authenticated
with check (user_id = auth.uid() and public.can_view_post(post_id));
create policy "post_likes_delete_self" on public.post_likes for delete to authenticated
using (user_id = auth.uid());
create policy "post_comments_read_visible" on public.post_comments for select to authenticated
using (public.can_view_post(post_id));
create policy "post_comments_create_self" on public.post_comments for insert to authenticated
with check (author_id = auth.uid() and public.can_view_post(post_id));
create policy "post_comments_delete_self" on public.post_comments for delete to authenticated
using (author_id = auth.uid());

create policy "shorts_read_visible" on public.shorts for select to authenticated
using (creator_id = auth.uid() or public.can_view_short(id));
create policy "shorts_create_self" on public.shorts for insert to authenticated
with check (creator_id = auth.uid() and moderation_state = 'pending');
create policy "shorts_update_self" on public.shorts for update to authenticated
using (creator_id = auth.uid()) with check (creator_id = auth.uid());
create policy "shorts_delete_self" on public.shorts for delete to authenticated
using (creator_id = auth.uid());

create policy "short_likes_read_visible" on public.short_likes for select to authenticated
using (public.can_view_short(short_id));
create policy "short_likes_create_self" on public.short_likes for insert to authenticated
with check (user_id = auth.uid() and public.can_view_short(short_id));
create policy "short_likes_delete_self" on public.short_likes for delete to authenticated
using (user_id = auth.uid());
create policy "short_comments_read_visible" on public.short_comments for select to authenticated
using (public.can_view_short(short_id));
create policy "short_comments_create_self" on public.short_comments for insert to authenticated
with check (author_id = auth.uid() and public.can_view_short(short_id));
create policy "short_comments_delete_self" on public.short_comments for delete to authenticated
using (author_id = auth.uid());

create policy "notifications_read_recipient" on public.notifications for select to authenticated
using (recipient_id = auth.uid());
create policy "notifications_update_recipient" on public.notifications for update to authenticated
using (recipient_id = auth.uid()) with check (recipient_id = auth.uid());

create policy "device_tokens_read_self" on public.device_tokens for select to authenticated using (user_id = auth.uid());
create policy "device_tokens_create_self" on public.device_tokens for insert to authenticated with check (user_id = auth.uid());
create policy "device_tokens_update_self" on public.device_tokens for update to authenticated using (user_id = auth.uid()) with check (user_id = auth.uid());
create policy "device_tokens_delete_self" on public.device_tokens for delete to authenticated using (user_id = auth.uid());

create policy "reports_create_self" on public.user_reports for insert to authenticated
with check (reporter_id = auth.uid() and (reported_user_id is null or reported_user_id <> auth.uid()));
create policy "reports_read_reporter" on public.user_reports for select to authenticated
using (reporter_id = auth.uid());

-- Private media buckets. Client object paths use:
-- avatars/{user_id}/...
-- chat-media/{conversation_id}/{user_id}/...
-- statuses/{owner_id}/{status_id}/...
-- posts/{owner_id}/{post_id}/...
-- shorts/{creator_id}/{short_id}/...
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values
  ('avatars','avatars',false,5242880,array['image/jpeg','image/png','image/webp']),
  ('chat-media','chat-media',false,26214400,array['image/jpeg','image/png','image/webp','video/mp4','audio/mpeg','audio/mp4']),
  ('statuses','statuses',false,52428800,array['image/jpeg','image/png','image/webp','video/mp4']),
  ('posts','posts',false,104857600,array['image/jpeg','image/png','image/webp','video/mp4']),
  ('shorts','shorts',false,209715200,array['video/mp4'])
on conflict (id) do nothing;

create policy "avatar_owner_upload" on storage.objects for insert to authenticated
with check (bucket_id = 'avatars' and split_part(name,'/',1) = auth.uid()::text);
create policy "avatar_owner_update" on storage.objects for update to authenticated
using (bucket_id = 'avatars' and split_part(name,'/',1) = auth.uid()::text)
with check (bucket_id = 'avatars' and split_part(name,'/',1) = auth.uid()::text);
create policy "avatar_owner_delete" on storage.objects for delete to authenticated
using (bucket_id = 'avatars' and split_part(name,'/',1) = auth.uid()::text);
create policy "avatar_read_visible_profile" on storage.objects for select to authenticated
using (
  bucket_id = 'avatars' and exists (
    select 1 from public.profiles p
    where p.id::text = split_part(name,'/',1)
      and public.can_view_profile(p.id)
  )
);

create policy "chat_media_upload_member" on storage.objects for insert to authenticated
with check (
  bucket_id = 'chat-media'
  and split_part(name,'/',2) = auth.uid()::text
  and public.is_conversation_member(split_part(name,'/',1)::uuid)
);
create policy "chat_media_read_member" on storage.objects for select to authenticated
using (
  bucket_id = 'chat-media'
  and exists (
    select 1 from public.messages m
    where m.media_path = storage.objects.name
      and public.is_conversation_member(m.conversation_id)
  )
);
create policy "chat_media_delete_uploader" on storage.objects for delete to authenticated
using (bucket_id = 'chat-media' and split_part(name,'/',2) = auth.uid()::text);

create policy "status_media_upload_owner" on storage.objects for insert to authenticated
with check (bucket_id = 'statuses' and split_part(name,'/',1) = auth.uid()::text);
create policy "status_media_read_visible" on storage.objects for select to authenticated
using (
  bucket_id = 'statuses' and exists (
    select 1 from public.statuses s
    where s.media_path = storage.objects.name and public.can_view_status(s.id)
  )
);
create policy "status_media_delete_owner" on storage.objects for delete to authenticated
using (bucket_id = 'statuses' and split_part(name,'/',1) = auth.uid()::text);

create policy "post_media_upload_owner" on storage.objects for insert to authenticated
with check (bucket_id = 'posts' and split_part(name,'/',1) = auth.uid()::text);
create policy "post_media_read_visible" on storage.objects for select to authenticated
using (
  bucket_id = 'posts' and exists (
    select 1 from public.posts p
    where p.media_path = storage.objects.name and public.can_view_post(p.id)
  )
);
create policy "post_media_delete_owner" on storage.objects for delete to authenticated
using (bucket_id = 'posts' and split_part(name,'/',1) = auth.uid()::text);

create policy "short_media_upload_owner" on storage.objects for insert to authenticated
with check (bucket_id = 'shorts' and split_part(name,'/',1) = auth.uid()::text);
create policy "short_media_read_visible" on storage.objects for select to authenticated
using (
  bucket_id = 'shorts' and exists (
    select 1 from public.shorts s
    where (s.video_path = storage.objects.name or s.thumbnail_path = storage.objects.name)
      and (s.creator_id = auth.uid() or public.can_view_short(s.id))
  )
);
create policy "short_media_delete_owner" on storage.objects for delete to authenticated
using (bucket_id = 'shorts' and split_part(name,'/',1) = auth.uid()::text);

-- Limit direct table privileges; RLS remains the row-level authorization boundary.
grant usage on schema public to authenticated;
grant select, update on public.profiles to authenticated;
grant select, insert, update, delete on public.follows, public.blocked_users, public.close_friends to authenticated;
grant select, insert, update on public.conversations to authenticated;
grant select on public.conversation_members to authenticated;
grant select, insert, update, delete on public.messages to authenticated;
grant select, insert, update on public.message_receipts to authenticated;
grant select, insert, update, delete on public.statuses, public.posts, public.post_comments, public.shorts, public.short_comments to authenticated;
grant select, insert, delete on public.status_views, public.post_likes, public.short_likes to authenticated;
grant select, update on public.notifications to authenticated;
grant select, insert, update, delete on public.device_tokens to authenticated;
grant select, insert on public.user_reports to authenticated;

-- Functions called by policies are available to authenticated users, but sensitive lookup is not.
revoke all on function public.is_blocked_between(uuid, uuid) from public, anon;
revoke all on function public.has_accepted_follow(uuid, uuid) from public, anon;
revoke all on function public.can_view_profile(uuid) from public, anon;
revoke all on function public.is_conversation_member(uuid) from public, anon;
revoke all on function public.can_view_status(uuid) from public, anon;
revoke all on function public.can_view_short(uuid) from public, anon;
revoke all on function public.can_view_post(uuid) from public, anon;
grant execute on function public.is_blocked_between(uuid, uuid) to authenticated;
grant execute on function public.has_accepted_follow(uuid, uuid) to authenticated;
grant execute on function public.can_view_profile(uuid) to authenticated;
grant execute on function public.is_conversation_member(uuid) to authenticated;
grant execute on function public.can_view_status(uuid) to authenticated;
grant execute on function public.can_view_short(uuid) to authenticated;
grant execute on function public.can_view_post(uuid) to authenticated;

comment on schema public is 'Nipto Social application schema. Auth credentials remain in Supabase Auth.';
comment on table public.profiles is 'Public Nipto identity. Never store passwords, recovery emails, or phone numbers here.';
comment on table public.messages is 'Private conversation messages. Access is limited to conversation members by RLS.';
comment on table public.statuses is '24-hour status updates with public, follower, or close-friends visibility.';
comment on table public.shorts is 'Short-form videos. New uploads start pending moderation.';
