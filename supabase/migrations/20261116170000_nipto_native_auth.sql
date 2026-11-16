-- Nipto-native authentication for hosted Supabase Custom OIDC.
-- STAGED: do not apply to production until Nipto OIDC endpoints, Custom OIDC
-- issuer trust, client session storage, and the full test suite are ready.
-- Existing profile UUIDs and social data are preserved. auth.users rows are not
-- deleted; new Nipto identities are created directly in public.profiles.

create table private.nipto_accounts (
  user_id uuid primary key references public.profiles(id) on delete cascade,
  password_hash text not null
    check (password_hash like '$argon2id$%' and char_length(password_hash) between 32 and 512),
  credential_version bigint not null default 1 check (credential_version > 0),
  status text not null default 'active' check (status in ('active','locked','disabled')),
  password_changed_at timestamptz not null default pg_catalog.now(),
  created_at timestamptz not null default pg_catalog.now(),
  updated_at timestamptz not null default pg_catalog.now()
);

create table private.nipto_sessions (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references private.nipto_accounts(user_id) on delete cascade,
  refresh_token_hash text not null unique check (refresh_token_hash ~ '^[a-f0-9]{64}$'),
  device_label text check (device_label is null or char_length(device_label) <= 80),
  created_at timestamptz not null default pg_catalog.now(),
  expires_at timestamptz not null,
  last_used_at timestamptz not null default pg_catalog.now(),
  revoked_at timestamptz,
  rotated_to uuid references private.nipto_sessions(id) on delete set null,
  check (expires_at > created_at)
);
create index nipto_sessions_user_active_idx
  on private.nipto_sessions(user_id, expires_at desc) where revoked_at is null;

create table private.nipto_recovery_challenges (
  id uuid primary key default gen_random_uuid(),
  owner_id uuid not null references private.nipto_accounts(user_id) on delete cascade,
  recovery_user_id uuid not null references public.profiles(id) on delete cascade,
  challenge_hash text not null check (challenge_hash ~ '^[a-f0-9]{64}$'),
  status text not null default 'pending'
    check (status in ('pending','approved','rejected','expired','consumed')),
  created_at timestamptz not null default pg_catalog.now(),
  expires_at timestamptz not null,
  approved_at timestamptz,
  rejected_at timestamptz,
  consumed_at timestamptz,
  check (owner_id <> recovery_user_id),
  check (expires_at > created_at)
);
create unique index nipto_recovery_one_pending_per_owner_idx
  on private.nipto_recovery_challenges(owner_id) where status = 'pending';
create index nipto_recovery_inbox_idx
  on private.nipto_recovery_challenges(recovery_user_id, created_at desc)
  where status = 'pending';

create table private.nipto_password_reset_grants (
  id uuid primary key default gen_random_uuid(),
  challenge_id uuid not null unique
    references private.nipto_recovery_challenges(id) on delete cascade,
  owner_id uuid not null references private.nipto_accounts(user_id) on delete cascade,
  grant_hash text not null unique check (grant_hash ~ '^[a-f0-9]{64}$'),
  created_at timestamptz not null default pg_catalog.now(),
  expires_at timestamptz not null,
  consumed_at timestamptz,
  check (expires_at > created_at)
);

create table private.nipto_security_events (
  id bigint generated always as identity primary key,
  user_id uuid references private.nipto_accounts(user_id) on delete set null,
  event_type text not null check (event_type in (
    'account_created','account_migrated','password_changed','password_reset',
    'session_created','session_rotated','session_revoked',
    'recovery_requested','recovery_approved','recovery_rejected'
  )),
  created_at timestamptz not null default pg_catalog.now(),
  metadata jsonb not null default '{}'::jsonb
);
create index nipto_security_events_user_created_idx
  on private.nipto_security_events(user_id, created_at desc);

alter table private.nipto_accounts enable row level security;
alter table private.nipto_sessions enable row level security;
alter table private.nipto_recovery_challenges enable row level security;
alter table private.nipto_password_reset_grants enable row level security;
alter table private.nipto_security_events enable row level security;
revoke all on private.nipto_accounts, private.nipto_sessions,
  private.nipto_recovery_challenges, private.nipto_password_reset_grants,
  private.nipto_security_events from public, anon, authenticated;

