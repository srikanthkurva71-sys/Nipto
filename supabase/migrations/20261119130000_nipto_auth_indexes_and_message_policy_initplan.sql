-- Cover the remaining Nipto auth foreign keys and avoid per-row auth.uid()
-- evaluation in the connected-chat message INSERT policy.
create index if not exists nipto_migration_tickets_user_id_idx
  on private.nipto_migration_tickets(user_id);
create index if not exists nipto_oidc_codes_identity_id_idx
  on private.nipto_oidc_codes(identity_id);
create index if not exists nipto_password_reset_grants_owner_identity_id_idx
  on private.nipto_password_reset_grants(owner_identity_id);

drop policy if exists messages_send_connected_as_self on public.messages;
create policy messages_send_connected_as_self
on public.messages
for insert
to authenticated
with check (
  sender_id = (select auth.uid())
  and can_access_conversation_messages(conversation_id)
  and not exists (
    select 1
    from public.conversation_members cm
    where cm.conversation_id = messages.conversation_id
      and cm.user_id <> (select auth.uid())
      and private.is_blocked_between((select auth.uid()), cm.user_id)
  )
);
