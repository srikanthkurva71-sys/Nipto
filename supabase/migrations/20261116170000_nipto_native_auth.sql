-- Nipto-owned credentials with Supabase Auth as an email-optional OIDC session broker.
-- Nipto remains the identity provider; Supabase Auth brokers app sessions and
-- preserves auth.uid(), existing RLS, Storage, Realtime and profile UUIDs.

alter table public.profiles alter column is_private set default true;
alter table public.posts alter column visibility set default 'followers';
alter table public.shorts alter column visibility set default 'followers';

create table private.nipto_accounts (
  identity_id uuid primary key default gen_random_uuid(),
  nipto_id text not null unique
    check (nipto_id = lower(nipto_id)
      and nipto_id ~ '^[a-z0-9_]{3,24}$'
      and nipto_id not in ('admin','administrator','support','help','nipto','official','security','moderator')),
  display_name text not null check (char_length(display_name) between 1 and 50),
  password_hash text not null
    check (password_hash like '$argon2id$%' and char_length(password_hash) between 32 and 512),
  status text not null default 'active' check (status in ('active','locked','disabled')),
  supabase_user_id uuid unique references auth.users(id) on delete cascade,
  pending_recovery_nipto_id text
    check (pending_recovery_nipto_id is null or pending_recovery_nipto_id ~ '^[a-z0-9_]{3,24}$'),
  password_changed_at timestamptz not null default pg_catalog.now(),
  created_at timestamptz not null default pg_catalog.now(),
  updated_at timestamptz not null default pg_catalog.now()
);
create index nipto_accounts_supabase_user_idx
  on private.nipto_accounts(supabase_user_id) where supabase_user_id is not null;

create table private.nipto_oidc_transactions (
  id uuid primary key default gen_random_uuid(),
  client_id text not null,
  redirect_uri text not null,
  response_type text not null check (response_type='code'),
  scope text not null,
  state text not null,
  nonce text not null,
  code_challenge text not null,
  code_challenge_method text not null check (code_challenge_method='S256'),
  csrf_hash text not null check (csrf_hash ~ '^[a-f0-9]{64}$'),
  migration_ticket_hash text
    check (migration_ticket_hash is null or migration_ticket_hash ~ '^[a-f0-9]{64}$'),
  created_at timestamptz not null default pg_catalog.now(),
  expires_at timestamptz not null,
  consumed_at timestamptz,
  check (expires_at > created_at)
);
create index nipto_oidc_transactions_expiry_idx
  on private.nipto_oidc_transactions(expires_at);

create table private.nipto_migration_tickets (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references auth.users(id) on delete cascade,
  ticket_hash text not null unique check (ticket_hash ~ '^[a-f0-9]{64}$'),
  created_at timestamptz not null default pg_catalog.now(),
  expires_at timestamptz not null,
  consumed_at timestamptz,
  check (expires_at > created_at)
);
create index nipto_migration_tickets_expiry_idx
  on private.nipto_migration_tickets(expires_at);

create table private.nipto_oidc_codes (
  code_hash text primary key check (code_hash ~ '^[a-f0-9]{64}$'),
  identity_id uuid not null references private.nipto_accounts(identity_id) on delete cascade,
  client_id text not null,
  redirect_uri text not null,
  nonce text not null,
  code_challenge text not null,
  created_at timestamptz not null default pg_catalog.now(),
  expires_at timestamptz not null,
  consumed_at timestamptz,
  check (expires_at > created_at)
);
create index nipto_oidc_codes_expiry_idx on private.nipto_oidc_codes(expires_at);

create table private.nipto_recovery_challenges (
  id uuid primary key default gen_random_uuid(),
  owner_identity_id uuid not null references private.nipto_accounts(identity_id) on delete cascade,
  recovery_user_id uuid not null references public.profiles(id) on delete cascade,
  challenge_hash text not null check (challenge_hash ~ '^[a-f0-9]{64}$'),
  status text not null default 'pending'
    check (status in ('pending','approved','rejected','expired','consumed')),
  created_at timestamptz not null default pg_catalog.now(),
  expires_at timestamptz not null,
  approved_at timestamptz,
  rejected_at timestamptz,
  consumed_at timestamptz,
  check (expires_at > created_at)
);
create unique index nipto_recovery_one_pending_owner_idx
  on private.nipto_recovery_challenges(owner_identity_id) where status='pending';
create index nipto_recovery_inbox_idx
  on private.nipto_recovery_challenges(recovery_user_id,created_at desc) where status='pending';

create table private.nipto_password_reset_grants (
  id uuid primary key default gen_random_uuid(),
  challenge_id uuid not null unique
    references private.nipto_recovery_challenges(id) on delete cascade,
  owner_identity_id uuid not null references private.nipto_accounts(identity_id) on delete cascade,
  grant_hash text not null unique check (grant_hash ~ '^[a-f0-9]{64}$'),
  created_at timestamptz not null default pg_catalog.now(),
  expires_at timestamptz not null,
  consumed_at timestamptz,
  check (expires_at > created_at)
);

