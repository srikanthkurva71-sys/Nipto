
-- Reconcile legacy permissive policies from the first schema migration.
-- Column grants and RLS are both required: neither is a substitute for the other.

drop policy if exists follows_update_recipient on public.follows;
drop policy if exists follows_update_participants on public.follows;
create policy follows_update_recipient on public.follows
for update to authenticated
using (following_id = (select auth.uid()))
with check (following_id = (select auth.uid()));

drop policy if exists message_receipts_update_own on public.message_receipts;
create policy message_receipts_update_own on public.message_receipts
for update to authenticated
using (user_id = (select auth.uid()))
with check (user_id = (select auth.uid()));

drop policy if exists status_views_insert_self on public.status_views;
create policy status_views_insert_self on public.status_views
for insert to authenticated
with check (
  viewer_id = (select auth.uid())
  and exists (
    select 1 from public.statuses s
    where s.id = status_id
      and s.owner_id <> (select auth.uid())
      and s.expires_at > now()
  )
);

drop policy if exists message_receipts_insert_self on public.message_receipts;
create policy message_receipts_insert_self on public.message_receipts
for insert to authenticated
with check (
  user_id = (select auth.uid())
  and exists (
    select 1 from public.messages m
    where m.id = message_id
      and m.conversation_id = conversation_id
      and m.sender_id <> (select auth.uid())
      and private.is_conversation_member(conversation_id)
  )
);

drop policy if exists profiles_update_own on public.profiles;
create policy profiles_update_own on public.profiles
for update to authenticated
using (id = (select auth.uid()))
with check (id = (select auth.uid()));

drop policy if exists user_reports_read_own on public.user_reports;
create policy user_reports_read_own on public.user_reports
for select to authenticated
using (reporter_id = (select auth.uid()));

drop policy if exists user_reports_insert_self on public.user_reports;
create policy user_reports_insert_self on public.user_reports
for insert to authenticated
with check (
  reporter_id = (select auth.uid())
  and (reported_user_id is null or reported_user_id <> (select auth.uid()))
);

-- Authenticated definer RPCs intentionally expose narrowly-scoped application
-- operations. Pin their grants to authenticated only; anon and PUBLIC cannot call.
revoke all on function public.accept_group_invitation(uuid) from public, anon;
revoke all on function public.decline_group_invitation(uuid) from public, anon;
revoke all on function public.create_group_conversation(text, uuid[]) from public, anon;
revoke all on function public.create_or_get_direct_conversation(uuid) from public, anon;
revoke all on function public.list_blocked_profiles() from public, anon;
revoke all on function public.list_my_connections(text) from public, anon;
revoke all on function public.list_my_notifications() from public, anon;
revoke all on function public.search_profiles(text, integer) from public, anon;

grant execute on function public.accept_group_invitation(uuid) to authenticated;
grant execute on function public.decline_group_invitation(uuid) to authenticated;
grant execute on function public.create_group_conversation(text, uuid[]) to authenticated;
grant execute on function public.create_or_get_direct_conversation(uuid) to authenticated;
grant execute on function public.list_blocked_profiles() to authenticated;
grant execute on function public.list_my_connections(text) to authenticated;
grant execute on function public.list_my_notifications() to authenticated;
grant execute on function public.search_profiles(text, integer) to authenticated;
