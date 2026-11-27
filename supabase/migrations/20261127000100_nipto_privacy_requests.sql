-- User-initiated privacy requests: private exports and delayed account deletion.
-- Clients may only request and read their own request status; a trusted worker
-- is the sole writer of processing outcomes and storage artifacts.

create schema if not exists private;

create table public.privacy_requests (
  id uuid primary key default gen_random_uuid(),
  user_id uuid references auth.users(id) on delete set null,
  kind text not null check (kind in ('export', 'deletion')),
  status text not null default 'pending'
    check (status in ('pending', 'processing', 'completed', 'failed', 'canceled')),
  requested_at timestamptz not null default now(),
  execute_after timestamptz not null,
  started_at timestamptz,
  completed_at timestamptz,
  canceled_at timestamptz,
  attempts integer not null default 0 check (attempts >= 0 and attempts <= 5),
  next_attempt_at timestamptz not null default now(),
  last_error text check (last_error is null or char_length(last_error) <= 500),
  export_path text check (export_path is null or char_length(export_path) <= 512),
  export_expires_at timestamptz,
  constraint privacy_requests_export_only_fields check (
    kind = 'deletion'
    or (export_expires_at is null or export_expires_at >= requested_at)
  )
);

create unique index privacy_requests_one_open_per_kind
  on public.privacy_requests (user_id, kind)
  where user_id is not null and status in ('pending', 'processing');
create index privacy_requests_due_idx
  on public.privacy_requests (status, next_attempt_at, execute_after)
  where status = 'pending';
create index privacy_requests_user_kind_idx
  on public.privacy_requests (user_id, kind, requested_at desc);
create index privacy_requests_expired_export_idx
  on public.privacy_requests (status, export_expires_at)
  where kind = 'export' and status = 'completed';

alter table public.privacy_requests enable row level security;
revoke all on public.privacy_requests from public, anon, authenticated;
grant select on public.privacy_requests to authenticated;
grant select, insert, update, delete on public.privacy_requests to service_role;

create policy "privacy_requests_read_own" on public.privacy_requests
  for select to authenticated
  using (user_id = (select auth.uid()));

comment on table public.privacy_requests is
  'Owner-readable privacy request ledger. Exports are due immediately and expire after 7 days; deletion executes after a 14-day cancellation window. Clients cannot write status.';

-- Server-only audit trail. The subject user ID is nulled with the Auth user so
-- the audit remains useful without preserving a link to the deleted account.
create table private.privacy_audit (
  id uuid primary key default gen_random_uuid(),
  request_id uuid references public.privacy_requests(id) on delete set null,
  user_id uuid references auth.users(id) on delete set null,
  action text not null check (
    action in (
      'requested', 'worker_claimed', 'completed', 'retry_scheduled',
      'failed', 'canceled', 'export_purged', 'status_changed'
    )
  ),
  details jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now()
);
create index privacy_audit_request_idx on private.privacy_audit(request_id, created_at);
alter table private.privacy_audit enable row level security;
revoke all on private.privacy_audit from public, anon, authenticated;
grant select, insert on private.privacy_audit to service_role;

create or replace function private.nipto_privacy_audit_trigger()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_action text;
  v_user_id uuid;
  v_details jsonb;
begin
  if tg_op = 'INSERT' then
    v_action := 'requested';
    v_user_id := new.user_id;
    v_details := jsonb_build_object('kind', new.kind, 'to_status', new.status);
  else
    if new.status is not distinct from old.status then
      return null;
    end if;
    v_user_id := coalesce(new.user_id, old.user_id);
    v_details := jsonb_build_object(
      'kind', new.kind,
      'from_status', old.status,
      'to_status', new.status
    );
    v_action := case new.status
      when 'processing' then 'worker_claimed'
      when 'completed' then 'completed'
      when 'failed' then 'failed'
      when 'canceled' then 'canceled'
      else 'status_changed'
    end;
  end if;

  insert into private.privacy_audit (request_id, user_id, action, details)
  values (new.id, v_user_id, v_action, v_details);
  return null;
