
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
  )
  and not exists (
    select 1
    from public.conversation_members other_member
    where other_member.conversation_id = p_conversation_id
      and other_member.user_id <> auth.uid()
      and other_member.membership_state = 'accepted'
      and private.is_blocked_between(auth.uid(), other_member.user_id)
  );
$$;
revoke all on function private.is_conversation_member(uuid) from public, anon, authenticated;

create or replace function public.list_blocked_profiles()
returns table (user_id uuid, nipto_id text, display_name text, created_at timestamptz)
language sql
stable
security definer
set search_path = ''
as $$
  select p.id, p.nipto_id, p.display_name, b.created_at
  from public.blocked_users b
  join public.profiles p on p.id = b.blocked_id
  where b.blocker_id = auth.uid()
  order by b.created_at desc
  limit 200;
$$;
revoke all on function public.list_blocked_profiles() from public, anon;
grant execute on function public.list_blocked_profiles() to authenticated;