-- Existing profiles used auth.users as their UUID source. Native Nipto identities
-- create profile UUIDs directly; keep old auth.users rows untouched.
alter table public.profiles drop constraint if exists profiles_id_fkey;

-- Application ownership and moderation history must reference the stable Nipto
-- profile UUID, not the legacy Supabase Auth row. This allows the legacy Auth
-- identity (which may contain an email) to be deleted after successful migration.
alter table public.posts drop constraint if exists posts_moderation_reviewed_by_fkey;
alter table public.posts add constraint posts_moderation_reviewed_by_fkey
  foreign key (moderation_reviewed_by) references public.profiles(id) on delete set null;

alter table public.shorts drop constraint if exists shorts_moderation_reviewed_by_fkey;
alter table public.shorts add constraint shorts_moderation_reviewed_by_fkey
  foreign key (moderation_reviewed_by) references public.profiles(id) on delete set null;

alter table public.user_feedback drop constraint if exists user_feedback_reviewed_by_fkey;
alter table public.user_feedback add constraint user_feedback_reviewed_by_fkey
  foreign key (reviewed_by) references public.profiles(id) on delete set null;

alter table public.user_reports drop constraint if exists user_reports_reviewed_by_fkey;
alter table public.user_reports add constraint user_reports_reviewed_by_fkey
  foreign key (reviewed_by) references public.profiles(id) on delete set null;

alter table private.staff_action_log drop constraint if exists staff_action_log_actor_id_fkey;
alter table private.staff_action_log add constraint staff_action_log_actor_id_fkey
  foreign key (actor_id) references public.profiles(id) on delete restrict;

alter table private.staff_roles drop constraint if exists staff_roles_user_id_fkey;
alter table private.staff_roles add constraint staff_roles_user_id_fkey
  foreign key (user_id) references public.profiles(id) on delete cascade;

alter table private.staff_roles drop constraint if exists staff_roles_granted_by_fkey;
alter table private.staff_roles add constraint staff_roles_granted_by_fkey
  foreign key (granted_by) references public.profiles(id) on delete set null;

create or replace function public.nipto_native_register(
  p_nipto_id text,
  p_display_name text,
  p_password_hash text,
  p_recovery_nipto_id text default null
)
returns table(user_id uuid, recovery_request_id uuid)
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_user_id uuid := gen_random_uuid();
  v_nipto_id text := lower(trim(coalesce(p_nipto_id, '')));
  v_display_name text := trim(coalesce(p_display_name, ''));
  v_recovery_id uuid;
  v_recovery_request uuid;
begin
  if v_nipto_id !~ '^[a-z0-9_]{3,24}$'
     or v_nipto_id = any(array['admin','administrator','support','help','nipto','official','security','moderator']) then
    raise exception 'Invalid Nipto ID';
  end if;
  if char_length(v_display_name) not between 1 and 50 then
    raise exception 'Invalid display name';
  end if;
  if p_password_hash is null or p_password_hash not like '$argon2id$%'
     or char_length(p_password_hash) not between 32 and 512 then
    raise exception 'Invalid password hash';
  end if;

  insert into public.profiles(id, nipto_id, display_name)
  values (v_user_id, v_nipto_id, v_display_name);

  insert into private.nipto_accounts(user_id, password_hash)
  values (v_user_id, p_password_hash);

  insert into private.nipto_security_events(user_id, event_type)
  values (v_user_id, 'account_created');

  if nullif(trim(coalesce(p_recovery_nipto_id, '')), '') is not null then
    select p.id into v_recovery_id
    from public.profiles p
    join private.nipto_accounts recovery_account
      on recovery_account.user_id = p.id and recovery_account.status = 'active'
    where p.nipto_id = lower(trim(p_recovery_nipto_id))
      and p.account_state = 'active';

    if v_recovery_id is null or v_recovery_id = v_user_id then
      raise exception 'Recovery Nipto account could not be selected';
    end if;
    if private.is_blocked_between(v_user_id, v_recovery_id) then
      raise exception 'Recovery Nipto account could not be selected';
    end if;

    insert into public.account_recovery_contacts(owner_id, recovery_user_id)
    values (v_user_id, v_recovery_id)
    returning id into v_recovery_request;
  end if;

  return query select v_user_id, v_recovery_request;
