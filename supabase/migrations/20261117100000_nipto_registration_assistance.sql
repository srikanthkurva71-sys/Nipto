-- Safe public-facing username availability check.
-- Only returns a boolean and a small list of alternatives; never returns account data.

alter table public.profiles drop constraint if exists profiles_nipto_id_format;
alter table public.profiles add constraint profiles_nipto_id_format check (
  nipto_id = lower(nipto_id)
  and char_length(nipto_id) between 3 and 24
  and nipto_id ~ '^[a-z0-9]+(_[a-z0-9]+)*$'
  and nipto_id not in ('admin','administrator','support','help','nipto','official','security','moderator')
);

alter table private.nipto_accounts drop constraint if exists nipto_accounts_nipto_id_check;
alter table private.nipto_accounts add constraint nipto_accounts_nipto_id_check check (
  nipto_id = lower(nipto_id)
  and char_length(nipto_id) between 3 and 24
  and nipto_id ~ '^[a-z0-9]+(_[a-z0-9]+)*$'
  and nipto_id not in ('admin','administrator','support','help','nipto','official','security','moderator')
);

create or replace function public.nipto_oidc_check_id(p_nipto_id text)
returns table(available boolean,suggestions text[])
language plpgsql stable security definer set search_path=''
as $$
declare
  v_id text := lower(trim(regexp_replace(coalesce(p_nipto_id,''),'^@','')));
  v_base text;
  v_suggestions text[];
  v_reserved boolean;
begin
  if char_length(v_id) not between 3 and 24
    or v_id !~ '^[a-z0-9]+(_[a-z0-9]+)*$' then
    return query select false,array[]::text[];
    return;
  end if;

  v_reserved := v_id = any(array[
    'admin','administrator','support','help','nipto','official','security','moderator'
  ]);

  select not exists(select 1 from public.profiles p where p.nipto_id=v_id)
    and not exists(select 1 from private.nipto_accounts a where a.nipto_id=v_id)
  into available;

  if available and not v_reserved then
    return query select true,array[]::text[];
    return;
  end if;

  v_base := left(trim(both '_' from v_id),19);
  select coalesce(array_agg(options.candidate order by options.candidate),array[]::text[])
  into v_suggestions
  from (
    select candidate
    from (
      select (v_base || '_' || n::text) as candidate
      from generate_series(1,40) n
      where char_length(v_base || '_' || n::text) between 3 and 24
        and not exists(select 1 from public.profiles p where p.nipto_id=(v_base || '_' || n::text))
        and not exists(select 1 from private.nipto_accounts a where a.nipto_id=(v_base || '_' || n::text))
      union all
      select (left(v_base,21) || n::text) as candidate
      from generate_series(1,40) n
      where char_length(left(v_base,21) || n::text) between 3 and 24
        and not exists(select 1 from public.profiles p where p.nipto_id=(left(v_base,21) || n::text))
        and not exists(select 1 from private.nipto_accounts a where a.nipto_id=(left(v_base,21) || n::text))
    ) all_options
    group by candidate
    order by candidate
    limit 5
  ) options;

  return query select false,v_suggestions;
end;
$$;

revoke all on function public.nipto_oidc_check_id(text) from public,anon,authenticated;
grant execute on function public.nipto_oidc_check_id(text) to service_role;
