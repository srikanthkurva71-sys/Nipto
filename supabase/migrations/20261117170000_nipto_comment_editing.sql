-- Allow authors to edit only their own comment body while retaining RLS visibility checks.
-- Identity columns and parent references remain immutable to clients.

alter table public.short_comments
  add column if not exists updated_at timestamptz not null default now();

drop trigger if exists short_comments_updated_at on public.short_comments;
create trigger short_comments_updated_at
before update on public.short_comments
for each row execute function private.set_updated_at();

drop policy if exists post_comments_update_own_body on public.post_comments;
create policy post_comments_update_own_body
on public.post_comments
for update to authenticated
using (author_id = (select auth.uid()) and private.can_view_post(post_id))
with check (author_id = (select auth.uid()) and private.can_view_post(post_id));

drop policy if exists short_comments_update_own_body on public.short_comments;
create policy short_comments_update_own_body
on public.short_comments
for update to authenticated
using (author_id = (select auth.uid()) and private.can_view_short(short_id))
with check (author_id = (select auth.uid()) and private.can_view_short(short_id));

revoke update on public.post_comments from authenticated;
revoke update on public.short_comments from authenticated;
grant update (body) on public.post_comments to authenticated;
grant update (body) on public.short_comments to authenticated;
