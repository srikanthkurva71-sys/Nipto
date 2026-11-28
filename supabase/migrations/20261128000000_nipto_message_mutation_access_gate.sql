-- Close the mutation side of the connected-chat gate.
--
-- edit_own_message and delete_own_message already required authorship and an
-- accepted conversation membership, but unlike message reads they did not
-- recheck the direct-chat follow/block state. A user who was unfollowed or
-- blocked could therefore still mutate a message they had sent earlier.
-- Reuse the same read-access helper so mutation and visibility agree.

create or replace function public.edit_own_message(
  p_message_id uuid,
  p_body text
)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_user_id uuid := auth.uid();
  v_body text := btrim(coalesce(p_body, ''));
begin
  if v_user_id is null then
    raise exception 'Authentication required' using errcode = '28000';
  end if;

  if v_body = '' or char_length(v_body) > 10000 then
    raise exception 'Message text must contain 1 to 10000 characters'
      using errcode = '22023';
  end if;

  update public.messages as m
     set body = v_body,
         edited_at = now()
   where m.id = p_message_id
     and m.sender_id = v_user_id
     and m.message_type = 'text'
     and m.deleted_at is null
     and public.can_access_conversation_messages(m.conversation_id);

  if not found then
    raise exception 'Message not found or cannot be edited'
      using errcode = '42501';
  end if;
end;
$$;

create or replace function public.delete_own_message(
  p_message_id uuid
)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_user_id uuid := auth.uid();
begin
  if v_user_id is null then
    raise exception 'Authentication required' using errcode = '28000';
  end if;

  update public.messages as m
     set deleted_at = now(),
         body = 'Message deleted',
         media_path = null
   where m.id = p_message_id
     and m.sender_id = v_user_id
     and m.deleted_at is null
     and public.can_access_conversation_messages(m.conversation_id);

  if not found then
    raise exception 'Message not found or cannot be deleted'
      using errcode = '42501';
  end if;
end;
$$;

revoke all on function public.edit_own_message(uuid, text) from public, anon;
revoke all on function public.delete_own_message(uuid) from public, anon;
grant execute on function public.edit_own_message(uuid, text) to authenticated;
grant execute on function public.delete_own_message(uuid) to authenticated;