end;
$$;
revoke all on function private.nipto_privacy_audit_trigger() from public, anon, authenticated;

create trigger privacy_requests_audit
  after insert or update on public.privacy_requests
  for each row execute function private.nipto_privacy_audit_trigger();

-- Retention exception: conversations, messages and staff/moderation records
-- owned by other people are preserved. Attribution columns are nulled rather
-- than deleting those records, so group history and review outcomes survive.
alter table public.conversations
  drop constraint if exists conversations_created_by_fkey,
  alter column created_by drop not null,
  add constraint conversations_created_by_fkey
    foreign key (created_by) references public.profiles(id) on delete set null;

alter table public.messages
  drop constraint if exists messages_sender_id_fkey,
  alter column sender_id drop not null,
  add constraint messages_sender_id_fkey
    foreign key (sender_id) references public.profiles(id) on delete set null;

alter table private.staff_roles
  drop constraint if exists staff_roles_granted_by_fkey,
  add constraint staff_roles_granted_by_fkey
    foreign key (granted_by) references auth.users(id) on delete set null;

alter table private.staff_action_log
  drop constraint if exists staff_action_log_actor_id_fkey,
  alter column actor_id drop not null,
  add constraint staff_action_log_actor_id_fkey
    foreign key (actor_id) references auth.users(id) on delete set null;

alter table public.user_feedback
  drop constraint if exists user_feedback_reviewed_by_fkey,
  add constraint user_feedback_reviewed_by_fkey
    foreign key (reviewed_by) references auth.users(id) on delete set null;

alter table public.user_reports
  drop constraint if exists user_reports_reviewed_by_fkey,
  add constraint user_reports_reviewed_by_fkey
    foreign key (reviewed_by) references auth.users(id) on delete set null;

alter table public.posts
  drop constraint if exists posts_moderation_reviewed_by_fkey,
  add constraint posts_moderation_reviewed_by_fkey
    foreign key (moderation_reviewed_by) references auth.users(id) on delete set null;

alter table public.shorts
  drop constraint if exists shorts_moderation_reviewed_by_fkey,
  add constraint shorts_moderation_reviewed_by_fkey
    foreign key (moderation_reviewed_by) references auth.users(id) on delete set null;

-- Idempotent owner RPCs. The uniqueness violation path handles simultaneous
-- requests without allowing a second open row of the same kind.
create or replace function public.request_privacy_export()
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_user_id uuid := auth.uid();
  v_request_id uuid;
begin
  if v_user_id is null then raise exception 'Authentication required'; end if;

  select pr.id into v_request_id
  from public.privacy_requests pr
  where pr.user_id = v_user_id and pr.kind = 'export'
    and pr.status in ('pending', 'processing')
  order by pr.requested_at desc
  limit 1;
  if v_request_id is not null then return v_request_id; end if;

  begin
    insert into public.privacy_requests (user_id, kind, execute_after)
    values (v_user_id, 'export', now())
    returning id into v_request_id;
  exception when unique_violation then
    select pr.id into v_request_id
    from public.privacy_requests pr
    where pr.user_id = v_user_id and pr.kind = 'export'
      and pr.status in ('pending', 'processing')
    order by pr.requested_at desc
    limit 1;
  end;
  return v_request_id;
end;
$$;
revoke all on function public.request_privacy_export() from public, anon;
grant execute on function public.request_privacy_export() to authenticated;

create or replace function public.request_account_deletion()
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_user_id uuid := auth.uid();
  v_request_id uuid;
begin
  if v_user_id is null then raise exception 'Authentication required'; end if;

  select pr.id into v_request_id
  from public.privacy_requests pr
  where pr.user_id = v_user_id and pr.kind = 'deletion'
    and pr.status in ('pending', 'processing')
  order by pr.requested_at desc
  limit 1;
  if v_request_id is not null then return v_request_id; end if;

  begin
    insert into public.privacy_requests (user_id, kind, execute_after)
    values (v_user_id, 'deletion', now() + interval '14 days')
    returning id into v_request_id;
  exception when unique_violation then
    select pr.id into v_request_id
    from public.privacy_requests pr
    where pr.user_id = v_user_id and pr.kind = 'deletion'
      and pr.status in ('pending', 'processing')
    order by pr.requested_at desc
    limit 1;
  end;
  return v_request_id;
