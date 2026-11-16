
create schema if not exists private;

create table if not exists private.staff_roles (
  user_id uuid primary key references auth.users(id) on delete cascade,
  role text not null check (role in ('moderator','admin')),
  is_active boolean not null default true,
  granted_by uuid references auth.users(id),
  created_at timestamptz not null default now()
);

create table if not exists private.staff_action_log (
  id uuid primary key default gen_random_uuid(),
  actor_id uuid not null references auth.users(id),
  action_type text not null,
  target_type text not null,
  target_id uuid not null,
  reason text,
  details jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now()
);

alter table private.staff_roles enable row level security;
alter table private.staff_action_log enable row level security;
revoke all on private.staff_roles, private.staff_action_log from public, anon, authenticated;
grant all on private.staff_roles, private.staff_action_log to service_role;

create or replace function private.current_staff_role()
returns text
language sql
stable
security definer
set search_path = ''
as $$
  select sr.role
  from private.staff_roles sr
  where sr.user_id = auth.uid()
    and sr.is_active
  limit 1;
$$;
revoke all on function private.current_staff_role() from public, anon, authenticated;

create or replace function public.staff_can_access()
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select auth.uid() is not null and private.current_staff_role() in ('moderator','admin');
$$;
revoke all on function public.staff_can_access() from public, anon;
grant execute on function public.staff_can_access() to authenticated;

alter table public.user_feedback
  add column if not exists staff_note text,
  add column if not exists response_message text,
  add column if not exists reviewed_by uuid references auth.users(id),
  add column if not exists reviewed_at timestamptz;

alter table public.user_reports
  add column if not exists status text not null default 'received'
    check (status in ('received','reviewing','actioned','dismissed')),
  add column if not exists resolution_note text,
  add column if not exists reviewed_by uuid references auth.users(id),
  add column if not exists reviewed_at timestamptz;

alter table public.posts
  add column if not exists moderation_reviewed_by uuid references auth.users(id),
  add column if not exists moderation_reviewed_at timestamptz,
  add column if not exists moderation_reason text;

alter table public.shorts
  add column if not exists moderation_reviewed_by uuid references auth.users(id),
  add column if not exists moderation_reviewed_at timestamptz,
  add column if not exists moderation_reason text;

create index if not exists user_feedback_staff_queue_idx
  on public.user_feedback (status, created_at desc);
create index if not exists user_reports_staff_queue_idx
  on public.user_reports (status, created_at desc);
create index if not exists posts_moderation_queue_idx
  on public.posts (created_at desc)
  where moderation_state = 'pending';
create index if not exists shorts_moderation_queue_idx
  on public.shorts (created_at desc)
  where moderation_state = 'pending';