create table private.nipto_security_events (
  id bigint generated always as identity primary key,
  identity_id uuid references private.nipto_accounts(identity_id) on delete set null,
  event_type text not null check (event_type in (
    'account_created','account_linked','password_changed','password_reset',
    'recovery_requested','recovery_approved','recovery_rejected',
    'email_identity_removed','session_revoked'
  )),
  created_at timestamptz not null default pg_catalog.now(),
  metadata jsonb not null default '{}'::jsonb
);
create index nipto_security_events_identity_created_idx
  on private.nipto_security_events(identity_id,created_at desc);

alter table private.nipto_accounts enable row level security;
alter table private.nipto_oidc_transactions enable row level security;
alter table private.nipto_migration_tickets enable row level security;
alter table private.nipto_oidc_codes enable row level security;
alter table private.nipto_recovery_challenges enable row level security;
alter table private.nipto_password_reset_grants enable row level security;
alter table private.nipto_security_events enable row level security;
revoke all on private.nipto_accounts,private.nipto_oidc_transactions,
  private.nipto_migration_tickets,private.nipto_oidc_codes,
  private.nipto_recovery_challenges,private.nipto_password_reset_grants,
  private.nipto_security_events from public,anon,authenticated;

create or replace function public.nipto_oidc_register(
  p_nipto_id text,p_display_name text,p_password_hash text,p_recovery_nipto_id text default null
)
returns uuid language plpgsql security definer set search_path=''
as $$
declare
  v_id uuid;
  v_nipto_id text := lower(trim(coalesce(p_nipto_id,'')));
  v_display_name text := trim(coalesce(p_display_name,''));
  v_recovery text := nullif(lower(trim(coalesce(p_recovery_nipto_id,''))),'');
begin
  if v_nipto_id !~ '^[a-z0-9_]{3,24}$'
    or v_nipto_id=any(array['admin','administrator','support','help','nipto','official','security','moderator']) then
    raise exception 'Invalid Nipto ID';
  end if;
  if char_length(v_display_name) not between 1 and 50 then raise exception 'Invalid display name'; end if;
  if p_password_hash is null or p_password_hash not like '$argon2id$%'
    or char_length(p_password_hash) not between 32 and 512 then raise exception 'Invalid password hash'; end if;
  if exists(select 1 from public.profiles p where p.nipto_id=v_nipto_id) then
    raise exception 'That Nipto ID is already in use';
  end if;
  if v_recovery is not null then
    if v_recovery !~ '^[a-z0-9_]{3,24}$' or v_recovery=v_nipto_id then
      raise exception 'Invalid recovery Nipto ID';
    end if;
    if not exists(
      select 1 from public.profiles p
      join private.nipto_accounts a on a.supabase_user_id=p.id and a.status='active'
      where p.nipto_id=v_recovery and p.account_state='active'
    ) then raise exception 'Recovery Nipto account is unavailable'; end if;
  end if;
  insert into private.nipto_accounts(nipto_id,display_name,password_hash,pending_recovery_nipto_id)
  values(v_nipto_id,v_display_name,p_password_hash,v_recovery)
  returning identity_id into v_id;
  insert into private.nipto_security_events(identity_id,event_type) values(v_id,'account_created');
  return v_id;
end;
$$;
revoke all on function public.nipto_oidc_register(text,text,text,text) from public,anon,authenticated;
grant execute on function public.nipto_oidc_register(text,text,text,text) to service_role;

create or replace function public.nipto_oidc_register_legacy(
  p_user_id uuid,p_nipto_id text,p_display_name text,p_password_hash text,
  p_recovery_nipto_id text default null
)
returns uuid language plpgsql security definer set search_path=''
as $$
declare
  v_id uuid;
  v_target uuid;
  v_recovery text := nullif(lower(trim(coalesce(p_recovery_nipto_id,''))),'');
begin
  if not exists(
    select 1 from public.profiles p
    where p.id=p_user_id and p.nipto_id=lower(trim(p_nipto_id)) and p.account_state='active'
  ) then raise exception 'Existing Nipto profile could not be verified'; end if;
  if p_password_hash is null or p_password_hash not like '$argon2id$%'
    or char_length(p_password_hash) not between 32 and 512 then raise exception 'Invalid password hash'; end if;
  if v_recovery is not null then
    select p.id into v_target
    from public.profiles p
    join private.nipto_accounts a on a.supabase_user_id=p.id and a.status='active'
    where p.nipto_id=v_recovery and p.account_state='active';
    if v_target is null or v_target=p_user_id then raise exception 'Recovery Nipto account is unavailable'; end if;
  end if;

  select a.identity_id into v_id
  from private.nipto_accounts a
  where a.nipto_id=lower(trim(p_nipto_id))
    and (a.supabase_user_id is null or a.supabase_user_id=p_user_id)
  for update;
  if v_id is not null then
    update private.nipto_accounts
    set password_hash=p_password_hash,
        pending_recovery_nipto_id=v_recovery,
        updated_at=pg_catalog.now()
    where identity_id=v_id;
  else
    if exists(select 1 from private.nipto_accounts a where a.nipto_id=lower(trim(p_nipto_id))) then
      raise exception 'This Nipto identity is linked to another account';
    end if;
    insert into private.nipto_accounts(nipto_id,display_name,password_hash,pending_recovery_nipto_id)
    values(lower(trim(p_nipto_id)),trim(p_display_name),p_password_hash,v_recovery)
    returning identity_id into v_id;
  end if;

  insert into private.nipto_security_events(identity_id,event_type) values(v_id,'account_linked');
  return v_id;