end;
$$;
revoke all on function public.request_account_deletion() from public, anon;
grant execute on function public.request_account_deletion() to authenticated;

create or replace function public.cancel_account_deletion()
returns boolean
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_user_id uuid := auth.uid();
  v_request_id uuid;
begin
  if v_user_id is null then raise exception 'Authentication required'; end if;
  update public.privacy_requests
  set status = 'canceled', canceled_at = now(), next_attempt_at = now()
  where user_id = v_user_id and kind = 'deletion' and status = 'pending'
  returning id into v_request_id;
  return v_request_id is not null;
end;
$$;
revoke all on function public.cancel_account_deletion() from public, anon;
grant execute on function public.cancel_account_deletion() to authenticated;

-- Worker-only RPCs. Every one of these is unreachable with anon/authenticated
-- keys; the Edge Function uses the service role solely inside the worker route.
create or replace function public.nipto_privacy_claim_due(p_limit integer default 5)
returns table (
  id uuid,
  user_id uuid,
  kind text,
  status text,
  attempts integer,
  execute_after timestamptz,
  requested_at timestamptz
)
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_limit integer := least(greatest(coalesce(p_limit, 5), 1), 10);
begin
  return query
  with due as (
    select pr.id, coalesce(pr.user_id, subj.user_id) as subject_user_id,
           pr.kind, pr.attempts, pr.execute_after, pr.requested_at
    from public.privacy_requests pr
    left join lateral (
      select pa.user_id
      from private.privacy_audit pa
      where pa.request_id = pr.id and pa.user_id is not null
      order by pa.created_at desc
      limit 1
    ) subj on true
    where pr.status = 'pending'
      and pr.execute_after <= now()
      and pr.next_attempt_at <= now()
      and pr.attempts < 5
    order by pr.execute_after, pr.requested_at
    limit v_limit
    for update of pr skip locked
  ), claimed as (
    update public.privacy_requests pr
    set status = 'processing', started_at = now(), attempts = pr.attempts + 1
    from due d
    where pr.id = d.id
    returning pr.id, d.subject_user_id, pr.kind, pr.status, pr.attempts,
              pr.execute_after, pr.requested_at
  )
  select * from claimed;
end;
$$;
revoke all on function public.nipto_privacy_claim_due(integer) from public, anon, authenticated;
grant execute on function public.nipto_privacy_claim_due(integer) to service_role;

create or replace function public.nipto_privacy_complete(
  p_request_id uuid,
  p_export_path text default null,
  p_export_expires_at timestamptz default null
)
returns boolean
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_path text := nullif(btrim(coalesce(p_export_path, '')), '');
begin
  if p_request_id is null then return false; end if;
  if v_path is not null and (
    char_length(v_path) > 512
    or v_path !~ '^[0-9a-fA-F-]{36}/[0-9a-fA-F-]{36}[.]json$'
  ) then
    raise exception 'Invalid privacy export path';
  end if;

  update public.privacy_requests
  set status = 'completed',
      completed_at = now(),
      started_at = null,
      export_path = case when kind = 'export' then v_path else export_path end,
      export_expires_at = case
        when kind = 'export' then p_export_expires_at else null
      end,
      last_error = null
  where id = p_request_id and status = 'processing';
  return found;
end;
$$;
revoke all on function public.nipto_privacy_complete(uuid, text, timestamptz) from public, anon, authenticated;
grant execute on function public.nipto_privacy_complete(uuid, text, timestamptz) to service_role;

