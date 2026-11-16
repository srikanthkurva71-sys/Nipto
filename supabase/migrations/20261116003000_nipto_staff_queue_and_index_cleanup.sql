
drop index if exists public.user_feedback_staff_queue_idx;

create or replace function public.staff_list_pending_content(
  p_kind text default 'all',
  p_limit integer default 50
)
returns table (
  content_type text,
  content_id uuid,
  owner_id uuid,
  nipto_id text,
  display_name text,
  caption text,
  media_path text,
  media_type text,
  created_at timestamptz
)
language plpgsql
stable
security definer
set search_path = ''
as $$
begin
  if private.current_staff_role() not in ('moderator','admin') then
    raise exception 'Staff access required';
  end if;
  if p_kind not in ('all','posts','shorts') then
    raise exception 'Invalid content type';
  end if;

  return query
  select queued.content_type, queued.content_id, queued.owner_id,
         queued.nipto_id, queued.display_name, queued.caption,
         queued.media_path, queued.media_type, queued.created_at
  from (
    select
      'post'::text as content_type,
      p.id as content_id,
      p.author_id as owner_id,
      pr.nipto_id,
      pr.display_name,
      p.caption,
      p.media_path,
      p.media_type,
      p.created_at
    from public.posts p
    join public.profiles pr on pr.id = p.author_id
    where p.moderation_state = 'pending'
      and p_kind in ('all','posts')

    union all

    select
      'short'::text as content_type,
      s.id as content_id,
      s.creator_id as owner_id,
      pr.nipto_id,
      pr.display_name,
      s.caption,
      s.video_path as media_path,
      'video'::text as media_type,
      s.created_at
    from public.shorts s
    join public.profiles pr on pr.id = s.creator_id
    where s.moderation_state = 'pending'
      and p_kind in ('all','shorts')
  ) as queued
  order by queued.created_at desc
  limit least(greatest(coalesce(p_limit, 50), 1), 100);
end;
$$;

revoke all on function public.staff_list_pending_content(text, integer) from public, anon;
grant execute on function public.staff_list_pending_content(text, integer) to authenticated;