end;
$$;
revoke all on function public.nipto_native_register(text,text,text,text) from public, anon, authenticated;
grant execute on function public.nipto_native_register(text,text,text,text) to service_role;

create or replace function public.nipto_native_login_record(p_nipto_id text)
returns table(user_id uuid, password_hash text, account_state text, nipto_id text, display_name text)
language sql
stable
security definer
set search_path = ''
as $$
  select a.user_id, a.password_hash, p.account_state, p.nipto_id, p.display_name
  from private.nipto_accounts a
  join public.profiles p on p.id = a.user_id
  where p.nipto_id = lower(trim(coalesce(p_nipto_id, '')))
    and a.status = 'active'
    and p.account_state = 'active'
  limit 1;
$$;
revoke all on function public.nipto_native_login_record(text) from public, anon, authenticated;
grant execute on function public.nipto_native_login_record(text) to service_role;

create or replace function public.nipto_native_create_session(
  p_user_id uuid,
  p_refresh_token_hash text,
  p_expires_at timestamptz,
  p_device_label text default null
)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare v_session_id uuid;
begin
  if p_refresh_token_hash !~ '^[a-f0-9]{64}$'
     or p_expires_at <= pg_catalog.now()
     or p_expires_at > pg_catalog.now() + interval '90 days' then
    raise exception 'Invalid session parameters';
  end if;
  if not exists (
    select 1 from private.nipto_accounts a
    join public.profiles p on p.id = a.user_id
    where a.user_id = p_user_id and a.status = 'active'
      and p.account_state = 'active'
  ) then raise exception 'Account unavailable'; end if;

  -- Keep a bounded number of active device sessions per account.
  update private.nipto_sessions s
    set revoked_at = pg_catalog.now()
    where s.id in (
      select old_session.id
      from private.nipto_sessions old_session
      where old_session.user_id = p_user_id and old_session.revoked_at is null
      order by old_session.created_at desc
      offset 9
    );

  insert into private.nipto_sessions(user_id, refresh_token_hash, expires_at, device_label)
  values (p_user_id, p_refresh_token_hash, p_expires_at, left(p_device_label, 80))
  returning id into v_session_id;

  insert into private.nipto_security_events(user_id, event_type)
  values (p_user_id, 'session_created');
  return v_session_id;
end;
$$;
revoke all on function public.nipto_native_create_session(uuid,text,timestamptz,text) from public, anon, authenticated;
grant execute on function public.nipto_native_create_session(uuid,text,timestamptz,text) to service_role;

create or replace function public.nipto_native_rotate_session(
  p_old_refresh_token_hash text,
  p_new_refresh_token_hash text,
  p_new_expires_at timestamptz
)
returns table(user_id uuid, session_id uuid)
language plpgsql
security definer
set search_path = ''
as $$
declare v_old private.nipto_sessions%rowtype; v_new_id uuid;
begin
  if p_old_refresh_token_hash !~ '^[a-f0-9]{64}$'
     or p_new_refresh_token_hash !~ '^[a-f0-9]{64}$'
     or p_new_expires_at <= pg_catalog.now()
     or p_new_expires_at > pg_catalog.now() + interval '90 days' then
    return;
  end if;

  select * into v_old from private.nipto_sessions s
  where s.refresh_token_hash = p_old_refresh_token_hash for update;
  if not found then return; end if;

  if v_old.revoked_at is not null then
    update private.nipto_sessions s set revoked_at = coalesce(s.revoked_at, pg_catalog.now())
    where s.user_id = v_old.user_id;
    insert into private.nipto_security_events(user_id, event_type)
    values (v_old.user_id, 'session_revoked');
    return;
  end if;

  if v_old.expires_at <= pg_catalog.now() or not exists (
    select 1 from private.nipto_accounts a join public.profiles p on p.id=a.user_id
    where a.user_id=v_old.user_id and a.status='active' and p.account_state='active'
  ) then
    update private.nipto_sessions s set revoked_at=pg_catalog.now() where s.id=v_old.id;
    return;
  end if;

  update private.nipto_sessions s
    set revoked_at=pg_catalog.now(), last_used_at=pg_catalog.now()
    where s.id=v_old.id;

  insert into private.nipto_sessions(user_id,refresh_token_hash,expires_at,device_label)
  values(v_old.user_id,p_new_refresh_token_hash,p_new_expires_at,v_old.device_label)
  returning id into v_new_id;

  update private.nipto_sessions s set rotated_to=v_new_id where s.id=v_old.id;
  insert into private.nipto_security_events(user_id,event_type)
  values(v_old.user_id,'session_rotated');

  return query select v_old.user_id,v_new_id;
