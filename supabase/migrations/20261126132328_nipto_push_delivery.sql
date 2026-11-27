-- Forward migration: real Android push delivery plumbing.
--
-- The app already has a private inbox and a foreground-only call dialog. This
-- migration adds a durable outbox, narrow client RPCs for FCM token ownership,
-- and service-role-only worker RPCs used by the nipto-push-dispatch Edge
-- Function. No FCM credential or service-role material is stored in Flutter.

create table if not exists private.push_delivery_outbox (
  id uuid primary key default gen_random_uuid(),
  notification_id uuid unique references public.notifications(id) on delete cascade,
  call_id uuid unique references private.call_sessions(id) on delete cascade,
  user_id uuid not null references public.profiles(id) on delete cascade,
  delivery_type text not null check (delivery_type in ('notification','incoming_call')),
  payload jsonb not null default '{}'::jsonb,
  state text not null default 'pending' check (state in ('pending','sending','sent','failed')),
  attempts integer not null default 0 check (attempts >= 0),
  next_attempt_at timestamptz not null default now(),
  last_error text,
  created_at timestamptz not null default now(),
  sent_at timestamptz,
  constraint push_delivery_outbox_kind check (
    (delivery_type = 'notification' and notification_id is not null and call_id is null)
    or (delivery_type = 'incoming_call' and call_id is not null and notification_id is null)
  )
);

alter table private.push_delivery_outbox enable row level security;
revoke all on private.push_delivery_outbox from public, anon, authenticated;

create index if not exists push_delivery_outbox_due_idx
  on private.push_delivery_outbox (state, next_attempt_at, created_at)
  where state in ('pending','sending');

create or replace function private.enqueue_notification_push()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_actor_name text;
begin
  select p.display_name into v_actor_name
  from public.profiles as p
  where p.id = new.actor_id;

  insert into private.push_delivery_outbox (
    notification_id, user_id, delivery_type, payload
  )
  values (
    new.id,
    new.recipient_id,
    'notification',
    jsonb_build_object(
      'notification_id', new.id,
      'notification_type', new.notification_type,
      'entity_id', new.entity_id,
      'actor_name', coalesce(v_actor_name, 'Someone')
    )
  );
  return new;
end;
$$;

revoke all on function private.enqueue_notification_push() from public, anon, authenticated;
drop trigger if exists notifications_after_insert_push on public.notifications;
create trigger notifications_after_insert_push
after insert on public.notifications
for each row execute function private.enqueue_notification_push();

create or replace function private.enqueue_incoming_call_push()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_caller_name text;
begin
  select p.display_name into v_caller_name
  from public.profiles as p
  where p.id = new.caller_id;

  insert into private.push_delivery_outbox (call_id, user_id, delivery_type, payload)
  values (
    new.id,
    new.callee_id,
    'incoming_call',
    jsonb_build_object(
      'call_id', new.id,
      'conversation_id', new.conversation_id,
      'media_type', new.media_type,
      'caller_name', coalesce(v_caller_name, 'Someone')
    )
  );
  return new;
end;
$$;

revoke all on function private.enqueue_incoming_call_push() from public, anon, authenticated;
drop trigger if exists call_sessions_after_insert_push on private.call_sessions;
create trigger call_sessions_after_insert_push
after insert on private.call_sessions
for each row execute function private.enqueue_incoming_call_push();

-- Client-owned FCM registration. The caller can only add or remove tokens for
-- their own profile; a token cannot be attached to another account.
create or replace function public.register_device_push_token(
  p_token text,
  p_platform text default 'android'
)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_user_id uuid := auth.uid();
  v_token text := btrim(coalesce(p_token, ''));
  v_platform text := lower(btrim(coalesce(p_platform, 'android')));
begin
  if v_user_id is null then
    raise exception 'Authentication required' using errcode = '28000';
  end if;
  if v_platform <> 'android' then
    raise exception 'Unsupported push platform' using errcode = '22023';
  end if;
  if char_length(v_token) < 16 or char_length(v_token) > 4096
     or v_token ~ '[[:cntrl:]]' then
    raise exception 'Invalid push token' using errcode = '22023';
  end if;
  if not exists (select 1 from public.profiles as p where p.id = v_user_id) then
    raise exception 'Profile not found' using errcode = '42501';
  end if;
  if exists (
    select 1 from public.device_tokens as dt
    where dt.token = v_token and dt.user_id <> v_user_id
  ) then
    raise exception 'Invalid push token' using errcode = '42501';
  end if;

  insert into public.device_tokens (user_id, token, platform, created_at, updated_at)
  values (v_user_id, v_token, v_platform, now(), now())
  on conflict (token) do update
     set user_id = excluded.user_id,
         platform = excluded.platform,
         updated_at = now();
