
-- Nipto Social v1.0 functional hardening and realtime setup.
alter table public.conversation_members
  add column if not exists membership_state text not null default 'accepted'
  check (membership_state in ('invited','accepted'));

create or replace function private.is_conversation_member(p_conversation_id uuid)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select auth.uid() is not null and exists (
    select 1 from public.conversation_members cm
    where cm.conversation_id = p_conversation_id
      and cm.user_id = auth.uid()
      and cm.membership_state = 'accepted'
  );
$$;

drop policy "conversation_members_read_members" on public.conversation_members;
create policy "conversation_members_read_self_or_members" on public.conversation_members
for select to authenticated
using (user_id = (select auth.uid()) or private.is_conversation_member(conversation_id));

drop policy "conversations_read_members" on public.conversations;
create policy "conversations_read_members_or_invitees" on public.conversations
for select to authenticated
using (exists (
  select 1 from public.conversation_members cm
  where cm.conversation_id = id and cm.user_id = (select auth.uid())
));

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
  select count(distinct x), count(*) into v_unique_count, v_member_count
  from unnest(p_member_ids) as x;
  if v_unique_count <> v_member_count or v_unique_count <> cardinality(p_member_ids) then
    raise exception 'Duplicate group members are not allowed';
  end if;
  if v_me = any(p_member_ids) then raise exception 'Do not include yourself in the member list'; end if;
  select count(*) into v_invalid_count
  from unnest(p_member_ids) as requested(id)
  left join public.profiles p on p.id = requested.id and p.account_state = 'active'
  where p.id is null or private.is_blocked_between(v_me, requested.id);
  if v_invalid_count > 0 then raise exception 'One or more selected accounts are unavailable'; end if;

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

create or replace function public.accept_group_invitation(p_conversation_id uuid)
returns void
language plpgsql
security definer
set search_path = ''
as $$
begin
  if auth.uid() is null then raise exception 'Authentication required'; end if;
  update public.conversation_members
  set membership_state = 'accepted'
  where conversation_id = p_conversation_id
    and user_id = auth.uid()
    and membership_state = 'invited';
  if not found then raise exception 'Invitation not found'; end if;
end;
$$;

create or replace function public.decline_group_invitation(p_conversation_id uuid)
returns void
language plpgsql
security definer
set search_path = ''
as $$
begin
  if auth.uid() is null then raise exception 'Authentication required'; end if;
  delete from public.conversation_members
  where conversation_id = p_conversation_id
    and user_id = auth.uid()
    and membership_state = 'invited';
  if not found then raise exception 'Invitation not found'; end if;
end;
$$;

revoke all on function public.create_group_conversation(text, uuid[]) from public, anon;
revoke all on function public.accept_group_invitation(uuid) from public, anon;
revoke all on function public.decline_group_invitation(uuid) from public, anon;
grant execute on function public.create_group_conversation(text, uuid[]) to authenticated;
grant execute on function public.accept_group_invitation(uuid) to authenticated;
grant execute on function public.decline_group_invitation(uuid) to authenticated;

-- The following helper is an internal Supabase project function, not an app API.
revoke all on function public.rls_auto_enable() from public, anon, authenticated;

-- Add core live tables to the existing Supabase Realtime publication, when available.
do $$
declare
  v_table text;
begin
  if exists (select 1 from pg_publication where pubname = 'supabase_realtime') then
    foreach v_table in array array['messages','conversation_members','notifications'] loop
      if not exists (
        select 1 from pg_publication_tables
        where pubname = 'supabase_realtime'
          and schemaname = 'public'
          and tablename = v_table
      ) then
        execute format('alter publication supabase_realtime add table public.%I', v_table);
      end if;
    end loop;
  end if;
end;
$$;

comment on column public.conversation_members.membership_state is 'Group members are invited first and must accept before reading or sending messages.';
