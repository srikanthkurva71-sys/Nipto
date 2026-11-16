-- One-to-one call lifecycle and private Realtime signaling authorization.
create table private.call_sessions (
  id uuid primary key default gen_random_uuid(),
  conversation_id uuid not null references public.conversations(id) on delete cascade,
  caller_id uuid not null references public.profiles(id) on delete cascade,
  callee_id uuid not null references public.profiles(id) on delete cascade,
  media_type text not null check (media_type in ('audio','video')),
  state text not null default 'ringing'
    check (state in ('ringing','accepted','declined','ended','missed','expired')),
  created_at timestamptz not null default pg_catalog.now(),
  answered_at timestamptz,
  ended_at timestamptz,
  expires_at timestamptz not null default (pg_catalog.now() + interval '45 seconds'),
  end_reason text,
  constraint call_sessions_distinct_participants check (caller_id <> callee_id),
  constraint call_sessions_terminal_timestamp check (
    (state in ('ringing','accepted') and ended_at is null)
    or (state in ('declined','ended','missed','expired') and ended_at is not null)
  )
);
create index call_sessions_callee_incoming_idx
  on private.call_sessions(callee_id, created_at desc)
  where state = 'ringing';
create index call_sessions_participant_history_idx
  on private.call_sessions(caller_id, callee_id, created_at desc);
create unique index call_sessions_one_active_per_conversation_idx
  on private.call_sessions(conversation_id)
  where state in ('ringing','accepted');

alter table private.call_sessions enable row level security;
revoke all on private.call_sessions from public, anon, authenticated;

create or replace function private.can_access_nipto_call_topic()
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select auth.uid() is not null
    and realtime.topic() ~ '^nipto-call:[0-9a-fA-F-]{36}$'
    and exists (
      select 1
      from private.call_sessions c
      where c.id::text = pg_catalog.split_part(realtime.topic(), ':', 2)
        and auth.uid() in (c.caller_id, c.callee_id)
        and c.state in ('ringing','accepted')
        and c.expires_at > pg_catalog.now()
    );
$$;
revoke all on function private.can_access_nipto_call_topic() from public, anon;
grant execute on function private.can_access_nipto_call_topic() to authenticated;

drop policy if exists nipto_call_participant_read on realtime.messages;
create policy nipto_call_participant_read
  on realtime.messages for select to authenticated
  using (private.can_access_nipto_call_topic());

drop policy if exists nipto_call_participant_send on realtime.messages;
create policy nipto_call_participant_send
  on realtime.messages for insert to authenticated
  with check (private.can_access_nipto_call_topic());

create or replace function public.start_nipto_call(
  p_conversation_id uuid,
  p_media_type text
)
returns table(call_id uuid, callee_id uuid, expires_at timestamptz)
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_me uuid := auth.uid();
  v_conversation public.conversations%rowtype;
  v_callee uuid;
  v_call_id uuid;
  v_expires timestamptz;
  v_recent_count integer;
begin
  if v_me is null then raise exception 'Authentication required'; end if;
  if p_media_type not in ('audio','video') then raise exception 'Unsupported call type'; end if;

  select * into v_conversation
  from public.conversations c
  where c.id = p_conversation_id
    and c.conversation_type = 'direct'
    and v_me in (c.direct_user_a, c.direct_user_b);

  if not found then raise exception 'Direct conversation not found'; end if;
  v_callee := case when v_conversation.direct_user_a = v_me
                   then v_conversation.direct_user_b
                   else v_conversation.direct_user_a end;

  if not exists (
    select 1 from public.conversation_members cm
    where cm.conversation_id = p_conversation_id
      and cm.user_id = v_me and cm.membership_state = 'accepted'
  ) or not exists (
    select 1 from public.conversation_members cm
    where cm.conversation_id = p_conversation_id
      and cm.user_id = v_callee and cm.membership_state = 'accepted'
  ) then
    raise exception 'Accepted conversation membership required';
  end if;

  if not exists (
    select 1 from public.profiles p
    where p.id in (v_me, v_callee) and p.account_state = 'active'
    group by p.id having count(*) = 2
  ) then
    raise exception 'Call participants are unavailable';
  end if;
  if private.is_blocked_between(v_me, v_callee) then
    raise exception 'This call is unavailable';
  end if;

  select count(*) into v_recent_count
  from private.call_sessions c
  where c.caller_id = v_me
    and c.created_at > pg_catalog.now() - interval '1 hour';
  if v_recent_count >= 20 then raise exception 'Call limit reached. Try again later.'; end if;

  update private.call_sessions c
  set state = 'expired', ended_at = pg_catalog.now(), end_reason = 'ring_timeout'
  where c.conversation_id = p_conversation_id
    and c.state = 'ringing' and c.expires_at <= pg_catalog.now();

  insert into private.call_sessions(conversation_id, caller_id, callee_id, media_type)
  values (p_conversation_id, v_me, v_callee, p_media_type)
  returning id, private.call_sessions.expires_at into v_call_id, v_expires;

  return query select v_call_id, v_callee, v_expires;
