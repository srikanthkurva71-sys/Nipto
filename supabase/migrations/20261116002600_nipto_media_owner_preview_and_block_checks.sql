
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
        or (
          not private.is_blocked_between(auth.uid(), p.id)
          and (
            not p.is_private
            or private.has_accepted_follow(auth.uid(), p.id)
          )
        )
      )
  );
$$;
revoke all on function private.can_read_avatar(text) from public, anon, authenticated;

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
        or (
          s.moderation_state = 'approved'
          and private.can_view_short(s.id)
        )
      )
  );
$$;
revoke all on function private.can_read_short_media(text) from public, anon, authenticated;