end;
$$;
revoke all on function public.nipto_oidc_register_legacy(uuid,text,text,text,text) from public,anon,authenticated;
grant execute on function public.nipto_oidc_register_legacy(uuid,text,text,text,text) to service_role;

create or replace function public.nipto_oidc_login_record(p_nipto_id text)
returns table(identity_id uuid,password_hash text,status text,nipto_id text,display_name text)
language sql stable security definer set search_path=''
as $$
  select a.identity_id,a.password_hash,a.status,a.nipto_id,a.display_name
  from private.nipto_accounts a where a.nipto_id=lower(trim(coalesce(p_nipto_id,''))) limit 1;
$$;
revoke all on function public.nipto_oidc_login_record(text) from public,anon,authenticated;
grant execute on function public.nipto_oidc_login_record(text) to service_role;

create or replace function public.nipto_oidc_create_transaction(
  p_client_id text,p_redirect_uri text,p_scope text,p_state text,p_nonce text,
  p_code_challenge text,p_csrf_hash text,p_migration_ticket_hash text default null
)
returns uuid language plpgsql security definer set search_path=''
as $$
declare v_id uuid;
begin
  if p_client_id is null or p_redirect_uri is null or p_state is null or p_nonce is null
    or p_code_challenge is null or p_code_challenge !~ '^[A-Za-z0-9_-]{43,128}$'
    or p_csrf_hash !~ '^[a-f0-9]{64}$'
    or (p_migration_ticket_hash is not null and p_migration_ticket_hash !~ '^[a-f0-9]{64}$') then
    raise exception 'Invalid OIDC authorization request';
  end if;
  insert into private.nipto_oidc_transactions(
    client_id,redirect_uri,response_type,scope,state,nonce,code_challenge,
    code_challenge_method,csrf_hash,migration_ticket_hash,expires_at
  )
  values(p_client_id,p_redirect_uri,'code',coalesce(p_scope,'openid profile'),p_state,p_nonce,
    p_code_challenge,'S256',p_csrf_hash,p_migration_ticket_hash,pg_catalog.now()+interval '10 minutes')
  returning id into v_id;
  return v_id;
end;
$$;
revoke all on function public.nipto_oidc_create_transaction(text,text,text,text,text,text,text,text) from public,anon,authenticated;
grant execute on function public.nipto_oidc_create_transaction(text,text,text,text,text,text,text,text) to service_role;

create or replace function public.nipto_oidc_get_transaction(p_id uuid,p_csrf_hash text)
returns table(client_id text,redirect_uri text,scope text,state text,nonce text,code_challenge text,migration_ticket_hash text)
language sql stable security definer set search_path=''
as $$
  select t.client_id,t.redirect_uri,t.scope,t.state,t.nonce,t.code_challenge,t.migration_ticket_hash
  from private.nipto_oidc_transactions t
  where t.id=p_id and t.csrf_hash=p_csrf_hash and t.consumed_at is null
    and t.expires_at>pg_catalog.now() limit 1;
$$;
revoke all on function public.nipto_oidc_get_transaction(uuid,text) from public,anon,authenticated;
grant execute on function public.nipto_oidc_get_transaction(uuid,text) to service_role;

create or replace function public.nipto_oidc_consume_transaction(p_id uuid,p_csrf_hash text)
returns boolean language plpgsql security definer set search_path=''
as $$
declare v_count integer;
begin
  update private.nipto_oidc_transactions set consumed_at=pg_catalog.now()
  where id=p_id and csrf_hash=p_csrf_hash and consumed_at is null and expires_at>pg_catalog.now();
  get diagnostics v_count=row_count;
  return v_count=1;
end;
$$;
revoke all on function public.nipto_oidc_consume_transaction(uuid,text) from public,anon,authenticated;
grant execute on function public.nipto_oidc_consume_transaction(uuid,text) to service_role;

create or replace function public.nipto_oidc_create_code(
  p_code_hash text,p_identity_id uuid,p_client_id text,p_redirect_uri text,p_nonce text,p_code_challenge text
)
returns void language plpgsql security definer set search_path=''
as $$
begin
  if p_code_hash !~ '^[a-f0-9]{64}$' or p_code_challenge !~ '^[A-Za-z0-9_-]{43,128}$' then
    raise exception 'Invalid authorization code';
  end if;
  insert into private.nipto_oidc_codes(code_hash,identity_id,client_id,redirect_uri,nonce,code_challenge,expires_at)
  select p_code_hash,a.identity_id,p_client_id,p_redirect_uri,p_nonce,p_code_challenge,
    pg_catalog.now()+interval '2 minutes'
  from private.nipto_accounts a where a.identity_id=p_identity_id and a.status='active';
  if not found then raise exception 'Nipto account unavailable'; end if;
end;
$$;
revoke all on function public.nipto_oidc_create_code(text,uuid,text,text,text,text) from public,anon,authenticated;
grant execute on function public.nipto_oidc_create_code(text,uuid,text,text,text,text) to service_role;

