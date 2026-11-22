-- Nipto ID availability RPC
-- Public availability is required by the registration UI; this function only exposes
-- whether a syntactically valid ID is already reserved and never returns account data.

create or replace function public.nipto_id_is_available(candidate_id text)
returns boolean
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  normalized text;
begin
  normalized := lower(trim(both from coalesce(candidate_id, '')));

  if normalized !~ '^[a-z0-9_]{3,24}$'
     or normalized in ('admin','administrator','support','help','nipto','official','security','moderator') then
    return false;
  end if;

  return not exists (
    select 1
    from public.profiles p
    where p.nipto_id = normalized
  );
end;
$$;

revoke all on function public.nipto_id_is_available(text) from public;
grant execute on function public.nipto_id_is_available(text) to anon, authenticated;

comment on function public.nipto_id_is_available(text) is
  'Returns availability for a valid Nipto ID only; exposes no profile or auth data.';