create or replace function public.nipto_privacy_fail(p_request_id uuid, p_error text)
returns boolean
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_attempts integer;
begin
  select attempts into v_attempts
  from public.privacy_requests
  where id = p_request_id and status = 'processing';
  if not found then return false; end if;

  update public.privacy_requests
  set status = case when v_attempts >= 5 then 'failed' else 'pending' end,
      started_at = null,
      last_error = left(coalesce(nullif(btrim(p_error), ''), 'Worker failed'), 500),
      next_attempt_at = case
        when v_attempts >= 5 then next_attempt_at
        else now() + (least(v_attempts, 4) || ' minutes')::interval
      end
  where id = p_request_id and status = 'processing';
  return true;
end;
$$;
revoke all on function public.nipto_privacy_fail(uuid, text) from public, anon, authenticated;
grant execute on function public.nipto_privacy_fail(uuid, text) to service_role;

create or replace function public.nipto_privacy_list_expired_exports(p_limit integer default 10)
returns table (id uuid, export_path text)
language sql
stable
security definer
set search_path = ''
as $$
  select pr.id, pr.export_path
  from public.privacy_requests pr
  where pr.kind = 'export'
    and pr.status = 'completed'
    and pr.export_expires_at is not null
    and pr.export_expires_at <= now()
    and pr.export_path is not null
  order by pr.export_expires_at
  limit least(greatest(coalesce(p_limit, 10), 1), 50);
$$;
revoke all on function public.nipto_privacy_list_expired_exports(integer) from public, anon, authenticated;
grant execute on function public.nipto_privacy_list_expired_exports(integer) to service_role;

create or replace function public.nipto_privacy_purge_export(p_request_id uuid)
returns boolean
language plpgsql
security definer
set search_path = ''
as $$
begin
  update public.privacy_requests
  set export_path = null, export_expires_at = null
  where id = p_request_id and kind = 'export' and status = 'completed'
    and export_expires_at is not null and export_expires_at <= now();
  if found then
    insert into private.privacy_audit (request_id, user_id, action, details)
    select pr.id, pr.user_id, 'export_purged', jsonb_build_object('kind', 'export')
    from public.privacy_requests pr where pr.id = p_request_id;
    return true;
  end if;
  return false;
end;
$$;
revoke all on function public.nipto_privacy_purge_export(uuid) from public, anon, authenticated;
grant execute on function public.nipto_privacy_purge_export(uuid) to service_role;

