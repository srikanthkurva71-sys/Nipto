-- Nipto connected-account messaging gate.
-- Search remains available for discovery; direct chats require an accepted
-- follow in either direction and no block. Group membership stays independent.

create or replace function public.can_access_conversation_messages(p_conversation_id uuid)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select auth.uid() is not null and exists (
    select 1
      from public.conversations c
      where c.id = p_conversation_id
        and public.is_conversation_member(c.id)
        and (
          c.conversation_type = 'group'
          or (
            c.conversation_type = 'direct'
            and not public.is_blocked_between(c.direct_user_a, c.direct_user_b)
            and (
              public.has_accepted_follow(c.direct_user_a, c.direct_user_b)
              or public.has_accepted_follow(c.direct_user_b, c.direct_user_a)
            )
          )
        )
  );
$$;

revoke all on function public.can_access_conversation_messages(uuid) from public, anon;
grant execute on function public.can_access_conversation_messages(uuid) to authenticated;

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
  if public.is_blocked_between(v_me, p_other_user) then
    raise exception 'This conversation is unavailable';
  end if;
  if not exists (
    select 1 from public.profiles p
    where p.id = p_other_user and p.account_state = 'active'
  ) then
    raise exception 'User not found';
  end if;
  if not (
    public.has_accepted_follow(v_me, p_other_user)
    or public.has_accepted_follow(p_other_user, v_me)
  ) then
    raise exception 'Follow or be followed by this account to start a chat';
  end if;

  v_a := least(v_me, p_other_user);
  v_b := greatest(v_me, p_other_user);
  insert into public.conversations (conversation_type, created_by, direct_user_a, direct_user_b)
  values ('direct', v_me, v_a, v_b)
  on conflict (direct_user_a, direct_user_b) do nothing;

  select c.id into v_conversation_id
    from public.conversations c
   where c.direct_user_a = v_a and c.direct_user_b = v_b;

  insert into public.conversation_members (conversation_id, user_id, member_role)
  values
    (v_conversation_id, v_a, case when v_a = v_me then 'owner' else 'member' end),
    (v_conversation_id, v_b, case when v_b = v_me then 'owner' else 'member' end)
  on conflict do nothing;

  return v_conversation_id;
end;
$$;

revoke all on function public.create_or_get_direct_conversation(uuid) from public, anon;
grant execute on function public.create_or_get_direct_conversation(uuid) to authenticated;

drop policy if exists "messages_read_members" on public.messages;
create policy "messages_read_connected_members" on public.messages for select to authenticated
using (public.can_access_conversation_messages(conversation_id));

drop policy if exists "messages_send_as_self" on public.messages;
create policy "messages_send_connected_as_self" on public.messages for insert to authenticated
with check (
  sender_id = auth.uid()
  and public.can_access_conversation_messages(conversation_id)
  and not exists (
    select 1 from public.conversation_members cm
    where cm.conversation_id = messages.conversation_id
      and cm.user_id <> auth.uid()
      and public.is_blocked_between(auth.uid(), cm.user_id)
  )
);

drop policy if exists "chat_media_read_member" on storage.objects;
create policy "chat_media_read_connected_member" on storage.objects for select to authenticated
using (
  bucket_id = 'chat-media'
  and exists (
    select 1 from public.messages m
    where m.media_path = storage.objects.name
      and public.can_access_conversation_messages(m.conversation_id)
  )
);

-- Account search is open for discovery but private accounts expose only basic
-- identity fields until the viewer's follow request is accepted.
create index if not exists profiles_display_name_search_idx on public.profiles(lower(display_name));

create or replace function public.search_profiles(p_query text, p_limit integer default 20)
returns table (
  id uuid,
  nipto_id text,
  display_name text,
  bio text,
  avatar_path text,
  is_private boolean
)
language sql
stable
security definer
set search_path = ''
as $$
  select
    p.id,
    p.nipto_id,
    p.display_name,
    case
      when not p.is_private or public.has_accepted_follow(auth.uid(), p.id) or p.id = auth.uid()
      then p.bio
      else ''
    end,
    case
      when not p.is_private or public.has_accepted_follow(auth.uid(), p.id) or p.id = auth.uid()
      then p.avatar_path
      else null
    end,
    p.is_private
  from public.profiles p
  where auth.uid() is not null
    and p.account_state = 'active'
    and (
      p.nipto_id like (lower(trim(p_query)) || '%')
      or lower(p.display_name) like (lower(trim(p_query)) || '%')
    )
    and not public.is_blocked_between(auth.uid(), p.id)
    and p.id <> auth.uid()
  order by p.nipto_id
  limit least(greatest(coalesce(p_limit, 20), 1), 30);
$$;

revoke all on function public.search_profiles(text, integer) from public, anon;
grant execute on function public.search_profiles(text, integer) to authenticated;
