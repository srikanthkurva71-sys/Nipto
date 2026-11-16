
alter table public.user_preferences
  add column if not exists message_access text not null default 'mutuals'
  check (message_access in ('mutuals','followers','nobody'));

create or replace function private.can_start_direct_chat(p_sender uuid, p_recipient uuid)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select case coalesce((
    select up.message_access
    from public.user_preferences up
    where up.user_id = p_recipient
  ), 'mutuals')
    when 'nobody' then false
    when 'followers' then private.has_accepted_follow(p_sender, p_recipient)
    else private.has_accepted_follow(p_sender, p_recipient)
      and private.has_accepted_follow(p_recipient, p_sender)
  end;
$$;
revoke all on function private.can_start_direct_chat(uuid, uuid) from public, anon, authenticated;

create or replace function public.create_or_get_direct_conversation(p_other_user uuid)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_me uuid := auth.uid();
  v_a uuid;
  v_b uuid;
  v_conversation_id uuid;
begin
  if v_me is null then raise exception 'Authentication required'; end if;
  if p_other_user is null or p_other_user = v_me then raise exception 'Invalid recipient'; end if;
  if private.is_blocked_between(v_me, p_other_user) then raise exception 'This conversation is unavailable'; end if;
  if not exists (select 1 from public.profiles p where p.id = p_other_user and p.account_state = 'active') then
    raise exception 'User not found';
  end if;
  if not private.can_start_direct_chat(v_me, p_other_user) then
    raise exception 'This person only accepts messages from people they follow or follow back.';
  end if;

  v_a := least(v_me, p_other_user);
  v_b := greatest(v_me, p_other_user);
  insert into public.conversations (conversation_type, created_by, direct_user_a, direct_user_b)
  values ('direct', v_me, v_a, v_b)
  on conflict (direct_user_a, direct_user_b) do nothing;
  select c.id into v_conversation_id from public.conversations c
  where c.direct_user_a = v_a and c.direct_user_b = v_b;
  insert into public.conversation_members (conversation_id, user_id, member_role, membership_state)
  values (v_conversation_id, v_a, case when v_a = v_me then 'owner' else 'member' end, 'accepted'),
         (v_conversation_id, v_b, case when v_b = v_me then 'owner' else 'member' end, 'accepted')
  on conflict do nothing;
  return v_conversation_id;
end;
$$;
revoke all on function public.create_or_get_direct_conversation(uuid) from public, anon;
grant execute on function public.create_or_get_direct_conversation(uuid) to authenticated;
