
-- Follows: only the receiving account may accept a pending request.
drop policy if exists follows_update_recipient on public.follows;

-- Message receipts are inserted by the trusted after-message trigger only.
-- Clients only update their own receipts after they actually open the conversation.
drop policy if exists message_receipts_insert_self on public.message_receipts;
drop policy if exists message_receipts_write_self on public.message_receipts;
drop policy if exists message_receipts_update_own on public.message_receipts;

-- Profiles: retain one owner-only policy, using a stable auth.uid() initplan.
drop policy if exists profiles_update_self on public.profiles;

-- Status-view creation must satisfy the full visibility rule, be unexpired,
-- and must not create a view record for the viewer's own status.
drop policy if exists status_views_insert_self on public.status_views;
drop policy if exists status_views_create_self on public.status_views;
create policy status_views_create_self on public.status_views
for insert to authenticated
with check (
  viewer_id = (select auth.uid())
  and exists (
    select 1 from public.statuses s
    where s.id = status_id
      and s.owner_id <> (select auth.uid())
      and s.expires_at > now()
  )
  and private.can_view_status(status_id)
);

-- Reports remain insertable/readable only by their author; moderation state is
-- managed exclusively by staff SECURITY DEFINER RPCs.
drop policy if exists reports_create_self on public.user_reports;
drop policy if exists reports_read_reporter on public.user_reports;
