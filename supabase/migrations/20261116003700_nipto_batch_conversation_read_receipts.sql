create or replace function public.mark_conversation_read(p_conversation_id uuid)
returns integer
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_user_id uuid := auth.uid();
  v_updated integer := 0;
begin
  if v_user_id is null then
    raise exception 'Authentication required';
  end if;

  if not exists (
    select 1
    from public.conversation_members cm
    where cm.conversation_id = p_conversation_id
      and cm.user_id = v_user_id
      and cm.membership_state = 'accepted'
  ) then
    raise exception 'Conversation access required';
  end if;

  update public.message_receipts mr
  set delivered_at = coalesce(mr.delivered_at, pg_catalog.now()),
      read_at = coalesce(mr.read_at, pg_catalog.now())
  from public.messages m
  where mr.message_id = m.id
    and mr.conversation_id = p_conversation_id
    and mr.user_id = v_user_id
    and m.conversation_id = p_conversation_id
    and m.sender_id <> v_user_id
    and mr.read_at is null;

  get diagnostics v_updated = row_count;
  return v_updated;
end;
$$;

revoke all on function public.mark_conversation_read(uuid) from public, anon;
grant execute on function public.mark_conversation_read(uuid) to authenticated;