end;
$$;
revoke all on function public.nipto_native_rotate_session(text,text,timestamptz) from public, anon, authenticated;
grant execute on function public.nipto_native_rotate_session(text,text,timestamptz) to service_role;

create or replace function public.nipto_native_revoke_session(
  p_user_id uuid, p_session_id uuid
)
returns boolean
language plpgsql
security definer
set search_path = ''
as $$
declare v_count integer;
begin
  update private.nipto_sessions s set revoked_at=pg_catalog.now()
  where s.id=p_session_id and s.user_id=p_user_id and s.revoked_at is null;
  get diagnostics v_count=row_count;
  if v_count=1 then
    insert into private.nipto_security_events(user_id,event_type)
    values(p_user_id,'session_revoked');
  end if;
  return v_count=1;
end;
$$;
revoke all on function public.nipto_native_revoke_session(uuid,uuid) from public, anon, authenticated;
grant execute on function public.nipto_native_revoke_session(uuid,uuid) to service_role;

create or replace function public.nipto_native_revoke_all_sessions(p_user_id uuid)
returns integer
language plpgsql
security definer
set search_path = ''
as $$
declare v_count integer;
begin
  update private.nipto_sessions s set revoked_at=pg_catalog.now()
  where s.user_id=p_user_id and s.revoked_at is null;
  get diagnostics v_count=row_count;
  insert into private.nipto_security_events(user_id,event_type)
  values(p_user_id,'session_revoked');
  return v_count;
end;
$$;
revoke all on function public.nipto_native_revoke_all_sessions(uuid) from public, anon, authenticated;
grant execute on function public.nipto_native_revoke_all_sessions(uuid) to service_role;

create or replace function public.nipto_native_request_recovery_contact(
  p_owner_id uuid, p_nipto_id text
)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare v_target uuid; v_id uuid;
begin
  select p.id into v_target
  from public.profiles p
  join private.nipto_accounts target_account
    on target_account.user_id=p.id and target_account.status='active'
  where p.nipto_id=lower(trim(coalesce(p_nipto_id,'')))
    and p.account_state='active';
  if v_target is null or v_target=p_owner_id
     or not exists(select 1 from private.nipto_accounts a where a.user_id=p_owner_id and a.status='active')
     or private.is_blocked_between(p_owner_id,v_target) then
    raise exception 'Recovery Nipto account could not be selected';
  end if;

  if exists (
    select 1 from public.account_recovery_contacts rc
    where rc.owner_id=p_owner_id and rc.status in ('pending','accepted')
      and rc.recovery_user_id<>v_target
  ) then raise exception 'Remove the existing recovery account before choosing another'; end if;

  insert into public.account_recovery_contacts(owner_id,recovery_user_id)
  values(p_owner_id,v_target)
  on conflict(owner_id,recovery_user_id) do update
    set status='pending',updated_at=pg_catalog.now()
  returning id into v_id;
  return v_id;
end;
$$;
revoke all on function public.nipto_native_request_recovery_contact(uuid,text) from public, anon, authenticated;
grant execute on function public.nipto_native_request_recovery_contact(uuid,text) to service_role;

