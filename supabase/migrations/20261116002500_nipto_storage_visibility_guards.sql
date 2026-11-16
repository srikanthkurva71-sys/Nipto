
-- Ensure application helpers run with private-schema ownership while clients cannot execute them.
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
  limit 1;
$$;
revoke all on function public.resolve_nipto_login(text) from public, anon, authenticated;
grant execute on function public.resolve_nipto_login(text) to service_role;

-- Storage policy objects are owner-prefixed, while their metadata is bound to
-- the row's exact media_path. Read access is granted only when the parent
-- content is visible through its owner/audience/block policy.
create or replace function private.can_read_avatar(p_path text)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select exists (
    select 1 from public.profiles p
    where p.id::text = split_part(p_path, '/', 1)
      and (
        p.id = auth.uid()
        or (not p.is_private and not private.is_blocked_between(auth.uid(), p.id))
        or private.has_accepted_follow(auth.uid(), p.id)
      )
  );
$$;
revoke all on function private.can_read_avatar(text) from public, anon, authenticated;

drop policy if exists avatar_read_visible_profile on storage.objects;
create policy avatar_read_visible_profile on storage.objects
for select to authenticated
using (bucket_id='avatars' and private.can_read_avatar(name));

create or replace function private.can_read_status_media(p_path text)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select exists (
    select 1 from public.statuses s
    where s.media_path = p_path
      and s.expires_at > now()
      and private.can_view_status(s.id)
  );
$$;
revoke all on function private.can_read_status_media(text) from public, anon, authenticated;

drop policy if exists status_media_read_visible on storage.objects;
create policy status_media_read_visible on storage.objects
for select to authenticated
using (bucket_id='statuses' and private.can_read_status_media(name));

create or replace function private.can_read_post_media(p_path text)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select exists (
    select 1 from public.posts p
    where p.media_path = p_path
      and (p.author_id = auth.uid() or private.can_view_post(p.id))
  );
$$;
revoke all on function private.can_read_post_media(text) from public, anon, authenticated;

drop policy if exists post_media_read_visible on storage.objects;
create policy post_media_read_visible on storage.objects
for select to authenticated
using (bucket_id='posts' and private.can_read_post_media(name));

create or replace function private.can_read_short_media(p_path text)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select exists (
    select 1 from public.shorts s
    where (s.video_path = p_path or s.thumbnail_path = p_path)
      and s.moderation_state = 'approved'
      and (s.creator_id = auth.uid() or private.can_view_short(s.id))
  );
$$;
revoke all on function private.can_read_short_media(text) from public, anon, authenticated;

drop policy if exists short_media_read_visible on storage.objects;
create policy short_media_read_visible on storage.objects
for select to authenticated
using (bucket_id='shorts' and private.can_read_short_media(name));