end;
$$;

create or replace function public.unregister_device_push_token(p_token text)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_user_id uuid := auth.uid();
  v_token text := btrim(coalesce(p_token, ''));
begin
  if v_user_id is null then
    raise exception 'Authentication required' using errcode = '28000';
  end if;
  if char_length(v_token) < 16 or char_length(v_token) > 4096 then
    raise exception 'Invalid push token' using errcode = '22023';
  end if;

  delete from public.device_tokens as dt
  where dt.user_id = v_user_id and dt.token = v_token;
end;
$$;

revoke all on function public.register_device_push_token(text, text) from public, anon, authenticated;
revoke all on function public.unregister_device_push_token(text) from public, anon, authenticated;
grant execute on function public.register_device_push_token(text, text) to authenticated;
grant execute on function public.unregister_device_push_token(text) to authenticated;

-- Worker RPCs are service-role-only. Edge Functions hold the service-role
-- secret; the Flutter client never receives these privileges.
create or replace function public.nipto_push_claim(p_limit integer default 50)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_limit integer := least(greatest(coalesce(p_limit, 50), 1), 100);
  v_jobs jsonb;
begin
  with claimed as (
    select o.id, o.user_id, o.delivery_type, o.payload, o.attempts
    from private.push_delivery_outbox as o
    where o.state in ('pending','sending')
      and o.next_attempt_at <= now()
    order by o.created_at
    limit v_limit
    for update skip locked
  )
  update private.push_delivery_outbox as o
     set state = 'sending',
         attempts = claimed.attempts + 1,
         next_attempt_at = now() + interval '5 minutes'
    from claimed
   where o.id = claimed.id
  returning jsonb_build_object(
    'id', o.id,
    'user_id', o.user_id,
    'delivery_type', o.delivery_type,
    'payload', o.payload,
    'attempts', o.attempts
  ) into v_jobs;

  return coalesce(v_jobs, '[]'::jsonb);
end;
$$;

create or replace function public.nipto_push_complete(p_job_id uuid)
returns void
language plpgsql
security definer
set search_path = ''
as $$
begin
  update private.push_delivery_outbox as o
     set state = 'sent', sent_at = now(), last_error = null
   where o.id = p_job_id;
end;
$$;

create or replace function public.nipto_push_fail(
  p_job_id uuid,
  p_error text,
  p_retryable boolean default true
)
returns void
language plpgsql
security definer
set search_path = ''
as $$
begin
  update private.push_delivery_outbox as o
     set state = case
                   when p_retryable and o.attempts < 5 then 'pending'
                   else 'failed'
                 end,
         last_error = left(btrim(coalesce(p_error, 'Push delivery failed')), 500),
         next_attempt_at = case
                             when p_retryable and o.attempts < 5
                               then now() + (least(o.attempts, 4) * interval '2 minutes')
                             else o.next_attempt_at
                           end
   where o.id = p_job_id;
end;
$$;

create or replace function public.nipto_push_tokens(p_user_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_tokens jsonb;
begin
  select coalesce(jsonb_agg(dt.token), '[]'::jsonb) into v_tokens
  from public.device_tokens as dt
  where dt.user_id = p_user_id and dt.platform = 'android';
  return v_tokens;
end;
$$;

create or replace function public.nipto_push_invalidate_token(p_token text)
returns void
language plpgsql
security definer
set search_path = ''
as $$
begin
  delete from public.device_tokens as dt where dt.token = p_token;
end;
$$;

revoke all on function public.nipto_push_claim(integer) from public, anon, authenticated;
revoke all on function public.nipto_push_complete(uuid) from public, anon, authenticated;
revoke all on function public.nipto_push_fail(uuid, text, boolean) from public, anon, authenticated;
revoke all on function public.nipto_push_tokens(uuid) from public, anon, authenticated;
revoke all on function public.nipto_push_invalidate_token(text) from public, anon, authenticated;

grant execute on function public.nipto_push_claim(integer) to service_role;
grant execute on function public.nipto_push_complete(uuid) to service_role;
grant execute on function public.nipto_push_fail(uuid, text, boolean) to service_role;
grant execute on function public.nipto_push_tokens(uuid) to service_role;
grant execute on function public.nipto_push_invalidate_token(text) to service_role;