create or replace function public.nipto_native_list_recovery_contacts(p_user_id uuid)
returns table(
  request_id uuid, owner_id uuid, owner_nipto_id text, owner_display_name text,
  recovery_user_id uuid, recovery_nipto_id text, recovery_display_name text,
  status text, created_at timestamptz
)
language sql stable security definer set search_path=''
as $$
  select rc.id,rc.owner_id,op.nipto_id,op.display_name,
         rc.recovery_user_id,rp.nipto_id,rp.display_name,rc.status,rc.created_at
  from public.account_recovery_contacts rc
  join public.profiles op on op.id=rc.owner_id
  join public.profiles rp on rp.id=rc.recovery_user_id
  where rc.owner_id=p_user_id or rc.recovery_user_id=p_user_id
  order by rc.created_at desc limit 20;
$$;
revoke all on function public.nipto_native_list_recovery_contacts(uuid) from public, anon, authenticated;
grant execute on function public.nipto_native_list_recovery_contacts(uuid) to service_role;

create or replace function public.nipto_native_respond_recovery_contact(
  p_request_id uuid, p_recovery_user_id uuid, p_accept boolean
)
returns boolean
language plpgsql security definer set search_path=''
as $$
declare v_owner uuid;
begin
  update public.account_recovery_contacts rc
    set status=case when p_accept then 'accepted' else 'rejected' end,
        updated_at=pg_catalog.now()
  where rc.id=p_request_id and rc.recovery_user_id=p_recovery_user_id
    and rc.status='pending'
    and exists (
      select 1 from private.nipto_accounts a
      join public.profiles op on op.id=a.user_id
      join public.profiles rp on rp.id=rc.recovery_user_id
      join private.nipto_accounts recovery_account
        on recovery_account.user_id=rp.id and recovery_account.status='active'
      where a.user_id=rc.owner_id and a.status='active'
        and op.account_state='active' and rp.account_state='active'
        and not private.is_blocked_between(rc.owner_id,rc.recovery_user_id)
    )
  returning rc.owner_id into v_owner;
  if v_owner is null then return false; end if;
  insert into private.nipto_security_events(user_id,event_type)
  values(v_owner,case when p_accept then 'recovery_approved' else 'recovery_rejected' end);
  return true;
end;
$$;
revoke all on function public.nipto_native_respond_recovery_contact(uuid,uuid,boolean) from public, anon, authenticated;
grant execute on function public.nipto_native_respond_recovery_contact(uuid,uuid,boolean) to service_role;

create or replace function public.nipto_native_start_recovery(
  p_nipto_id text, p_challenge_hash text
)
returns table(challenge_id uuid, owner_id uuid, recovery_user_id uuid)
language plpgsql security definer set search_path=''
as $$
declare v_owner uuid; v_recovery uuid; v_challenge uuid;
begin
  if p_challenge_hash !~ '^[a-f0-9]{64}$' then return; end if;
  select p.id into v_owner
  from public.profiles p join private.nipto_accounts a on a.user_id=p.id
  where p.nipto_id=lower(trim(coalesce(p_nipto_id,'')))
    and p.account_state='active' and a.status='active';
  if v_owner is null then return; end if;

  select rc.recovery_user_id into v_recovery
  from public.account_recovery_contacts rc
  join public.profiles rp on rp.id=rc.recovery_user_id
  join private.nipto_accounts recovery_account
    on recovery_account.user_id=rp.id and recovery_account.status='active'
  where rc.owner_id=v_owner and rc.status='accepted'
    and rp.account_state='active'
    and not private.is_blocked_between(v_owner,rc.recovery_user_id)
  limit 1;
  if v_recovery is null then return; end if;

  update private.nipto_recovery_challenges c set status='expired'
  where c.owner_id=v_owner and c.status='pending' and c.expires_at<=pg_catalog.now();
  if exists(select 1 from private.nipto_recovery_challenges c
    where c.owner_id=v_owner and c.status='pending' and c.expires_at>pg_catalog.now()) then
    return;
  end if;

  insert into private.nipto_recovery_challenges(
    owner_id,recovery_user_id,challenge_hash,expires_at
  ) values(v_owner,v_recovery,p_challenge_hash,pg_catalog.now()+interval '15 minutes')
  returning id into v_challenge;

  insert into public.notifications(recipient_id,actor_id,notification_type,payload)
  values(v_recovery,v_owner,'system',
    jsonb_build_object('kind','password_recovery_request','challenge_id',v_challenge));

  insert into private.nipto_security_events(user_id,event_type)
  values(v_owner,'recovery_requested');
  return query select v_challenge,v_owner,v_recovery;
