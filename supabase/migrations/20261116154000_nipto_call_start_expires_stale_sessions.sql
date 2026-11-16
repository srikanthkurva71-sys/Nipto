-- Expire stale accepted sessions as well as unanswered ringing sessions
-- before creating another call in the same conversation.
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
