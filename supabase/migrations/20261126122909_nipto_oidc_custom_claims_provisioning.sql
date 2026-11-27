-- Supabase custom OIDC providers capture non-profile claims under
-- raw_user_meta_data->'custom_claims'. The auth.users trigger must read that
-- object so a no-email custom:nipto signup can provision a Nipto profile.

create or replace function private.handle_new_nipto_user()
returns trigger language plpgsql security definer set search_path=''
as $$
declare
  v_claims jsonb := coalesce(new.raw_user_meta_data->'custom_claims', '{}'::jsonb);
  v_nipto_id text := lower(coalesce(
    new.raw_user_meta_data->>'nipto_id',
    v_claims->>'nipto_id',
    v_claims->>'preferred_username',
    ''
  ));
  v_display_name text := nullif(trim(coalesce(
    new.raw_user_meta_data->>'display_name',
    v_claims->>'display_name',
    new.raw_user_meta_data->>'name',
    v_claims->>'name',
    ''
  )), '');
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

-- Keep the live provider's custom-claim capture configured when this migration
-- runs against an existing project. The provider itself is created out-of-band
-- because its client secret is entered through the Auth admin API/dashboard.
update auth.custom_oauth_providers
set custom_claims_allowlist = array['nipto_id','display_name'],
    attribute_mapping = '{}'::jsonb,
    updated_at = pg_catalog.now()
where identifier = 'custom:nipto';
