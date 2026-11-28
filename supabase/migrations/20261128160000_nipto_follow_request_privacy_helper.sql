-- The follows insert policy needs to inspect the target profile's privacy and
-- account state. profiles_read_visible intentionally hides private profiles
-- until a follow is accepted, so evaluating that query as the requesting user
-- creates a circular dependency. Use a security-definer helper that bypasses
-- profile RLS for this single check, while still enforcing the block rules and
-- the privacy-derived initial status.
create or replace function private.can_create_follow(
  p_follower uuid,
  p_following uuid,
  p_status text
)
returns boolean
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_is_private boolean;
  v_account_state text;
begin
  if p_follower is null or p_following is null or p_follower = p_following then
    return false;
  end if;

  select is_private, account_state
    into v_is_private, v_account_state
    from public.profiles
   where id = p_following;

  if v_account_state is distinct from 'active' then
    return false;
  end if;

  if private.is_blocked_between(p_follower, p_following) then
    return false;
  end if;

  if v_is_private then
    return p_status = 'pending';
  end if;
  return p_status = 'accepted';
end;
$$;

revoke all on function private.can_create_follow(uuid, uuid, text) from public, anon, authenticated;
grant execute on function private.can_create_follow(uuid, uuid, text) to authenticated;

drop policy if exists "follows_create_self" on public.follows;
create policy "follows_create_self" on public.follows for insert to authenticated
with check (
  follower_id = (select auth.uid())
  and private.can_create_follow(follower_id, following_id, status)
);