end;
$$;
revoke all on function public.nipto_native_start_recovery(text,text) from public, anon, authenticated;
grant execute on function public.nipto_native_start_recovery(text,text) to service_role;

create or replace function public.nipto_native_list_recovery_requests(p_recovery_user_id uuid)
returns table(challenge_id uuid, owner_id uuid, owner_nipto_id text, owner_display_name text, created_at timestamptz, expires_at timestamptz)
language sql stable security definer set search_path=''
as $$
  select c.id,c.owner_id,p.nipto_id,p.display_name,c.created_at,c.expires_at
  from private.nipto_recovery_challenges c
  join public.profiles p on p.id=c.owner_id
  where c.recovery_user_id=p_recovery_user_id
    and c.status='pending' and c.expires_at>pg_catalog.now()
  order by c.created_at desc limit 10;
$$;
revoke all on function public.nipto_native_list_recovery_requests(uuid) from public, anon, authenticated;
grant execute on function public.nipto_native_list_recovery_requests(uuid) to service_role;

create or replace function public.nipto_native_respond_password_recovery(
  p_challenge_id uuid, p_recovery_user_id uuid, p_approve boolean
)
returns boolean
language plpgsql security definer set search_path=''
as $$
declare v_owner uuid;
begin
  update private.nipto_recovery_challenges c
    set status=case when p_approve then 'approved' else 'rejected' end,
        approved_at=case when p_approve then pg_catalog.now() else null end,
        rejected_at=case when p_approve then null else pg_catalog.now() end
  where c.id=p_challenge_id and c.recovery_user_id=p_recovery_user_id
    and c.status='pending' and c.expires_at>pg_catalog.now()
    and exists(
      select 1 from public.account_recovery_contacts rc
      join public.profiles op on op.id=rc.owner_id
      join public.profiles rp on rp.id=rc.recovery_user_id
      join private.nipto_accounts a on a.user_id=rc.owner_id
      join private.nipto_accounts recovery_account
        on recovery_account.user_id=rp.id and recovery_account.status='active'
      where rc.owner_id=c.owner_id and rc.recovery_user_id=c.recovery_user_id
        and rc.status='accepted' and op.account_state='active'
        and rp.account_state='active' and a.status='active'
        and not private.is_blocked_between(rc.owner_id,rc.recovery_user_id)
    )
  returning c.owner_id into v_owner;
  if v_owner is null then return false; end if;
  insert into private.nipto_security_events(user_id,event_type)
  values(v_owner,case when p_approve then 'recovery_approved' else 'recovery_rejected' end);
  insert into public.notifications(recipient_id,actor_id,notification_type,payload)
  values(v_owner,p_recovery_user_id,'system',
    jsonb_build_object('kind',case when p_approve then 'password_recovery_approved' else 'password_recovery_rejected' end));
  return true;
end;
$$;
revoke all on function public.nipto_native_respond_password_recovery(uuid,uuid,boolean) from public, anon, authenticated;
grant execute on function public.nipto_native_respond_password_recovery(uuid,uuid,boolean) to service_role;