-- Explicit allowlist of user data for exports. Private tables, credential
-- columns, notification payloads and staff-only fields are never selected.
create or replace function public.nipto_privacy_export_snapshot(p_user_id uuid)
returns jsonb
language sql
stable
security definer
set search_path = ''
as $$
  select jsonb_build_object(
    'schema_version', 1,
    'generated_at', now(),
    'profile', (
      select jsonb_build_object(
        'id', p.id,
        'nipto_id', p.nipto_id,
        'display_name', p.display_name,
        'bio', p.bio,
        'avatar_path', p.avatar_path,
        'is_private', p.is_private,
        'account_state', p.account_state,
        'created_at', p.created_at,
        'updated_at', p.updated_at
      )
      from public.profiles p where p.id = p_user_id
    ),
    'preferences', (
      select jsonb_build_object(
        'message_notifications', up.message_notifications,
        'follow_notifications', up.follow_notifications,
        'status_notifications', up.status_notifications,
        'short_notifications', up.short_notifications,
        'message_access', up.message_access,
        'updated_at', up.updated_at
      )
      from public.user_preferences up where up.user_id = p_user_id
    ),
    'following', (
      select coalesce(jsonb_agg(jsonb_build_object(
        'user_id', f.following_id, 'status', f.status,
        'created_at', f.created_at
      ) order by f.created_at desc), '[]'::jsonb)
      from public.follows f where f.follower_id = p_user_id
    ),
    'followers', (
      select coalesce(jsonb_agg(jsonb_build_object(
        'user_id', f.follower_id, 'status', f.status,
        'created_at', f.created_at
      ) order by f.created_at desc), '[]'::jsonb)
      from public.follows f where f.following_id = p_user_id
    ),
    'blocked_accounts', (
      select coalesce(jsonb_agg(jsonb_build_object(
        'user_id', b.blocked_id, 'created_at', b.created_at
      ) order by b.created_at desc), '[]'::jsonb)
      from public.blocked_users b where b.blocker_id = p_user_id
    ),
    'close_friends', (
      select coalesce(jsonb_agg(jsonb_build_object(
        'user_id', cf.friend_id, 'created_at', cf.created_at
      ) order by cf.created_at desc), '[]'::jsonb)
      from public.close_friends cf where cf.owner_id = p_user_id
    ),
    'recovery_contacts', (
      select coalesce(jsonb_agg(jsonb_build_object(
        'user_id', case when rc.owner_id = p_user_id
          then rc.recovery_user_id else rc.owner_id end,
        'status', rc.status,
        'created_at', rc.created_at
      ) order by rc.created_at desc), '[]'::jsonb)
      from public.account_recovery_contacts rc
      where rc.owner_id = p_user_id or rc.recovery_user_id = p_user_id
    ),
    'conversations', (
      select coalesce(jsonb_agg(jsonb_build_object(
        'id', c.id,
        'conversation_type', c.conversation_type,
        'title', c.title,
        'created_at', c.created_at
      ) order by c.created_at desc), '[]'::jsonb)
      from public.conversations c
      join public.conversation_members cm on cm.conversation_id = c.id
      where cm.user_id = p_user_id
    ),
    'messages', (
      select coalesce(jsonb_agg(jsonb_build_object(
        'id', m.id,
        'conversation_id', m.conversation_id,
        'message_type', m.message_type,
        'body', m.body,
        'media_path', m.media_path,
        'created_at', m.created_at,
        'edited_at', m.edited_at,
        'deleted_at', m.deleted_at
      ) order by m.created_at desc), '[]'::jsonb)
      from public.messages m where m.sender_id = p_user_id
    ),
    'message_receipts', (
      select coalesce(jsonb_agg(jsonb_build_object(
        'message_id', mr.message_id,
        'conversation_id', mr.conversation_id,
        'delivered_at', mr.delivered_at,
        'read_at', mr.read_at
      ) order by mr.read_at desc nulls last), '[]'::jsonb)
      from public.message_receipts mr where mr.user_id = p_user_id
    ),
    'statuses', (
      select coalesce(jsonb_agg(jsonb_build_object(
        'id', s.id,
        'status_type', s.status_type,
        'text_content', s.text_content,
        'media_path', s.media_path,
        'background_color', s.background_color,
        'visibility', s.visibility,
        'expires_at', s.expires_at,
        'created_at', s.created_at
      ) order by s.created_at desc), '[]'::jsonb)
      from public.statuses s where s.owner_id = p_user_id
    ),
    'status_views', (
      select coalesce(jsonb_agg(jsonb_build_object(
        'status_id', sv.status_id, 'viewed_at', sv.viewed_at
      ) order by sv.viewed_at desc), '[]'::jsonb)
      from public.status_views sv where sv.viewer_id = p_user_id
    ),
    'posts', (
      select coalesce(jsonb_agg(jsonb_build_object(
        'id', po.id,
        'caption', po.caption,
        'media_path', po.media_path,
        'media_type', po.media_type,
        'visibility', po.visibility,
        'moderation_state', po.moderation_state,
        'created_at', po.created_at,
        'updated_at', po.updated_at
      ) order by po.created_at desc), '[]'::jsonb)
      from public.posts po where po.author_id = p_user_id
    ),
    'post_likes', (
      select coalesce(jsonb_agg(jsonb_build_object(
        'post_id', pl.post_id, 'created_at', pl.created_at
      ) order by pl.created_at desc), '[]'::jsonb)
      from public.post_likes pl where pl.user_id = p_user_id
    ),
    'post_comments', (
      select coalesce(jsonb_agg(jsonb_build_object(
        'id', pc.id,
        'post_id', pc.post_id,
        'body', pc.body,
        'created_at', pc.created_at,
        'updated_at', pc.updated_at
      ) order by pc.created_at desc), '[]'::jsonb)
      from public.post_comments pc where pc.author_id = p_user_id
    ),
    'shorts', (
      select coalesce(jsonb_agg(jsonb_build_object(
        'id', sh.id,
        'video_path', sh.video_path,
        'thumbnail_path', sh.thumbnail_path,
        'caption', sh.caption,
        'duration_seconds', sh.duration_seconds,
        'visibility', sh.visibility,
        'moderation_state', sh.moderation_state,
        'created_at', sh.created_at
      ) order by sh.created_at desc), '[]'::jsonb)
      from public.shorts sh where sh.creator_id = p_user_id
    ),
    'short_likes', (
      select coalesce(jsonb_agg(jsonb_build_object(
        'short_id', sl.short_id, 'created_at', sl.created_at
      ) order by sl.created_at desc), '[]'::jsonb)
      from public.short_likes sl where sl.user_id = p_user_id
    ),
    'short_comments', (
      select coalesce(jsonb_agg(jsonb_build_object(
        'id', sc.id,
        'short_id', sc.short_id,
        'body', sc.body,
        'created_at', sc.created_at
      ) order by sc.created_at desc), '[]'::jsonb)
      from public.short_comments sc where sc.author_id = p_user_id
    ),
    'notifications', (
      select coalesce(jsonb_agg(jsonb_build_object(
        'id', n.id,
        'notification_type', n.notification_type,
        'entity_id', n.entity_id,
        'read_at', n.read_at,
        'created_at', n.created_at
      ) order by n.created_at desc), '[]'::jsonb)
      from public.notifications n where n.recipient_id = p_user_id
    ),
    'feedback', (
      select coalesce(jsonb_agg(jsonb_build_object(
        'id', uf.id,
        'category', uf.category,
        'rating', uf.rating,
        'subject', uf.subject,
        'message', uf.message,
        'app_version', uf.app_version,
        'platform', uf.platform,
        'status', uf.status,
        'created_at', uf.created_at
      ) order by uf.created_at desc), '[]'::jsonb)
      from public.user_feedback uf where uf.user_id = p_user_id
    ),
    'reports', (
      select coalesce(jsonb_agg(jsonb_build_object(
        'id', ur.id,
        'content_type', ur.content_type,
        'content_id', ur.content_id,
        'reason', ur.reason,
        'details', ur.details,
        'status', ur.status,
        'created_at', ur.created_at
      ) order by ur.created_at desc), '[]'::jsonb)
      from public.user_reports ur where ur.reporter_id = p_user_id
    )
  );
