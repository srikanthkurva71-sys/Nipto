
create or replace function private.current_staff_role()
returns text
language sql
stable
security definer
set search_path = ''
as $$
  select coalesce((
    select sr.role
    from private.staff_roles sr
    where sr.user_id = auth.uid()
      and sr.is_active
    limit 1
  ), '');
$$;
revoke all on function private.current_staff_role() from public, anon, authenticated;

create or replace function public.staff_can_access()
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select auth.uid() is not null
    and private.current_staff_role() in ('moderator','admin');
$$;
revoke all on function public.staff_can_access() from public, anon;
grant execute on function public.staff_can_access() to authenticated;

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
      and (
        p.author_id = auth.uid()
        or private.current_staff_role() in ('moderator','admin')
        or private.can_view_post(p.id)
      )
  );
$$;
revoke all on function private.can_read_post_media(text) from public, anon, authenticated;

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
      and (
        s.creator_id = auth.uid()
        or private.current_staff_role() in ('moderator','admin')
        or (
          s.moderation_state = 'approved'
          and private.can_view_short(s.id)
        )
      )
  );
$$;
revoke all on function private.can_read_short_media(text) from public, anon, authenticated;
