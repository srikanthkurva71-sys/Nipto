
-- Correct function references after internal helpers were moved to the non-exposed private schema.
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

-- Search must be a prefix lookup, not an empty-prefix directory enumeration.
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
  select p.id, p.nipto_id, p.display_name, p.bio, p.avatar_path, p.is_private
  from public.profiles p
  where auth.uid() is not null
    and length(trim(coalesce(p_query, ''))) >= 2
    and p.account_state = 'active'
    and p.nipto_id like (lower(trim(p_query)) || '%')
    and not private.is_blocked_between(auth.uid(), p.id)
    and p.id <> auth.uid()
  order by p.nipto_id
  limit least(greatest(coalesce(p_limit, 20), 1), 30);
$$;
revoke all on function public.search_profiles(text, integer) from public, anon;
grant execute on function public.search_profiles(text, integer) to authenticated;
