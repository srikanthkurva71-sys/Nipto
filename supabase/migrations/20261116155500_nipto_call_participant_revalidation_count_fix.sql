-- Revalidate call participants when accepting or signaling, and fix the
-- active-profile cardinality check to count both participant rows.
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
        and not private.is_blocked_between(c.caller_id, c.callee_id)
        and exists (
          select 1 from public.conversation_members cm
          where cm.conversation_id = c.conversation_id
            and cm.user_id = c.caller_id
            and cm.membership_state = 'accepted'
        )
        and exists (
          select 1 from public.conversation_members cm
          where cm.conversation_id = c.conversation_id
            and cm.user_id = c.callee_id
            and cm.membership_state = 'accepted'
        )
        and (
          select pg_catalog.count(*)
          from public.profiles p
          where p.id in (c.caller_id, c.callee_id)
            and p.account_state = 'active'
        ) = 2
    );
$$;
revoke all on function private.can_access_nipto_call_topic() from public, anon;
grant execute on function private.can_access_nipto_call_topic() to authenticated;

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
  join public.profiles p
    on p.id = c.caller_id and p.account_state = 'active'
  join public.profiles callee
    on callee.id = c.callee_id and callee.account_state = 'active'
  where auth.uid() is not null
    and c.callee_id = auth.uid()
    and c.state = 'ringing'
    and c.expires_at > pg_catalog.now()
    and not private.is_blocked_between(auth.uid(), c.caller_id)
    and exists (
      select 1 from public.conversation_members cm
      where cm.conversation_id = c.conversation_id
        and cm.user_id = c.caller_id
        and cm.membership_state = 'accepted'
    )
    and exists (
      select 1 from public.conversation_members cm
      where cm.conversation_id = c.conversation_id
        and cm.user_id = c.callee_id
        and cm.membership_state = 'accepted'
    )
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
  set state = 'accepted',
      answered_at = pg_catalog.now(),
      expires_at = pg_catalog.now() + interval '12 hours'
  where c.id = p_call_id
    and c.callee_id = auth.uid()
    and c.state = 'ringing'
    and c.expires_at > pg_catalog.now()
    and not private.is_blocked_between(c.caller_id, c.callee_id)
    and exists (
      select 1 from public.conversation_members cm
      where cm.conversation_id = c.conversation_id
        and cm.user_id = c.caller_id
        and cm.membership_state = 'accepted'
    )
    and exists (
      select 1 from public.conversation_members cm
      where cm.conversation_id = c.conversation_id
        and cm.user_id = c.callee_id
        and cm.membership_state = 'accepted'
    )
    and (
      select pg_catalog.count(*)
      from public.profiles p
      where p.id in (c.caller_id, c.callee_id)
        and p.account_state = 'active'
    ) = 2
  returning c.id, c.conversation_id, c.caller_id, c.media_type, c.state;
  if not found then raise exception 'This call is no longer available'; end if;
end;
$$;
revoke all on function public.accept_nipto_call(uuid) from public, anon;
grant execute on function public.accept_nipto_call(uuid) to authenticated;

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

  if (
    select pg_catalog.count(*)
    from public.profiles p
    where p.id in (v_me, v_callee)
      and p.account_state = 'active'
  ) <> 2 then
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
  set state = case when c.state = 'ringing' then 'expired' else 'ended' end,
      ended_at = pg_catalog.now(),
      end_reason = case when c.state = 'ringing' then 'ring_timeout' else 'session_expired' end
  where c.conversation_id = p_conversation_id
    and c.state in ('ringing','accepted')
    and c.expires_at <= pg_catalog.now();

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
