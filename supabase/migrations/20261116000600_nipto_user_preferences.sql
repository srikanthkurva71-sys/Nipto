
create table public.user_preferences (
  user_id uuid primary key references public.profiles(id) on delete cascade,
  message_notifications boolean not null default true,
  follow_notifications boolean not null default true,
  status_notifications boolean not null default true,
  short_notifications boolean not null default true,
  updated_at timestamptz not null default now()
);
alter table public.user_preferences enable row level security;
create policy "preferences_read_self" on public.user_preferences
for select to authenticated using (user_id = (select auth.uid()));
create policy "preferences_insert_self" on public.user_preferences
for insert to authenticated with check (user_id = (select auth.uid()));
create policy "preferences_update_self" on public.user_preferences
for update to authenticated using (user_id = (select auth.uid()))
with check (user_id = (select auth.uid()));
grant select, insert, update on public.user_preferences to authenticated;
create trigger preferences_updated_at before update on public.user_preferences
for each row execute function private.set_updated_at();

-- Publish status changes to authenticated clients. Realtime payloads do not bypass table RLS.
do $$
begin
  if exists (select 1 from pg_publication where pubname = 'supabase_realtime') then
    if not exists (
      select 1 from pg_publication_tables
      where pubname = 'supabase_realtime' and schemaname = 'public' and tablename = 'statuses'
    ) then
      alter publication supabase_realtime add table public.statuses;
    end if;
  end if;
end;
$$;
comment on table public.user_preferences is 'Per-user notification preferences. Device push delivery still requires a provider integration.';
