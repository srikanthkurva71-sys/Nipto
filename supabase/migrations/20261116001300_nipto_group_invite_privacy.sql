
-- Group invitations follow the recipient's same message-access policy as direct chats.
create or replace function public.create_group_conversation(p_title text, p_member_ids uuid[])
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_me uuid := auth.uid();
  v_conversation_id uuid;
  v_member_count integer;
  v_unique_count integer;
  v_invalid_count integer;
begin
  if v_me is null then raise exception 'Authentication required'; end if;
  if p_title is null or char_length(trim(p_title)) not between 1 and 80 then
    raise exception 'Group name must be 1 to 80 characters';
  end if;

  v_member_count := coalesce(cardinality(p_member_ids), 0);
  if v_member_count < 1 or v_member_count > 49 then
    raise exception 'Choose between 1 and 49 other members';
  end if;

  select count(distinct requested.id), count(*)
    into v_unique_count, v_member_count
  from unnest(p_member_ids) as requested(id);

  if v_unique_count <> v_member_count or v_unique_count <> cardinality(p_member_ids) then
    raise exception 'Duplicate group members are not allowed';
  end if;
  if v_me = any(p_member_ids) then
    raise exception 'Do not include yourself in the member list';
  end if;

  select count(*) into v_invalid_count
  from unnest(p_member_ids) as requested(id)
  left join public.profiles p
    on p.id = requested.id and p.account_state = 'active'
  where p.id is null
    or private.is_blocked_between(v_me, requested.id)
    or not private.can_start_direct_chat(v_me, requested.id);

  if v_invalid_count > 0 then
    raise exception 'One or more people do not accept this group invitation';
  end if;

  insert into public.conversations (conversation_type, title, created_by)
  values ('group', trim(p_title), v_me)
  returning id into v_conversation_id;

  insert into public.conversation_members (conversation_id, user_id, member_role, membership_state)
  values (v_conversation_id, v_me, 'owner', 'accepted');

  insert into public.conversation_members (conversation_id, user_id, member_role, membership_state)
  select v_conversation_id, requested.id, 'member', 'invited'
  from unnest(p_member_ids) as requested(id);

  return v_conversation_id;
end;
$$;
revoke all on function public.create_group_conversation(text, uuid[]) from public, anon;
grant execute on function public.create_group_conversation(text, uuid[]) to authenticated;
