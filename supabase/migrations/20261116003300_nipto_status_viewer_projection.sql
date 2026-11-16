-- Return only the minimal viewer identity projection to the owner of a status.
create or replace function public.list_status_viewers(p_status_id uuid)
returns table (
  viewer_id uuid,
  nipto_id text,
  display_name text,
  viewed_at timestamptz
)
language plpgsql
stable
security definer
set search_path = ''
as $$
begin
  if auth.uid() is null then
    raise exception 'Authentication required';
  end if;

  if not exists (
    select 1 from public.statuses s
    where s.id = p_status_id and s.owner_id = auth.uid()
  ) then
    raise exception 'Status not found';
  end if;

  return query
    select v.viewer_id, p.nipto_id, p.display_name, v.viewed_at
    from public.status_views v
    join public.profiles p on p.id = v.viewer_id
    where v.status_id = p_status_id
    order by v.viewed_at desc
    limit 100;
end;
$$;

revoke all on function public.list_status_viewers(uuid) from public, anon;
grant execute on function public.list_status_viewers(uuid) to authenticated;

comment on function public.list_status_viewers(uuid) is
  'Returns a minimal viewer identity projection only to the owner of the requested status.';
