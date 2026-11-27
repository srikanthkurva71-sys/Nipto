alter table private.nipto_oidc_transactions alter column nonce drop not null;
alter table private.nipto_oidc_codes alter column nonce drop not null;

create or replace function public.nipto_oidc_create_transaction(
  p_client_id text,
  p_redirect_uri text,
  p_scope text,
  p_state text,
  p_nonce text,
  p_code_challenge text,
  p_csrf_hash text,
  p_migration_ticket_hash text default null
) returns uuid
language plpgsql
security definer
set search_path to ''
as $function$
declare v_id uuid;
begin
  if p_client_id is null or p_redirect_uri is null or p_state is null
    or (p_nonce is not null and pg_catalog.length(p_nonce) > 512)
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
$function$;

create or replace function public.nipto_oidc_create_code(
  p_code_hash text,
  p_identity_id uuid,
  p_client_id text,
  p_redirect_uri text,
  p_nonce text,
  p_code_challenge text
) returns void
language plpgsql
security definer
set search_path to ''
as $function$
begin
  if p_code_hash !~ '^[a-f0-9]{64}$'
    or p_code_challenge !~ '^[A-Za-z0-9_-]{43,128}$'
    or (p_nonce is not null and pg_catalog.length(p_nonce) > 512) then
    raise exception 'Invalid authorization code';
  end if;
  insert into private.nipto_oidc_codes(code_hash,identity_id,client_id,redirect_uri,nonce,code_challenge,expires_at)
  select p_code_hash,a.identity_id,p_client_id,p_redirect_uri,p_nonce,p_code_challenge,
    pg_catalog.now()+interval '2 minutes'
  from private.nipto_accounts a where a.identity_id=p_identity_id and a.status='active';
  if not found then raise exception 'Nipto account unavailable'; end if;
end;
$function$;
