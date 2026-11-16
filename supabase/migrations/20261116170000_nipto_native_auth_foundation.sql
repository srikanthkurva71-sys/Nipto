-- Nipto-native authentication foundation.
-- This migration is intentionally staged in source control only. Do not apply it to
-- the hosted production project. The hosted Supabase project must first be proven
-- to trust the Nipto identity issuer, or the deployment architecture must move to
-- a self-hosted Supabase stack with Nipto's private OIDC provider. See
-- docs/NIPTO_NATIVE_AUTH_DESIGN.md, section 9.

-- Decouple the profile identity UUID from Supabase Auth. Existing profile UUIDs
-- remain unchanged; native Nipto registration can now create profiles directly.
-- Existing auth.users rows are intentionally not deleted by this migration.
alter table public.profiles drop constraint if exists profiles_id_fkey;

create table private.nipto_accounts (
  user_id uuid primary key references public.profiles(id) on delete cascade,
  password_hash text not null
    check (password_hash like '$argon2id$%' and char_length(password_hash) between 32 and 512),
  credential_version bigint not null default 1 check (credential_version > 0),
  password_changed_at timestamptz not null default pg_catalog.now(),
  created_at timestamptz not null default pg_catalog.now(),
  updated_at timestamptz not null default pg_catalog.now()
);

create table private.nipto_sessions (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references private.nipto_accounts(user_id) on delete cascade,
  refresh_token_hash bytea not null unique check (octet_length(refresh_token_hash) = 32),
  device_label text check (device_label is null or char_length(device_label) <= 80),
  created_at timestamptz not null default pg_catalog.now(),
  expires_at timestamptz not null,
  last_used_at timestamptz not null default pg_catalog.now(),
  revoked_at timestamptz,
  rotated_to uuid references private.nipto_sessions(id) on delete set null,
  check (expires_at > created_at)
);
create index nipto_sessions_user_active_idx
  on private.nipto_sessions(user_id, expires_at desc)
  where revoked_at is null;

