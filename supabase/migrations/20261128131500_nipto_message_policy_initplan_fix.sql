-- Keep auth.uid() as a stable InitPlan expression in the message update policy
-- so PostgreSQL evaluates it once per statement rather than once per row.
drop policy if exists "messages_edit_own_recent" on public.messages;
create policy "messages_edit_own_recent" on public.messages for update to authenticated
using (
  sender_id = (select auth.uid())
  and created_at > now() - interval '15 minutes'
  and public.can_access_conversation_messages(conversation_id)
)
with check (
  sender_id = (select auth.uid())
  and public.can_access_conversation_messages(conversation_id)
);
