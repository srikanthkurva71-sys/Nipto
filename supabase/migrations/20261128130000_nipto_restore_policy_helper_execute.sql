-- Migration 20261116002400 removed EXECUTE from the private visibility helpers.
-- Those functions are referenced by RLS policies on public tables, so an
-- authenticated query must be able to evaluate them. Keep them out of the
-- PostgREST-exposed surface by granting only to the authenticated role.
revoke all on function private.is_blocked_between(uuid, uuid) from public, anon, authenticated;
revoke all on function private.has_accepted_follow(uuid, uuid) from public, anon, authenticated;
revoke all on function private.can_view_profile(uuid) from public, anon, authenticated;
revoke all on function private.is_conversation_member(uuid) from public, anon, authenticated;
revoke all on function private.can_view_status(uuid) from public, anon, authenticated;
revoke all on function private.can_view_short(uuid) from public, anon, authenticated;
revoke all on function private.can_view_post(uuid) from public, anon, authenticated;

grant execute on function private.is_blocked_between(uuid, uuid) to authenticated;
grant execute on function private.has_accepted_follow(uuid, uuid) to authenticated;
grant execute on function private.can_view_profile(uuid) to authenticated;
grant execute on function private.is_conversation_member(uuid) to authenticated;
grant execute on function private.can_view_status(uuid) to authenticated;
grant execute on function private.can_view_short(uuid) to authenticated;
grant execute on function private.can_view_post(uuid) to authenticated;