exception
  when unique_violation then
    raise exception 'A call is already active in this conversation';
end;
$$;
revoke all on function public.start_nipto_call(uuid,text) from public, anon;
grant execute on function public.start_nipto_call(uuid,text) to authenticated;

create or replace function public.list_my_incoming_calls()
returns table(
  call_id uuid,
  conversation_id uuid,
  caller_id uuid,
  caller_nipto_id text,
  caller_display_name text,
  media_type text,
  created_at timestamptz,
  expires_at timestamptz
)
language sql
stable
security definer
set search_path = ''
as $$
  select c.id, c.conversation_id, c.caller_id, p.nipto_id, p.display_name,
         c.media_type, c.created_at, c.expires_at
  from private.call_sessions c
  join public.profiles p on p.id = c.caller_id
  where auth.uid() is not null
    and c.callee_id = auth.uid()
    and c.state = 'ringing'
    and c.expires_at > pg_catalog.now()
    and not private.is_blocked_between(auth.uid(), c.caller_id)
  order by c.created_at desc
  limit 10;
$$;
revoke all on function public.list_my_incoming_calls() from public, anon;
grant execute on function public.list_my_incoming_calls() to authenticated;

create or replace function public.accept_nipto_call(p_call_id uuid)
returns table(call_id uuid, conversation_id uuid, caller_id uuid, media_type text, state text)
language plpgsql
security definer
set search_path = ''
as $$
begin
  return query
  update private.call_sessions c
  set state = 'accepted', answered_at = pg_catalog.now()
  where c.id = p_call_id
    and c.callee_id = auth.uid()
    and c.state = 'ringing'
    and c.expires_at > pg_catalog.now()
    and not private.is_blocked_between(c.caller_id, c.callee_id)
  returning c.id, c.conversation_id, c.caller_id, c.media_type, c.state;
  if not found then raise exception 'This call is no longer available'; end if;
end;
$$;
revoke all on function public.accept_nipto_call(uuid) from public, anon;
grant execute on function public.accept_nipto_call(uuid) to authenticated;

create or replace function public.decline_nipto_call(p_call_id uuid)
returns boolean
language plpgsql
security definer
set search_path = ''
as $$
declare v_updated integer;
begin
  if auth.uid() is null then raise exception 'Authentication required'; end if;
  update private.call_sessions c
  set state = 'declined', ended_at = pg_catalog.now(), end_reason = 'declined'
  where c.id = p_call_id and c.callee_id = auth.uid() and c.state = 'ringing';
  get diagnostics v_updated = row_count;
  return v_updated = 1;
end;
$$;
revoke all on function public.decline_nipto_call(uuid) from public, anon;
grant execute on function public.decline_nipto_call(uuid) to authenticated;

create or replace function public.end_nipto_call(p_call_id uuid, p_reason text default 'hangup')
returns boolean
language plpgsql
security definer
set search_path = ''
as $$
declare v_updated integer;
begin
  if auth.uid() is null then raise exception 'Authentication required'; end if;
  if p_reason not in ('hangup','connection_lost','permission_denied','failed') then
    raise exception 'Invalid call end reason';
  end if;
  update private.call_sessions c
  set state = 'ended', ended_at = pg_catalog.now(), end_reason = p_reason
  where c.id = p_call_id
    and auth.uid() in (c.caller_id,c.callee_id)
    and c.state in ('ringing','accepted');
  get diagnostics v_updated = row_count;
  return v_updated = 1;
end;
$$;
revoke all on function public.end_nipto_call(uuid,text) from public, anon;
grant execute on function public.end_nipto_call(uuid,text) to authenticated;

create or replace function public.expire_nipto_calls()
returns integer
language plpgsql
security definer
set search_path = ''
as $$
declare v_count integer;
begin
  update private.call_sessions c
  set state = case when c.state = 'ringing' then 'missed' else 'ended' end,
      ended_at = pg_catalog.now(),
      end_reason = case when c.state = 'ringing' then 'no_answer' else 'expired' end
  where (c.state = 'ringing' and c.expires_at <= pg_catalog.now())
     or (c.state = 'accepted' and c.answered_at < pg_catalog.now() - interval '12 hours');
  get diagnostics v_count = row_count;
  return v_count;
end;
$$;
revoke all on function public.expire_nipto_calls() from public, anon, authenticated;
grant execute on function public.expire_nipto_calls() to service_role;
