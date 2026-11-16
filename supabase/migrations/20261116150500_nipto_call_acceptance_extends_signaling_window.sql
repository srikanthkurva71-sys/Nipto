-- Keep accepted call signaling authorized for the active session lifetime.
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
  returning c.id, c.conversation_id, c.caller_id, c.media_type, c.state;
  if not found then raise exception 'This call is no longer available'; end if;
end;
$$;
revoke all on function public.accept_nipto_call(uuid) from public, anon;
grant execute on function public.accept_nipto_call(uuid) to authenticated;
