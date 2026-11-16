-- Make staff queue read RPCs explicitly fail closed when the JWT subject or role is absent.
create or replace function public.staff_list_feedback(
  p_status text default null,
  p_limit integer default 50
)
returns table (
  id uuid, user_id uuid, nipto_id text, display_name text, category text,
  rating smallint, subject text, message text, status text, staff_note text,
  response_message text, created_at timestamptz, reviewed_at timestamptz
)
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_actor uuid := auth.uid();
  v_role text := private.current_staff_role();
begin
  if v_actor is null or v_role is null or v_role not in ('moderator','admin') then
    raise exception 'Staff access required';
  end if;
  if p_status is not null and p_status not in ('received','reviewing','planned','resolved','closed') then
    raise exception 'Invalid feedback status filter';
  end if;
  return query
  select f.id, f.user_id, p.nipto_id, p.display_name, f.category, f.rating,
         f.subject, f.message, f.status, f.staff_note, f.response_message,
         f.created_at, f.reviewed_at
  from public.user_feedback f
  join public.profiles p on p.id = f.user_id
  where p_status is null or f.status = p_status
  order by f.created_at desc
  limit least(greatest(coalesce(p_limit, 50), 1), 100);
end;
$$;

create or replace function public.staff_list_reports(p_limit integer default 50)
returns table (
  id uuid, reporter_id uuid, reporter_nipto_id text, reported_user_id uuid,
  reported_nipto_id text, content_type text, content_id uuid, reason text,
  details text, status text, resolution_note text, created_at timestamptz,
  reviewed_at timestamptz
)
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_actor uuid := auth.uid();
  v_role text := private.current_staff_role();
begin
  if v_actor is null or v_role is null or v_role not in ('moderator','admin') then
    raise exception 'Staff access required';
  end if;
  return query
  select r.id, r.reporter_id, reporter.nipto_id,
         r.reported_user_id, reported.nipto_id,
         r.content_type, r.content_id, r.reason, r.details,
         r.status, r.resolution_note, r.created_at, r.reviewed_at
  from public.user_reports r
  left join public.profiles reporter on reporter.id = r.reporter_id
  left join public.profiles reported on reported.id = r.reported_user_id
  order by r.created_at desc
  limit least(greatest(coalesce(p_limit, 50), 1), 100);
end;
$$;

create or replace function public.staff_list_pending_content(
  p_kind text default 'all',
  p_limit integer default 50
)
returns table (
  content_type text, content_id uuid, owner_id uuid, nipto_id text,
  display_name text, caption text, media_path text, media_type text,
  created_at timestamptz
)
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_actor uuid := auth.uid();
  v_role text := private.current_staff_role();
begin
  if v_actor is null or v_role is null or v_role not in ('moderator','admin') then
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
    select 'post'::text as content_type, p.id as content_id,
           p.author_id as owner_id, pr.nipto_id, pr.display_name,
           p.caption, p.media_path, p.media_type, p.created_at
    from public.posts p
    join public.profiles pr on pr.id = p.author_id
    where p.moderation_state = 'pending' and p_kind in ('all','posts')
    union all
    select 'short'::text, s.id, s.creator_id, pr.nipto_id,
           pr.display_name, s.caption, s.video_path, 'video'::text, s.created_at
    from public.shorts s
    join public.profiles pr on pr.id = s.creator_id
    where s.moderation_state = 'pending' and p_kind in ('all','shorts')
  ) as queued
  order by queued.created_at desc
  limit least(greatest(coalesce(p_limit, 50), 1), 100);
end;
$$;

revoke all on function public.staff_list_feedback(text, integer) from public, anon;
revoke all on function public.staff_list_reports(integer) from public, anon;
revoke all on function public.staff_list_pending_content(text, integer) from public, anon;
grant execute on function public.staff_list_feedback(text, integer) to authenticated;
grant execute on function public.staff_list_reports(integer) to authenticated;
grant execute on function public.staff_list_pending_content(text, integer) to authenticated;
