-- Prevent cyclic Nipto recovery relationships.
-- Pending links count as edges because they may be approved later.
-- A transaction-scoped graph lock serializes new links so concurrent requests
-- cannot each pass a stale cycle check and create a cycle together.

create or replace function public.nipto_native_request_recovery_contact(
  p_owner_user_id uuid,
  p_nipto_id text
)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_target uuid;
  v_id uuid;
  v_cycle boolean;
begin
  if not exists(
    select 1
    from private.nipto_accounts a
    join public.profiles p on p.id=a.supabase_user_id
    where a.supabase_user_id=p_owner_user_id
      and a.status='active'
      and p.account_state='active'
  ) then
    raise exception 'Nipto account unavailable';
  end if;

  if p_nipto_id is null
    or p_nipto_id !~ '^[a-z0-9]+(_[a-z0-9]+)*$'
    or char_length(p_nipto_id) not between 3 and 24 then
    raise exception 'Enter a valid Nipto ID';
  end if;

  select p.id into v_target
  from public.profiles p
  join private.nipto_accounts a
    on a.supabase_user_id=p.id and a.status='active'
  where p.nipto_id=p_nipto_id
    and p.account_state='active';

  if v_target is null
    or v_target=p_owner_user_id
    or private.is_blocked_between(p_owner_user_id,v_target) then
    raise exception 'That Nipto account cannot be selected';
  end if;

  -- Serialize graph mutations before checking the current pending/accepted edges.
  perform pg_catalog.pg_advisory_xact_lock(
    pg_catalog.hashtextextended('nipto_recovery_relationship_graph',0)
  );

  if exists(
    select 1
    from public.account_recovery_contacts rc
    where rc.owner_id=p_owner_user_id
      and rc.status in ('pending','accepted')
      and rc.recovery_user_id<>v_target
  ) then
    raise exception 'Remove your current recovery account before choosing another';
  end if;

  if exists(
    select 1
    from public.account_recovery_contacts rc
    where rc.owner_id=p_owner_user_id
      and rc.recovery_user_id=v_target
      and rc.status='accepted'
  ) then
    raise exception 'This is already your recovery account';
  end if;

  with recursive recovery_chain(user_id,path) as (
    select v_target,array[v_target]::uuid[]
    union all
    select rc.recovery_user_id,chain.path || rc.recovery_user_id
    from recovery_chain chain
    join public.account_recovery_contacts rc
      on rc.owner_id=chain.user_id
    where rc.status in ('pending','accepted')
      and not rc.recovery_user_id=any(chain.path)
  )
  select exists(
    select 1 from recovery_chain where user_id=p_owner_user_id
  ) into v_cycle;

  if v_cycle then
    raise exception 'This recovery account would create a circular recovery relationship';
  end if;

  insert into public.account_recovery_contacts(owner_id,recovery_user_id)
  values(p_owner_user_id,v_target)
  on conflict(owner_id,recovery_user_id)
  do update set status='pending',updated_at=pg_catalog.now()
  returning id into v_id;

  return v_id;
end;
$$;

revoke all on function public.nipto_native_request_recovery_contact(uuid,text)
  from public,anon,authenticated;
grant execute on function public.nipto_native_request_recovery_contact(uuid,text)
  to service_role;
