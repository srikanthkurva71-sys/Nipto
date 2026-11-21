-- Recovery-account linking is a post-registration, authenticated settings action.
-- Remove the registration-time recovery parameters so account creation cannot
-- create or stage a recovery relationship before the owner has signed in.

drop function if exists public.nipto_oidc_register(text,text,text,text);
drop function if exists public.nipto_oidc_register_legacy(uuid,text,text,text,text);

create function public.nipto_oidc_register(
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
  v_id uuid;
  v_nipto_id text := lower(trim(coalesce(p_nipto_id,'')));
  v_display_name text := trim(coalesce(p_display_name,''));
begin
  if v_nipto_id !~ '^[a-z0-9]+(_[a-z0-9]+)*$'
    or char_length(v_nipto_id) not between 3 and 24
    or v_nipto_id = any(array['admin','administrator','support','help','nipto','official','security','moderator']) then
    raise exception 'Invalid Nipto ID';
  end if;
  if char_length(v_display_name) not between 1 and 50 then
    raise exception 'Invalid display name';
  end if;
  if p_password_hash is null
    or p_password_hash not like '$argon2id$%'
    or char_length(p_password_hash) not between 32 and 512 then
    raise exception 'Invalid password hash';
  end if;
  if exists(select 1 from public.profiles p where p.nipto_id=v_nipto_id)
    or exists(select 1 from private.nipto_accounts a where a.nipto_id=v_nipto_id) then
    raise exception 'That Nipto ID is already in use';
  end if;

  insert into private.nipto_accounts(nipto_id,display_name,password_hash)
  values(v_nipto_id,v_display_name,p_password_hash)
  returning identity_id into v_id;

  insert into private.nipto_security_events(identity_id,event_type)
  values(v_id,'account_created');
  return v_id;
end;
$$;

revoke all on function public.nipto_oidc_register(text,text,text) from public,anon,authenticated;
grant execute on function public.nipto_oidc_register(text,text,text) to service_role;

create function public.nipto_oidc_register_legacy(
  p_user_id uuid,
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
  v_id uuid;
begin
  if not exists(
    select 1 from public.profiles p
    where p.id=p_user_id
      and p.nipto_id=lower(trim(p_nipto_id))
      and p.account_state='active'
  ) then
    raise exception 'Existing Nipto profile could not be verified';
  end if;
  if p_password_hash is null
    or p_password_hash not like '$argon2id$%'
    or char_length(p_password_hash) not between 32 and 512 then
    raise exception 'Invalid password hash';
  end if;

  select a.identity_id into v_id
  from private.nipto_accounts a
  where a.nipto_id=lower(trim(p_nipto_id))
    and (a.supabase_user_id is null or a.supabase_user_id=p_user_id)
  for update;

  if v_id is not null then
    update private.nipto_accounts
    set password_hash=p_password_hash,
        pending_recovery_nipto_id=null,
        updated_at=pg_catalog.now()
    where identity_id=v_id;
  else
    if exists(
      select 1 from private.nipto_accounts a
      where a.nipto_id=lower(trim(p_nipto_id))
    ) then
      raise exception 'This Nipto identity is linked to another account';
    end if;
    insert into private.nipto_accounts(
      nipto_id,display_name,password_hash
    )
    values(
      lower(trim(p_nipto_id)),trim(p_display_name),p_password_hash
    )
    returning identity_id into v_id;
  end if;

  insert into private.nipto_security_events(identity_id,event_type)
  values(v_id,'account_linked');
  return v_id;
end;
$$;

revoke all on function public.nipto_oidc_register_legacy(uuid,text,text,text) from public,anon,authenticated;
grant execute on function public.nipto_oidc_register_legacy(uuid,text,text,text) to service_role;