create or replace function public.nipto_oidc_consume_code(
  p_code_hash text,p_client_id text,p_redirect_uri text,p_code_challenge text
)
returns table(identity_id uuid,nonce text,nipto_id text,display_name text)
language plpgsql security definer set search_path=''
as $$
begin
  return query
  update private.nipto_oidc_codes c set consumed_at=pg_catalog.now()
  from private.nipto_accounts a
  where c.code_hash=p_code_hash and c.client_id=p_client_id and c.redirect_uri=p_redirect_uri
    and c.code_challenge=p_code_challenge and c.identity_id=a.identity_id and a.status='active'
    and c.consumed_at is null and c.expires_at>pg_catalog.now()
  returning c.identity_id,c.nonce,a.nipto_id,a.display_name;
end;
$$;
revoke all on function public.nipto_oidc_consume_code(text,text,text,text) from public,anon,authenticated;
grant execute on function public.nipto_oidc_consume_code(text,text,text,text) to service_role;

create or replace function public.nipto_native_profile_for_user(p_user_id uuid)
returns table(nipto_id text,display_name text)
language sql stable security definer set search_path=''
as $$
  select p.nipto_id,p.display_name from public.profiles p
  where p.id=p_user_id and p.account_state='active' limit 1;
$$;
revoke all on function public.nipto_native_profile_for_user(uuid) from public,anon,authenticated;
grant execute on function public.nipto_native_profile_for_user(uuid) to service_role;

create or replace function public.nipto_oidc_create_migration_ticket(p_user_id uuid,p_ticket_hash text)
returns uuid language plpgsql security definer set search_path=''
as $$
declare v_id uuid;
begin
  if p_ticket_hash !~ '^[a-f0-9]{64}$'
    or not exists(select 1 from public.profiles p where p.id=p_user_id and p.account_state='active') then
    raise exception 'Account migration is unavailable';
  end if;
  if exists(select 1 from private.nipto_accounts a where a.supabase_user_id=p_user_id and a.status='active') then
    raise exception 'Nipto identity is already linked';
  end if;
  delete from private.nipto_migration_tickets
  where user_id=p_user_id and (consumed_at is not null or expires_at<=pg_catalog.now());
  insert into private.nipto_migration_tickets(user_id,ticket_hash,expires_at)
  values(p_user_id,p_ticket_hash,pg_catalog.now()+interval '5 minutes')
  returning id into v_id;
  return v_id;
end;
$$;
revoke all on function public.nipto_oidc_create_migration_ticket(uuid,text) from public,anon,authenticated;
grant execute on function public.nipto_oidc_create_migration_ticket(uuid,text) to service_role;

create or replace function public.nipto_oidc_consume_migration_ticket(p_ticket_hash text)
returns table(user_id uuid,nipto_id text,display_name text)
language plpgsql security definer set search_path=''
as $$
begin
  return query
  update private.nipto_migration_tickets t set consumed_at=pg_catalog.now()
  from public.profiles p
  where t.ticket_hash=p_ticket_hash and t.user_id=p.id and t.consumed_at is null
    and t.expires_at>pg_catalog.now() and p.account_state='active'
  returning t.user_id,p.nipto_id,p.display_name;
end;
$$;
revoke all on function public.nipto_oidc_consume_migration_ticket(text) from public,anon,authenticated;
grant execute on function public.nipto_oidc_consume_migration_ticket(text) to service_role;

create or replace function public.nipto_oidc_link_user(p_nipto_id text,p_user_id uuid)
returns boolean language plpgsql security definer set search_path=''
as $$
declare v_count integer;
begin
  if not exists(select 1 from public.profiles p where p.id=p_user_id and p.nipto_id=lower(trim(p_nipto_id))) then
    raise exception 'Nipto profile does not match';
  end if;
  update private.nipto_accounts set supabase_user_id=p_user_id,updated_at=pg_catalog.now()
  where nipto_id=lower(trim(p_nipto_id)) and (supabase_user_id is null or supabase_user_id=p_user_id)
    and status='active';
  get diagnostics v_count=row_count;
  if v_count<>1 then raise exception 'Nipto account could not be linked'; end if;
  insert into private.nipto_security_events(identity_id,event_type)
  select identity_id,'account_linked' from private.nipto_accounts where nipto_id=lower(trim(p_nipto_id));
  return true;
end;
$$;
revoke all on function public.nipto_oidc_link_user(text,uuid) from public,anon,authenticated;
grant execute on function public.nipto_oidc_link_user(text,uuid) to service_role;

-- Canonical private handler used by the deployed auth.users trigger.
create or replace function private.handle_new_nipto_user()
returns trigger language plpgsql security definer set search_path=''
as $$
declare
  v_nipto_id text := lower(coalesce(new.raw_user_meta_data->>'nipto_id',''));
  v_display_name text := nullif(trim(coalesce(new.raw_user_meta_data->>'display_name',new.raw_user_meta_data->>'name','')),'');
  v_recovery_nipto_id text;
  v_recovery_user_id uuid;
