-- One selected recovery Nipto account at a time. Existing accepted links must be
-- removed explicitly before a different account can be requested.
create or replace function public.request_recovery_contact(p_nipto_id text)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_me uuid := auth.uid();
  v_target uuid;
  v_id uuid;
begin
  if v_me is null then raise exception 'Authentication required'; end if;
  if p_nipto_id is null or p_nipto_id !~ '^[a-z0-9_]{3,24}$' then
    raise exception 'Enter a valid Nipto ID';
  end if;

  select p.id into v_target
  from public.profiles p
  where p.nipto_id = p_nipto_id and p.account_state = 'active';

  if v_target is null then raise exception 'That Nipto account could not be selected'; end if;
  if v_target = v_me then raise exception 'Choose another Nipto account'; end if;
  if private.is_blocked_between(v_me, v_target) then
    raise exception 'This account cannot be selected';
  end if;

  if exists (
    select 1 from public.account_recovery_contacts rc
    where rc.owner_id = v_me and rc.status in ('pending','accepted')
      and rc.recovery_user_id <> v_target
  ) then
    raise exception 'Remove your existing recovery account before choosing another';
  end if;

  if exists (
    select 1 from public.account_recovery_contacts rc
    where rc.owner_id = v_me and rc.recovery_user_id = v_target
      and rc.status = 'accepted'
  ) then
    raise exception 'This account is already your accepted recovery contact';
  end if;

  insert into public.account_recovery_contacts(owner_id,recovery_user_id)
  values(v_me,v_target)
  on conflict(owner_id,recovery_user_id) do update
    set status='pending',updated_at=pg_catalog.now()
  returning id into v_id;

  return v_id;
end;
$$;
revoke all on function public.request_recovery_contact(text) from public, anon;
grant execute on function public.request_recovery_contact(text) to authenticated;