create or replace function public.nipto_native_claim_reset_grant(
  p_challenge_id uuid, p_challenge_hash text, p_grant_hash text
)
returns uuid
language plpgsql security definer set search_path=''
as $$
declare v_owner uuid;
begin
  if p_challenge_hash !~ '^[a-f0-9]{64}$' or p_grant_hash !~ '^[a-f0-9]{64}$' then return null; end if;
  select c.owner_id into v_owner
  from private.nipto_recovery_challenges c
  where c.id=p_challenge_id and c.challenge_hash=p_challenge_hash
    and c.status='approved' and c.expires_at>pg_catalog.now()
    and exists (
      select 1
      from public.account_recovery_contacts rc
      join public.profiles op on op.id=rc.owner_id
      join public.profiles rp on rp.id=rc.recovery_user_id
      where rc.owner_id=c.owner_id and rc.recovery_user_id=c.recovery_user_id
        and rc.status='accepted' and op.account_state='active'
        and rp.account_state='active'
        and not private.is_blocked_between(rc.owner_id,rc.recovery_user_id)
    )
  for update;
  if v_owner is null then return null; end if;

  insert into private.nipto_password_reset_grants(challenge_id,owner_id,grant_hash,expires_at)
  values(p_challenge_id,v_owner,p_grant_hash,pg_catalog.now()+interval '10 minutes')
  on conflict(challenge_id) do nothing;
  if not found then return null; end if;

  update private.nipto_recovery_challenges c
  set status='consumed',consumed_at=pg_catalog.now()
  where c.id=p_challenge_id;
  return v_owner;
end;
$$;
revoke all on function public.nipto_native_claim_reset_grant(uuid,text,text) from public, anon, authenticated;
grant execute on function public.nipto_native_claim_reset_grant(uuid,text,text) to service_role;

create or replace function public.nipto_native_consume_reset_grant(
  p_grant_hash text, p_new_password_hash text
)
returns uuid
language plpgsql security definer set search_path=''
as $$
declare v_grant private.nipto_password_reset_grants%rowtype;
begin
  if p_grant_hash !~ '^[a-f0-9]{64}$'
     or p_new_password_hash is null or p_new_password_hash not like '$argon2id$%'
     or char_length(p_new_password_hash) not between 32 and 512 then return null; end if;

  select * into v_grant from private.nipto_password_reset_grants g
  where g.grant_hash=p_grant_hash for update;
  if not found or v_grant.consumed_at is not null
     or v_grant.expires_at<=pg_catalog.now()
     or not exists (
       select 1 from private.nipto_accounts a
       join public.profiles p on p.id=a.user_id
       where a.user_id=v_grant.owner_id and a.status='active'
         and p.account_state='active'
     ) then return null; end if;

  update private.nipto_password_reset_grants g
    set consumed_at=pg_catalog.now() where g.id=v_grant.id;
  update private.nipto_accounts a
    set password_hash=p_new_password_hash,
        credential_version=credential_version+1,
        password_changed_at=pg_catalog.now(),updated_at=pg_catalog.now()
    where a.user_id=v_grant.owner_id;
  update private.nipto_sessions s set revoked_at=pg_catalog.now()
    where s.user_id=v_grant.owner_id and s.revoked_at is null;
  insert into private.nipto_security_events(user_id,event_type)
  values(v_grant.owner_id,'password_reset');
  return v_grant.owner_id;
end;
$$;
revoke all on function public.nipto_native_consume_reset_grant(text,text) from public, anon, authenticated;
grant execute on function public.nipto_native_consume_reset_grant(text,text) to service_role;

create or replace function public.nipto_native_change_password(
  p_user_id uuid, p_new_password_hash text
)
returns boolean
language plpgsql security definer set search_path=''
as $$
begin
  if p_new_password_hash is null or p_new_password_hash not like '$argon2id$%'
     or char_length(p_new_password_hash) not between 32 and 512 then return false; end if;
  update private.nipto_accounts a
    set password_hash=p_new_password_hash,
        credential_version=credential_version+1,
        password_changed_at=pg_catalog.now(),updated_at=pg_catalog.now()
    where a.user_id=p_user_id and a.status='active';
  if not found then return false; end if;
  update private.nipto_sessions s set revoked_at=pg_catalog.now()
    where s.user_id=p_user_id and s.revoked_at is null;
  insert into private.nipto_security_events(user_id,event_type)
  values(p_user_id,'password_changed');
  return true;
end;
$$;
revoke all on function public.nipto_native_change_password(uuid,text) from public, anon, authenticated;
grant execute on function public.nipto_native_change_password(uuid,text) to service_role;