begin
  if new.raw_app_meta_data->>'provider' is distinct from 'custom:nipto' then
    raise exception 'Use your Nipto account to sign in';
  end if;
  if v_nipto_id !~ '^[a-z0-9]+(_[a-z0-9]+)*$'
    or char_length(v_nipto_id) not between 3 and 24
    or v_nipto_id in ('admin','administrator','support','help','nipto','official','security','moderator') then
    raise exception 'A valid Nipto ID is required';
  end if;
  if v_display_name is null or char_length(v_display_name) not between 1 and 50 then
    raise exception 'A valid display name is required';
  end if;
  select a.pending_recovery_nipto_id into v_recovery_nipto_id
  from private.nipto_accounts a
  where a.nipto_id=v_nipto_id and a.status='active' and a.supabase_user_id is null
  for update;
  if not found then raise exception 'Nipto account identity is unavailable'; end if;

  insert into public.profiles(id,nipto_id,display_name,is_private)
  values(new.id,v_nipto_id,v_display_name,true);
  update private.nipto_accounts set supabase_user_id=new.id,pending_recovery_nipto_id=null,
    updated_at=pg_catalog.now()
  where nipto_id=v_nipto_id and supabase_user_id is null;

  if v_recovery_nipto_id is not null then
    select p.id into v_recovery_user_id
    from public.profiles p
    join private.nipto_accounts ra on ra.supabase_user_id=p.id and ra.status='active'
    where p.nipto_id=v_recovery_nipto_id and p.account_state='active' limit 1;
    if v_recovery_user_id is not null and not private.is_blocked_between(new.id,v_recovery_user_id) then
      insert into public.account_recovery_contacts(owner_id,recovery_user_id)
      values(new.id,v_recovery_user_id)
      on conflict(owner_id,recovery_user_id) do update set status='pending',updated_at=pg_catalog.now();
    end if;
  end if;
  return new;
end;
$$;
revoke all on function private.handle_new_nipto_user() from public,anon,authenticated;

-- Normalize the trigger target across existing installations and clean installs.
drop trigger if exists on_auth_user_created_nipto on auth.users;
create trigger on_auth_user_created_nipto
after insert on auth.users
for each row execute function private.handle_new_nipto_user();

create or replace function public.nipto_native_current_user()
returns uuid language sql stable security invoker set search_path=''
as $$ select auth.uid(); $$;
revoke all on function public.nipto_native_current_user() from public,anon;
grant execute on function public.nipto_native_current_user() to authenticated;

create or replace function public.nipto_native_clear_legacy_email()
returns boolean language plpgsql security definer set search_path=''
as $$
declare v_user_id uuid := auth.uid();
begin
  if v_user_id is null or not exists(
    select 1 from auth.identities i where i.user_id=v_user_id and i.provider='custom:nipto'
  ) then raise exception 'Link your Nipto identity before removing legacy sign-in'; end if;
  update auth.users set email=null,email_confirmed_at=null,phone=null,phone_confirmed_at=null,
    encrypted_password=''
  where id=v_user_id;
  delete from auth.identities where user_id=v_user_id and provider in ('email','phone');
  insert into private.nipto_security_events(identity_id,event_type)
  select a.identity_id,'email_identity_removed' from private.nipto_accounts a where a.supabase_user_id=v_user_id;
  return true;
end;
$$;
revoke all on function public.nipto_native_clear_legacy_email() from public,anon;
grant execute on function public.nipto_native_clear_legacy_email() to authenticated;

create or replace function public.nipto_native_start_recovery(p_nipto_id text,p_challenge_hash text)
returns table(challenge_id uuid,owner_user_id uuid,recovery_user_id uuid)
language plpgsql security definer set search_path=''
as $$
declare v_identity uuid; v_owner uuid; v_recovery uuid; v_challenge uuid;
begin
  if p_challenge_hash !~ '^[a-f0-9]{64}$' then return; end if;
  select a.identity_id,a.supabase_user_id into v_identity,v_owner
  from private.nipto_accounts a join public.profiles p on p.id=a.supabase_user_id
  where a.nipto_id=lower(trim(coalesce(p_nipto_id,''))) and a.status='active' and p.account_state='active';
  if v_identity is null or v_owner is null then return; end if;

  -- Serialize recovery starts for one Nipto identity so parallel requests cannot
  -- race past the pending-challenge check and hit the partial unique index.
  perform pg_catalog.pg_advisory_xact_lock(
    pg_catalog.hashtextextended(v_identity::text, 0)
  );

  select rc.recovery_user_id into v_recovery
  from public.account_recovery_contacts rc
  join public.profiles rp on rp.id=rc.recovery_user_id
  join private.nipto_accounts ra on ra.supabase_user_id=rp.id and ra.status='active'
  where rc.owner_id=v_owner and rc.status='accepted' and rp.account_state='active'
    and not private.is_blocked_between(v_owner,rc.recovery_user_id) limit 1;
  if v_recovery is null then return; end if;
  update private.nipto_recovery_challenges set status='expired'
  where owner_identity_id=v_identity and status='pending' and expires_at<=pg_catalog.now();
  if exists(select 1 from private.nipto_recovery_challenges c
    where c.owner_identity_id=v_identity and c.status='pending' and c.expires_at>pg_catalog.now()) then return; end if;
  insert into private.nipto_recovery_challenges(owner_identity_id,recovery_user_id,challenge_hash,expires_at)
  values(v_identity,v_recovery,p_challenge_hash,pg_catalog.now()+interval '15 minutes')
  returning id into v_challenge;
  insert into public.notifications(recipient_id,actor_id,notification_type,payload)
  values(v_recovery,v_owner,'system',jsonb_build_object('kind','password_recovery_request','challenge_id',v_challenge));
  insert into private.nipto_security_events(identity_id,event_type) values(v_identity,'recovery_requested');
  return query select v_challenge,v_owner,v_recovery;
