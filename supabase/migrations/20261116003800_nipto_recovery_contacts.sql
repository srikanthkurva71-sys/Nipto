-- Trusted Nipto recovery contacts are consent-based and never expose email or credentials.
create table public.account_recovery_contacts (
  id uuid primary key default gen_random_uuid(),
  owner_id uuid not null references public.profiles(id) on delete cascade,
  recovery_user_id uuid not null references public.profiles(id) on delete cascade,
  status text not null default 'pending' check (status in ('pending','accepted','rejected')),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint account_recovery_contacts_no_self check (owner_id <> recovery_user_id),
  constraint account_recovery_contacts_unique_pair unique (owner_id, recovery_user_id)
);
create index account_recovery_contacts_recovery_idx
  on public.account_recovery_contacts(recovery_user_id, status, created_at desc);
alter table public.account_recovery_contacts enable row level security;
revoke all on public.account_recovery_contacts from public, anon, authenticated;

create or replace function public.list_my_recovery_contacts()
returns table (
  request_id uuid,
  owner_id uuid,
  owner_nipto_id text,
  owner_display_name text,
  recovery_user_id uuid,
  recovery_nipto_id text,
  recovery_display_name text,
  status text,
  created_at timestamptz
)
language sql
stable
security definer
set search_path = ''
as $$
  select rc.id, rc.owner_id, owner_profile.nipto_id, owner_profile.display_name,
         rc.recovery_user_id, recovery_profile.nipto_id, recovery_profile.display_name,
         rc.status, rc.created_at
  from public.account_recovery_contacts rc
  join public.profiles owner_profile on owner_profile.id = rc.owner_id
  join public.profiles recovery_profile on recovery_profile.id = rc.recovery_user_id
  where auth.uid() is not null
    and (rc.owner_id = auth.uid() or rc.recovery_user_id = auth.uid())
  order by rc.created_at desc
  limit 20;
$$;
revoke all on function public.list_my_recovery_contacts() from public, anon;
grant execute on function public.list_my_recovery_contacts() to authenticated;

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
  v_pending integer;
begin
  if v_me is null then raise exception 'Authentication required'; end if;
  if p_nipto_id is null or p_nipto_id !~ '^[a-z0-9_]{3,24}$' then
    raise exception 'Enter a valid Nipto ID';
  end if;

  select count(*) into v_pending
  from public.account_recovery_contacts rc
  where rc.owner_id = v_me and rc.status = 'pending';
  if v_pending >= 3 then raise exception 'You can have up to three pending recovery requests'; end if;

  select p.id into v_target
  from public.profiles p
  where p.nipto_id = p_nipto_id and p.account_state = 'active';

  if v_target is null then raise exception 'That Nipto account could not be selected'; end if;
  if v_target = v_me then raise exception 'Choose another Nipto account'; end if;
  if private.is_blocked_between(v_me, v_target) then
    raise exception 'This account cannot be selected';
  end if;

  insert into public.account_recovery_contacts(owner_id, recovery_user_id)
  values (v_me, v_target)
  on conflict (owner_id, recovery_user_id)
  do update set status = 'pending', updated_at = pg_catalog.now()
  returning id into v_id;

  return v_id;
end;
$$;
revoke all on function public.request_recovery_contact(text) from public, anon;
grant execute on function public.request_recovery_contact(text) to authenticated;

create or replace function public.respond_recovery_contact(p_request_id uuid, p_accept boolean)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_me uuid := auth.uid();
begin
  if v_me is null then raise exception 'Authentication required'; end if;
  update public.account_recovery_contacts
  set status = case when p_accept then 'accepted' else 'rejected' end,
      updated_at = pg_catalog.now()
  where id = p_request_id
    and recovery_user_id = v_me
    and status = 'pending';
  if not found then raise exception 'Recovery request not found or already handled'; end if;
end;
$$;
revoke all on function public.respond_recovery_contact(uuid, boolean) from public, anon;
grant execute on function public.respond_recovery_contact(uuid, boolean) to authenticated;

create or replace function public.remove_recovery_contact(p_request_id uuid)
returns void
language plpgsql
security definer
set search_path = ''
as $$
begin
  if auth.uid() is null then raise exception 'Authentication required'; end if;
  delete from public.account_recovery_contacts
  where id = p_request_id
    and (owner_id = auth.uid() or recovery_user_id = auth.uid());
  if not found then raise exception 'Recovery contact not found'; end if;
end;
$$;
revoke all on function public.remove_recovery_contact(uuid) from public, anon;
grant execute on function public.remove_recovery_contact(uuid) to authenticated;