create or replace function public.staff_list_feedback(
  p_status text default null,
  p_limit integer default 50
)
returns table (
  id uuid,
  user_id uuid,
  nipto_id text,
  display_name text,
  category text,
  rating smallint,
  subject text,
  message text,
  status text,
  staff_note text,
  response_message text,
  created_at timestamptz,
  reviewed_at timestamptz
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

create or replace function public.staff_review_feedback(
  p_feedback_id uuid,
  p_status text,
  p_response_message text default null,
  p_staff_note text default null
)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_actor uuid := auth.uid();
  v_role text := private.current_staff_role();
  v_user_id uuid;
begin
  if v_actor is null or v_role not in ('moderator','admin') then
    raise exception 'Staff access required';
  end if;
  if p_status not in ('reviewing','planned','resolved','closed') then
    raise exception 'Invalid feedback status';
  end if;
  if p_response_message is not null and char_length(p_response_message) > 2000 then
    raise exception 'Response is too long';
  end if;
  if p_staff_note is not null and char_length(p_staff_note) > 4000 then
    raise exception 'Staff note is too long';
  end if;

  update public.user_feedback
  set status = p_status,
      staff_note = coalesce(p_staff_note, staff_note),
      response_message = coalesce(p_response_message, response_message),
      reviewed_by = v_actor,
      reviewed_at = now()
  where id = p_feedback_id
  returning user_id into v_user_id;

  if v_user_id is null then raise exception 'Feedback item not found'; end if;

  insert into private.staff_action_log (actor_id, action_type, target_type, target_id, reason, details)
  values (
    v_actor,
    'feedback_status_changed',
    'feedback',
    p_feedback_id,
    p_staff_note,
    jsonb_build_object('status', p_status, 'has_response', p_response_message is not null)
  );

  if p_response_message is not null or p_status in ('resolved','closed') then
    insert into public.notifications (recipient_id, actor_id, notification_type, entity_id, payload)
    values (
      v_user_id,
      v_actor,
      'system',
      p_feedback_id,
      jsonb_build_object(
        'kind', 'feedback_update',
        'status', p_status,
        'response', p_response_message
      )
    );
  end if;
end;
$$;

create or replace function public.staff_list_reports(p_limit integer default 50)
returns table (
  id uuid,
  reporter_id uuid,
  reporter_nipto_id text,
  reported_user_id uuid,
  reported_nipto_id text,
  content_type text,
  content_id uuid,
  reason text,
  details text,
  status text,
  resolution_note text,
  created_at timestamptz,
  reviewed_at timestamptz
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

create or replace function public.staff_review_report(
  p_report_id uuid,
  p_status text,
  p_resolution_note text default null
)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_actor uuid := auth.uid();
begin
  if v_actor is null or private.current_staff_role() not in ('moderator','admin') then
    raise exception 'Staff access required';
  end if;
  if p_status not in ('reviewing','actioned','dismissed') then
    raise exception 'Invalid report status';
  end if;
  if p_resolution_note is not null and char_length(p_resolution_note) > 4000 then
    raise exception 'Resolution note is too long';
  end if;

  update public.user_reports
  set status = p_status,
      resolution_note = p_resolution_note,
      reviewed_by = v_actor,
      reviewed_at = now()
  where id = p_report_id;
  if not found then raise exception 'Report not found'; end if;

  insert into private.staff_action_log (actor_id, action_type, target_type, target_id, reason, details)
  values (
    v_actor,
    'report_reviewed',
    'report',
    p_report_id,
    p_resolution_note,
    jsonb_build_object('status', p_status)
  );
end;
$$;

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
  select 'post'::text, p.id, p.author_id, pr.nipto_id, pr.display_name,
         p.caption, p.media_path, p.media_type, p.created_at
  from public.posts p
  join public.profiles pr on pr.id = p.author_id
  where p.moderation_state = 'pending' and p_kind in ('all','posts')
  union all
  select 'short'::text, s.id, s.creator_id, pr.nipto_id, pr.display_name,
         s.caption, s.video_path, 'video'::text, s.created_at
  from public.shorts s
  join public.profiles pr on pr.id = s.creator_id
  where s.moderation_state = 'pending' and p_kind in ('all','shorts')
  order by created_at desc
  limit least(greatest(coalesce(p_limit, 50), 1), 100);
end;
$$;

create or replace function public.staff_review_content(
  p_kind text,
  p_content_id uuid,
  p_decision text,
  p_reason text default null
)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_actor uuid := auth.uid();
  v_owner uuid;
begin
  if v_actor is null or private.current_staff_role() not in ('moderator','admin') then
    raise exception 'Staff access required';
  end if;
  if p_kind not in ('post','short') or p_decision not in ('approved','rejected') then
    raise exception 'Invalid moderation decision';
  end if;
  if p_reason is not null and char_length(p_reason) > 2000 then
    raise exception 'Moderation reason is too long';
  end if;

  if p_kind = 'post' then
    update public.posts
    set moderation_state = p_decision,
        moderation_reviewed_by = v_actor,
        moderation_reviewed_at = now(),
        moderation_reason = p_reason
    where id = p_content_id and moderation_state = 'pending'
    returning author_id into v_owner;
  else
    update public.shorts
    set moderation_state = p_decision,
        moderation_reviewed_by = v_actor,
        moderation_reviewed_at = now(),
        moderation_reason = p_reason
    where id = p_content_id and moderation_state = 'pending'
    returning creator_id into v_owner;
  end if;

  if v_owner is null then raise exception 'Pending content item not found'; end if;

  insert into private.staff_action_log (actor_id, action_type, target_type, target_id, reason, details)
  values (
    v_actor,
    'content_moderated',
    p_kind,
    p_content_id,
    p_reason,
    jsonb_build_object('decision', p_decision)
  );

  insert into public.notifications (recipient_id, actor_id, notification_type, entity_id, payload)
  values (
    v_owner,
    v_actor,
    'system',
    p_content_id,
    jsonb_build_object(
      'kind', 'content_moderation',
      'content_type', p_kind,
      'decision', p_decision
    )
  );
end;
$$;

revoke all on function public.staff_can_access() from public, anon;
revoke all on function public.staff_list_feedback(text, integer) from public, anon;
revoke all on function public.staff_review_feedback(uuid, text, text, text) from public, anon;
revoke all on function public.staff_list_reports(integer) from public, anon;
revoke all on function public.staff_review_report(uuid, text, text) from public, anon;
revoke all on function public.staff_list_pending_content(text, integer) from public, anon;
revoke all on function public.staff_review_content(text, uuid, text, text) from public, anon;

grant execute on function public.staff_can_access() to authenticated;
grant execute on function public.staff_list_feedback(text, integer) to authenticated;
grant execute on function public.staff_review_feedback(uuid, text, text, text) to authenticated;
grant execute on function public.staff_list_reports(integer) to authenticated;
grant execute on function public.staff_review_report(uuid, text, text) to authenticated;
grant execute on function public.staff_list_pending_content(text, integer) to authenticated;
grant execute on function public.staff_review_content(text, uuid, text, text) to authenticated;

comment on table private.staff_roles is
  'Trusted staff assignments. Provision only through Supabase project owner controls, never through client APIs.';
comment on table private.staff_action_log is
  'Append-only audit log for trusted feedback, report and content moderation actions.';