end;
$$;
revoke all on function public.nipto_native_start_recovery(text,text) from public,anon,authenticated;
grant execute on function public.nipto_native_start_recovery(text,text) to service_role;

create or replace function public.nipto_native_recovery_status(p_challenge_id uuid,p_challenge_hash text)
returns text language sql stable security definer set search_path=''
as $$
  select case when c.status in ('pending','approved') and c.expires_at<=pg_catalog.now()
    then 'expired' else c.status end
  from private.nipto_recovery_challenges c
  where c.id=p_challenge_id and c.challenge_hash=p_challenge_hash limit 1;
$$;
revoke all on function public.nipto_native_recovery_status(uuid,text) from public,anon,authenticated;
grant execute on function public.nipto_native_recovery_status(uuid,text) to service_role;

create or replace function public.nipto_native_list_recovery_requests(p_recovery_user_id uuid)
returns table(challenge_id uuid,owner_nipto_id text,owner_display_name text,created_at timestamptz,expires_at timestamptz)
language sql stable security definer set search_path=''
as $$
  select c.id,a.nipto_id,a.display_name,c.created_at,c.expires_at
  from private.nipto_recovery_challenges c
  join private.nipto_accounts a on a.identity_id=c.owner_identity_id and a.status='active'
  join public.account_recovery_contacts rc on rc.owner_id=a.supabase_user_id
    and rc.recovery_user_id=c.recovery_user_id and rc.status='accepted'
  join public.profiles rp on rp.id=c.recovery_user_id and rp.account_state='active'
  join public.profiles op on op.id=a.supabase_user_id and op.account_state='active'
  where c.recovery_user_id=p_recovery_user_id and c.status='pending'
    and c.expires_at>pg_catalog.now()
    and not private.is_blocked_between(a.supabase_user_id,c.recovery_user_id)
  order by c.created_at desc limit 10;
$$;
revoke all on function public.nipto_native_list_recovery_requests(uuid) from public,anon,authenticated;
grant execute on function public.nipto_native_list_recovery_requests(uuid) to service_role;

create or replace function public.nipto_native_respond_password_recovery(p_challenge_id uuid,p_recovery_user_id uuid,p_approve boolean)
returns boolean language plpgsql security definer set search_path=''
as $$
declare v_owner_identity uuid; v_owner_user uuid;
begin
  update private.nipto_recovery_challenges c
  set status=case when p_approve then 'approved' else 'rejected' end,
      approved_at=case when p_approve then pg_catalog.now() else null end,
      rejected_at=case when p_approve then null else pg_catalog.now() end
  where c.id=p_challenge_id and c.recovery_user_id=p_recovery_user_id
    and c.status='pending' and c.expires_at>pg_catalog.now()
    and exists(
      select 1
      from public.account_recovery_contacts rc
      join private.nipto_accounts owner_account on owner_account.identity_id=c.owner_identity_id
      join public.profiles owner_profile on owner_profile.id=owner_account.supabase_user_id
        and owner_profile.account_state='active'
      join public.profiles recovery_profile on recovery_profile.id=rc.recovery_user_id
        and recovery_profile.account_state='active'
      where rc.owner_id=owner_account.supabase_user_id
        and rc.recovery_user_id=c.recovery_user_id
        and rc.status='accepted'
        and owner_account.status='active'
        and not private.is_blocked_between(owner_account.supabase_user_id,rc.recovery_user_id)
    )
  returning c.owner_identity_id into v_owner_identity;
  if v_owner_identity is null then return false; end if;
  select supabase_user_id into v_owner_user from private.nipto_accounts where identity_id=v_owner_identity;
  insert into public.notifications(recipient_id,actor_id,notification_type,payload)
  values(v_owner_user,p_recovery_user_id,'system',
    jsonb_build_object('kind',case when p_approve then 'password_recovery_approved' else 'password_recovery_rejected' end));
  insert into private.nipto_security_events(identity_id,event_type)
  values(v_owner_identity,case when p_approve then 'recovery_approved' else 'recovery_rejected' end);
  return true;
end;
$$;
revoke all on function public.nipto_native_respond_password_recovery(uuid,uuid,boolean) from public,anon,authenticated;
grant execute on function public.nipto_native_respond_password_recovery(uuid,uuid,boolean) to service_role;

create or replace function public.nipto_native_claim_reset_grant(p_challenge_id uuid,p_challenge_hash text,p_grant_hash text)
returns uuid language plpgsql security definer set search_path=''
as $$
declare v_identity uuid;
begin
  if p_challenge_hash !~ '^[a-f0-9]{64}$' or p_grant_hash !~ '^[a-f0-9]{64}$' then return null; end if;
  select c.owner_identity_id into v_identity from private.nipto_recovery_challenges c
  where c.id=p_challenge_id and c.challenge_hash=p_challenge_hash
    and c.status='approved' and c.expires_at>pg_catalog.now() for update;
  if v_identity is null then return null; end if;
  insert into private.nipto_password_reset_grants(challenge_id,owner_identity_id,grant_hash,expires_at)
  values(p_challenge_id,v_identity,p_grant_hash,pg_catalog.now()+interval '10 minutes')
  on conflict(challenge_id) do nothing;
  if not found then return null; end if;
  update private.nipto_recovery_challenges set status='consumed',consumed_at=pg_catalog.now()
  where id=p_challenge_id;
  return v_identity;