$$;
revoke all on function public.nipto_privacy_export_snapshot(uuid) from public, anon, authenticated;
grant execute on function public.nipto_privacy_export_snapshot(uuid) to service_role;

-- Null attribution before the Auth row is removed so retained shared content
-- and moderation records remain intact without identifying the deleted user.
create or replace function public.nipto_privacy_anonymize_attribution(p_user_id uuid)
returns boolean
language plpgsql
security definer
set search_path = ''
as $$
begin
  if p_user_id is null then return false; end if;

  update public.messages set sender_id = null where sender_id = p_user_id;
  update public.conversations set created_by = null where created_by = p_user_id;
  update private.staff_action_log
  set actor_id = null,
      details = details || jsonb_build_object('attribution_anonymized', true)
  where actor_id = p_user_id;
  update private.staff_roles set granted_by = null where granted_by = p_user_id;
  update public.user_feedback set reviewed_by = null where reviewed_by = p_user_id;
  update public.user_reports set reviewed_by = null where reviewed_by = p_user_id;
  update public.posts set moderation_reviewed_by = null where moderation_reviewed_by = p_user_id;
  update public.shorts set moderation_reviewed_by = null where moderation_reviewed_by = p_user_id;
  return true;
end;
$$;
revoke all on function public.nipto_privacy_anonymize_attribution(uuid) from public, anon, authenticated;
grant execute on function public.nipto_privacy_anonymize_attribution(uuid) to service_role;

-- Private export bucket. No storage.objects policies are created, so clients
-- cannot list, read or sign URLs for these artifacts.
insert into storage.buckets (id, name, public)
values ('privacy-exports', 'privacy-exports', false)
on conflict (id) do update set public = false;