create table private.nipto_recovery_challenges (
  id uuid primary key default gen_random_uuid(),
  owner_id uuid not null references private.nipto_accounts(user_id) on delete cascade,
  recovery_user_id uuid not null references public.profiles(id) on delete cascade,
  challenge_hash bytea not null check (octet_length(challenge_hash) = 32),
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
  on private.nipto_recovery_challenges(owner_id)
  where status = 'pending';
create index nipto_recovery_inbox_idx
  on private.nipto_recovery_challenges(recovery_user_id, created_at desc)
  where status = 'pending';

create table private.nipto_password_reset_grants (
  id uuid primary key default gen_random_uuid(),
  challenge_id uuid not null unique
    references private.nipto_recovery_challenges(id) on delete cascade,
  owner_id uuid not null references private.nipto_accounts(user_id) on delete cascade,
  grant_hash bytea not null unique check (octet_length(grant_hash) = 32),
  created_at timestamptz not null default pg_catalog.now(),
  expires_at timestamptz not null,
  delivered_at timestamptz,
  consumed_at timestamptz,
  check (expires_at > created_at)
);

create table private.nipto_security_events (
  id bigint generated always as identity primary key,
  user_id uuid references private.nipto_accounts(user_id) on delete set null,
  event_type text not null check (event_type in (
    'account_created','password_changed','password_reset',
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

-- Registration is service-only. Edge Functions hash the password with Argon2id
-- before calling this RPC; this function never receives a plaintext password.
create or replace function public.nipto_native_register(
  p_nipto_id text,
  p_display_name text,
  p_password_hash text
)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_user_id uuid := gen_random_uuid();
  v_nipto_id text := lower(trim(coalesce(p_nipto_id, '')));
  v_display_name text := trim(coalesce(p_display_name, ''));
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

  return v_user_id;
end;
$$;
revoke all on function public.nipto_native_register(text,text,text) from public, anon, authenticated;
grant execute on function public.nipto_native_register(text,text,text) to service_role;

-- Only the trusted login Edge Function may retrieve a password hash.
create or replace function public.nipto_native_login_record(p_nipto_id text)
returns table(user_id uuid, password_hash text, account_state text)
language sql
stable
security definer
set search_path = ''
as $$
  select a.user_id, a.password_hash, p.account_state
  from private.nipto_accounts a
  join public.profiles p on p.id = a.user_id
  where p.nipto_id = lower(trim(coalesce(p_nipto_id, '')))
  limit 1;
$$;
revoke all on function public.nipto_native_login_record(text) from public, anon, authenticated;
grant execute on function public.nipto_native_login_record(text) to service_role;

create or replace function public.nipto_native_create_session(
  p_user_id uuid,
  p_refresh_token_hash bytea,
  p_expires_at timestamptz,
  p_device_label text default null
)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_session_id uuid;
begin
  if octet_length(p_refresh_token_hash) <> 32
     or p_expires_at <= pg_catalog.now()
     or p_expires_at > pg_catalog.now() + interval '90 days' then
    raise exception 'Invalid session parameters';
  end if;
  if not exists (
    select 1 from private.nipto_accounts a
    join public.profiles p on p.id = a.user_id
    where a.user_id = p_user_id and p.account_state = 'active'
  ) then
    raise exception 'Account unavailable';
  end if;

  insert into private.nipto_sessions(user_id, refresh_token_hash, expires_at, device_label)
  values (p_user_id, p_refresh_token_hash, p_expires_at, left(p_device_label, 80))
  returning id into v_session_id;

  insert into private.nipto_security_events(user_id, event_type)
  values (p_user_id, 'session_created');

  return v_session_id;
end;
$$;
revoke all on function public.nipto_native_create_session(uuid,bytea,timestamptz,text) from public, anon, authenticated;
grant execute on function public.nipto_native_create_session(uuid,bytea,timestamptz,text) to service_role;

-- Atomic refresh-token rotation. Reuse of a previously rotated token revokes
-- every session for that account and returns no session.
create or replace function public.nipto_native_rotate_session(
  p_old_refresh_token_hash bytea,
  p_new_refresh_token_hash bytea,
  p_new_expires_at timestamptz
)
returns table(user_id uuid, session_id uuid)
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_old private.nipto_sessions%rowtype;
  v_new_id uuid;
begin
  if octet_length(p_old_refresh_token_hash) <> 32
     or octet_length(p_new_refresh_token_hash) <> 32
     or p_new_expires_at <= pg_catalog.now()
     or p_new_expires_at > pg_catalog.now() + interval '90 days' then
    return;
  end if;

  select * into v_old
  from private.nipto_sessions s
  where s.refresh_token_hash = p_old_refresh_token_hash
  for update;

  if not found then return; end if;

  if v_old.revoked_at is not null then
    -- A rotated-token replay is treated as refresh-token theft.
    update private.nipto_sessions
      set revoked_at = coalesce(revoked_at, pg_catalog.now())
      where private.nipto_sessions.user_id = v_old.user_id;
    insert into private.nipto_security_events(user_id, event_type)
      values (v_old.user_id, 'session_revoked');
    return;
  end if;

  if v_old.expires_at <= pg_catalog.now() then
    update private.nipto_sessions set revoked_at = pg_catalog.now()
      where id = v_old.id;
    return;
  end if;

  if not exists (
    select 1 from public.profiles p
    where p.id = v_old.user_id and p.account_state = 'active'
  ) then
    update private.nipto_sessions set revoked_at = pg_catalog.now()
      where private.nipto_sessions.user_id = v_old.user_id;
    return;
  end if;

  update private.nipto_sessions
    set revoked_at = pg_catalog.now(), last_used_at = pg_catalog.now()
    where id = v_old.id;

  insert into private.nipto_sessions(user_id, refresh_token_hash, expires_at, device_label)
  values (v_old.user_id, p_new_refresh_token_hash, p_new_expires_at, v_old.device_label)
  returning id into v_new_id;

  update private.nipto_sessions set rotated_to = v_new_id where id = v_old.id;
  insert into private.nipto_security_events(user_id, event_type)
    values (v_old.user_id, 'session_rotated');

  return query select v_old.user_id, v_new_id;
end;
$$;
revoke all on function public.nipto_native_rotate_session(bytea,bytea,timestamptz) from public, anon, authenticated;
grant execute on function public.nipto_native_rotate_session(bytea,bytea,timestamptz) to service_role;

create or replace function public.nipto_native_revoke_sessions(
  p_user_id uuid,
  p_except_session_id uuid default null
)
returns integer
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_count integer;
begin
  update private.nipto_sessions
    set revoked_at = pg_catalog.now()
    where user_id = p_user_id
      and revoked_at is null
      and (p_except_session_id is null or id <> p_except_session_id);
  get diagnostics v_count = row_count;
  insert into private.nipto_security_events(user_id, event_type)
    values (p_user_id, 'session_revoked');
  return v_count;
end;
$$;
revoke all on function public.nipto_native_revoke_sessions(uuid,uuid) from public, anon, authenticated;
grant execute on function public.nipto_native_revoke_sessions(uuid,uuid) to service_role;

-- Start a recovery request only when an accepted recovery Nipto account exists.
-- The Edge Function supplies only a SHA-256 hash of a random 256-bit challenge.
create or replace function public.nipto_native_start_recovery(
  p_nipto_id text,
  p_challenge_hash bytea
)
returns table(challenge_id uuid, owner_id uuid, recovery_user_id uuid)
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_owner uuid;
  v_recovery uuid;
  v_challenge uuid;
begin
  if octet_length(p_challenge_hash) <> 32 then return; end if;

  select p.id into v_owner
  from public.profiles p
  join private.nipto_accounts a on a.user_id = p.id
  where p.nipto_id = lower(trim(coalesce(p_nipto_id, '')))
    and p.account_state = 'active';

  if v_owner is null then return; end if;

  select rc.recovery_user_id into v_recovery
  from public.account_recovery_contacts rc
  join public.profiles rp on rp.id = rc.recovery_user_id
  where rc.owner_id = v_owner
    and rc.status = 'accepted'
    and rp.account_state = 'active'
    and not private.is_blocked_between(v_owner, rc.recovery_user_id)
  limit 1;

  if v_recovery is null then return; end if;

  update private.nipto_recovery_challenges
    set status = 'expired'
    where owner_id = v_owner and status = 'pending' and expires_at <= pg_catalog.now();

  if exists (
    select 1 from private.nipto_recovery_challenges c
    where c.owner_id = v_owner and c.status = 'pending' and c.expires_at > pg_catalog.now()
  ) then
    return;
  end if;

  insert into private.nipto_recovery_challenges(
    owner_id, recovery_user_id, challenge_hash, expires_at
  )
  values (
    v_owner, v_recovery, p_challenge_hash, pg_catalog.now() + interval '15 minutes'
  )
  returning id into v_challenge;

  insert into public.notifications(recipient_id, actor_id, notification_type, payload)
  values (
    v_recovery, v_owner, 'system',
    jsonb_build_object('kind','password_recovery_request','challenge_id',v_challenge)
  );

  insert into private.nipto_security_events(user_id, event_type)
  values (v_owner, 'recovery_requested');

  return query select v_challenge, v_owner, v_recovery;
end;
$$;
revoke all on function public.nipto_native_start_recovery(text,bytea) from public, anon, authenticated;
grant execute on function public.nipto_native_start_recovery(text,bytea) to service_role;

create or replace function public.nipto_native_respond_recovery(
  p_challenge_id uuid,
  p_recovery_user_id uuid,
  p_approve boolean
)
returns boolean
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_owner uuid;
begin
  update private.nipto_recovery_challenges c
    set status = case when p_approve then 'approved' else 'rejected' end,
        approved_at = case when p_approve then pg_catalog.now() else null end,
        rejected_at = case when p_approve then null else pg_catalog.now() end
    where c.id = p_challenge_id
      and c.recovery_user_id = p_recovery_user_id
      and c.status = 'pending'
      and c.expires_at > pg_catalog.now()
      and exists (
        select 1
        from public.account_recovery_contacts rc
        join public.profiles owner_profile on owner_profile.id = rc.owner_id
        join public.profiles recovery_profile on recovery_profile.id = rc.recovery_user_id
        where rc.owner_id = c.owner_id
          and rc.recovery_user_id = c.recovery_user_id
          and rc.status = 'accepted'
          and owner_profile.account_state = 'active'
          and recovery_profile.account_state = 'active'
          and not private.is_blocked_between(rc.owner_id, rc.recovery_user_id)
      )
    returning c.owner_id into v_owner;

  if v_owner is null then return false; end if;

  insert into private.nipto_security_events(user_id, event_type)
    values (v_owner, case when p_approve then 'recovery_approved' else 'recovery_rejected' end);

  insert into public.notifications(recipient_id, actor_id, notification_type, payload)
  values (
    v_owner, p_recovery_user_id, 'system',
    jsonb_build_object('kind', case when p_approve then 'password_recovery_approved' else 'password_recovery_rejected' end)
  );

  return true;
end;
$$;
revoke all on function public.nipto_native_respond_recovery(uuid,uuid,boolean) from public, anon, authenticated;
grant execute on function public.nipto_native_respond_recovery(uuid,uuid,boolean) to service_role;

-- The owner proves possession of the original challenge secret to claim a grant.
-- The Edge Function generates the raw grant; only its hash is stored here.
create or replace function public.nipto_native_claim_reset_grant(
  p_challenge_id uuid,
  p_challenge_hash bytea,
  p_grant_hash bytea
)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_owner uuid;
begin
  if octet_length(p_challenge_hash) <> 32 or octet_length(p_grant_hash) <> 32 then
    return null;
  end if;

  select c.owner_id into v_owner
  from private.nipto_recovery_challenges c
  where c.id = p_challenge_id
    and c.challenge_hash = p_challenge_hash
    and c.status = 'approved'
    and c.expires_at > pg_catalog.now()
  for update;

  if v_owner is null then return null; end if;

  insert into private.nipto_password_reset_grants(
    challenge_id, owner_id, grant_hash, expires_at, delivered_at
  )
  values (
    p_challenge_id, v_owner, p_grant_hash,
    pg_catalog.now() + interval '10 minutes', pg_catalog.now()
  )
  on conflict (challenge_id) do nothing;

  if not found then return null; end if;

  update private.nipto_recovery_challenges
    set status = 'consumed', consumed_at = pg_catalog.now()
    where id = p_challenge_id;

  return v_owner;
end;
$$;
revoke all on function public.nipto_native_claim_reset_grant(uuid,bytea,bytea) from public, anon, authenticated;
grant execute on function public.nipto_native_claim_reset_grant(uuid,bytea,bytea) to service_role;

-- A reset grant can be consumed once. Password update and session revocation are
-- performed in the same database transaction.
create or replace function public.nipto_native_consume_reset_grant(
  p_grant_hash bytea,
  p_new_password_hash text
)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_grant private.nipto_password_reset_grants%rowtype;
begin
  if octet_length(p_grant_hash) <> 32
     or p_new_password_hash is null
     or p_new_password_hash not like '$argon2id$%'
     or char_length(p_new_password_hash) not between 32 and 512 then
    return null;
  end if;

  select * into v_grant
  from private.nipto_password_reset_grants g
  where g.grant_hash = p_grant_hash
  for update;

  if not found or v_grant.consumed_at is not null
     or v_grant.expires_at <= pg_catalog.now()
     or v_grant.delivered_at is null then
    return null;
  end if;

  update private.nipto_password_reset_grants
    set consumed_at = pg_catalog.now()
    where id = v_grant.id;

  update private.nipto_accounts
    set password_hash = p_new_password_hash,
        credential_version = credential_version + 1,
        password_changed_at = pg_catalog.now(),
        updated_at = pg_catalog.now()
    where user_id = v_grant.owner_id;

  update private.nipto_sessions
    set revoked_at = pg_catalog.now()
    where user_id = v_grant.owner_id and revoked_at is null;

  insert into private.nipto_security_events(user_id, event_type)
    values (v_grant.owner_id, 'password_reset');

  return v_grant.owner_id;
end;
$$;
revoke all on function public.nipto_native_consume_reset_grant(bytea,text) from public, anon, authenticated;
grant execute on function public.nipto_native_consume_reset_grant(bytea,text) to service_role;