end;
$$;
revoke all on function public.nipto_native_claim_reset_grant(uuid,text,text) from public,anon,authenticated;
grant execute on function public.nipto_native_claim_reset_grant(uuid,text,text) to service_role;

create or replace function public.nipto_native_consume_reset_grant(p_grant_hash text,p_new_password_hash text)
returns uuid language plpgsql security definer set search_path=''
as $$
declare v_grant private.nipto_password_reset_grants%rowtype;
begin
  if p_grant_hash !~ '^[a-f0-9]{64}$' or p_new_password_hash is null
    or p_new_password_hash not like '$argon2id$%' or char_length(p_new_password_hash) not between 32 and 512 then
    return null;
  end if;
  select * into v_grant from private.nipto_password_reset_grants g
  where g.grant_hash=p_grant_hash for update;
  if not found or v_grant.consumed_at is not null or v_grant.expires_at<=pg_catalog.now() then return null; end if;
  update private.nipto_password_reset_grants set consumed_at=pg_catalog.now() where id=v_grant.id;
  update private.nipto_accounts set password_hash=p_new_password_hash,
    password_changed_at=pg_catalog.now(),updated_at=pg_catalog.now()
  where identity_id=v_grant.owner_identity_id;
  insert into private.nipto_security_events(identity_id,event_type)
  values(v_grant.owner_identity_id,'password_reset');
  return (select supabase_user_id from private.nipto_accounts where identity_id=v_grant.owner_identity_id);
end;
$$;
revoke all on function public.nipto_native_consume_reset_grant(text,text) from public,anon,authenticated;
grant execute on function public.nipto_native_consume_reset_grant(text,text) to service_role;

create or replace function public.nipto_native_account_for_user(p_user_id uuid)
returns table(identity_id uuid,nipto_id text,display_name text,password_hash text,status text)
language sql stable security definer set search_path=''
as $$
  select a.identity_id,a.nipto_id,a.display_name,a.password_hash,a.status
  from private.nipto_accounts a where a.supabase_user_id=p_user_id and a.status='active' limit 1;
$$;
revoke all on function public.nipto_native_account_for_user(uuid) from public,anon,authenticated;
grant execute on function public.nipto_native_account_for_user(uuid) to service_role;

create or replace function public.nipto_native_change_password(p_identity_id uuid,p_password_hash text)
returns boolean language plpgsql security definer set search_path=''
as $$
declare v_user_id uuid; v_count integer;
begin
  if p_password_hash is null or p_password_hash not like '$argon2id$%'
    or char_length(p_password_hash) not between 32 and 512 then raise exception 'Invalid password hash'; end if;
  update private.nipto_accounts set password_hash=p_password_hash,password_changed_at=pg_catalog.now(),
    updated_at=pg_catalog.now()
  where identity_id=p_identity_id and status='active' returning supabase_user_id into v_user_id;
  get diagnostics v_count=row_count;
  if v_count<>1 then return false; end if;
  delete from auth.sessions where user_id=v_user_id;
  insert into private.nipto_security_events(identity_id,event_type) values(p_identity_id,'password_changed');
  return true;
end;
$$;
revoke all on function public.nipto_native_change_password(uuid,text) from public,anon,authenticated;
grant execute on function public.nipto_native_change_password(uuid,text) to service_role;

create or replace function public.nipto_native_list_recovery_contacts(p_user_id uuid)
returns table(request_id uuid,owner_id uuid,owner_nipto_id text,owner_display_name text,
  recovery_user_id uuid,recovery_nipto_id text,recovery_display_name text,status text,created_at timestamptz)
language sql stable security definer set search_path=''
as $$
  select rc.id,rc.owner_id,op.nipto_id,op.display_name,rc.recovery_user_id,rp.nipto_id,
    rp.display_name,rc.status,rc.created_at
  from public.account_recovery_contacts rc
  join public.profiles op on op.id=rc.owner_id
  join public.profiles rp on rp.id=rc.recovery_user_id
  where rc.owner_id=p_user_id or rc.recovery_user_id=p_user_id
  order by rc.created_at desc limit 20;
$$;
revoke all on function public.nipto_native_list_recovery_contacts(uuid) from public,anon,authenticated;
grant execute on function public.nipto_native_list_recovery_contacts(uuid) to service_role;

create or replace function public.nipto_native_request_recovery_contact(p_owner_user_id uuid,p_nipto_id text)
returns uuid language plpgsql security definer set search_path=''
as $$
declare v_target uuid; v_id uuid;
begin
  if not exists(select 1 from private.nipto_accounts a join public.profiles p on p.id=a.supabase_user_id
    where a.supabase_user_id=p_owner_user_id and a.status='active' and p.account_state='active') then
    raise exception 'Nipto account unavailable';
  end if;
  if p_nipto_id is null or p_nipto_id !~ '^[a-z0-9_]{3,24}$' then raise exception 'Enter a valid Nipto ID'; end if;
  select p.id into v_target from public.profiles p
  join private.nipto_accounts a on a.supabase_user_id=p.id and a.status='active'
  where p.nipto_id=p_nipto_id and p.account_state='active';
  if v_target is null or v_target=p_owner_user_id or private.is_blocked_between(p_owner_user_id,v_target) then
    raise exception 'That Nipto account cannot be selected';
  end if;
  if exists(select 1 from public.account_recovery_contacts rc
    where rc.owner_id=p_owner_user_id and rc.status in ('pending','accepted') and rc.recovery_user_id<>v_target) then
    raise exception 'Remove your current recovery account before choosing another';
  end if;
  if exists(select 1 from public.account_recovery_contacts rc
    where rc.owner_id=p_owner_user_id and rc.recovery_user_id=v_target and rc.status='accepted') then
    raise exception 'This is already your recovery account';
  end if;
  insert into public.account_recovery_contacts(owner_id,recovery_user_id)
  values(p_owner_user_id,v_target)
  on conflict(owner_id,recovery_user_id) do update set status='pending',updated_at=pg_catalog.now()
  returning id into v_id;
  return v_id;
end;
$$;
revoke all on function public.nipto_native_request_recovery_contact(uuid,text) from public,anon,authenticated;
grant execute on function public.nipto_native_request_recovery_contact(uuid,text) to service_role;

create or replace function public.nipto_native_respond_recovery_contact(p_request_id uuid,p_recovery_user_id uuid,p_accept boolean)
returns boolean language plpgsql security definer set search_path=''
as $$
declare v_count integer;
begin
  update public.account_recovery_contacts rc
  set status=case when p_accept then 'accepted' else 'rejected' end,updated_at=pg_catalog.now()
  where rc.id=p_request_id and rc.recovery_user_id=p_recovery_user_id and rc.status='pending'
    and exists(select 1 from private.nipto_accounts a where a.supabase_user_id=p_recovery_user_id and a.status='active')
    and not private.is_blocked_between(rc.owner_id,rc.recovery_user_id);
  get diagnostics v_count=row_count;
  return v_count=1;
end;
$$;
revoke all on function public.nipto_native_respond_recovery_contact(uuid,uuid,boolean) from public,anon,authenticated;
grant execute on function public.nipto_native_respond_recovery_contact(uuid,uuid,boolean) to service_role;

create or replace function public.nipto_native_remove_recovery_contact(p_user_id uuid,p_request_id uuid)
returns boolean language plpgsql security definer set search_path=''
as $$
declare v_count integer;
begin
  delete from public.account_recovery_contacts where id=p_request_id
    and (owner_id=p_user_id or recovery_user_id=p_user_id);
  get diagnostics v_count=row_count;
  return v_count=1;
end;
$$;
revoke all on function public.nipto_native_remove_recovery_contact(uuid,uuid) from public,anon,authenticated;
grant execute on function public.nipto_native_remove_recovery_contact(uuid,uuid) to service_role;

create or replace function public.nipto_native_list_sessions(p_user_id uuid)
returns table(session_id uuid,created_at timestamptz,last_used_at timestamptz,device_label text)
language sql stable security definer set search_path=''
as $$
  select s.id,s.created_at,coalesce(s.refreshed_at,s.created_at),left(coalesce(s.user_agent,''),180)
  from auth.sessions s where s.user_id=p_user_id
  order by coalesce(s.refreshed_at,s.created_at) desc limit 10;
$$;
revoke all on function public.nipto_native_list_sessions(uuid) from public,anon,authenticated;
grant execute on function public.nipto_native_list_sessions(uuid) to service_role;

create or replace function public.nipto_native_revoke_session(p_user_id uuid,p_session_id uuid)
returns boolean language plpgsql security definer set search_path=''
as $$
declare v_count integer;
begin
  delete from auth.sessions where id=p_session_id and user_id=p_user_id;
  get diagnostics v_count=row_count;
  return v_count=1;
end;
$$;
revoke all on function public.nipto_native_revoke_session(uuid,uuid) from public,anon,authenticated;
grant execute on function public.nipto_native_revoke_session(uuid,uuid) to service_role;

create or replace function public.nipto_native_revoke_all_sessions(p_user_id uuid)
returns integer language plpgsql security definer set search_path=''
as $$
declare v_count integer;
begin
  delete from auth.sessions where user_id=p_user_id;
  get diagnostics v_count=row_count;
  return v_count;
end;
$$;
revoke all on function public.nipto_native_revoke_all_sessions(uuid) from public,anon,authenticated;
grant execute on function public.nipto_native_revoke_all_sessions(uuid) to service_role;

create or replace function private.notify_recovery_contact_response()
returns trigger language plpgsql security definer set search_path=''
as $$
begin
  if old.status='pending' and new.status in ('accepted','rejected') then
    insert into public.notifications(recipient_id,actor_id,notification_type,payload)
    values(new.owner_id,new.recovery_user_id,'system',
      jsonb_build_object('kind',case when new.status='accepted' then 'recovery_accepted' else 'recovery_rejected' end,
        'request_id',new.id));
  end if;
  return new;
end;
$$;
revoke all on function private.notify_recovery_contact_response() from public,anon,authenticated;
