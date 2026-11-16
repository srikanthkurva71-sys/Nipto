
-- Private-schema helper functions are referenced by RLS and other definer functions.
-- They remain non-public APIs; do not grant direct execution to authenticated users.
revoke all on function private.can_view_post(uuid) from public, anon, authenticated;
revoke all on function private.can_view_profile(uuid) from public, anon, authenticated;
revoke all on function private.can_view_short(uuid) from public, anon, authenticated;
revoke all on function private.can_view_status(uuid) from public, anon, authenticated;
revoke all on function private.has_accepted_follow(uuid, uuid) from public, anon, authenticated;
revoke all on function private.is_blocked_between(uuid, uuid) from public, anon, authenticated;
revoke all on function private.is_conversation_member(uuid) from public, anon, authenticated;
revoke all on function private.can_start_direct_chat(uuid, uuid) from public, anon, authenticated;

-- PostgreSQL evaluates referenced functions in policies as the policy owner,
-- and application SECURITY DEFINER RPCs execute under their owner.
-- Exposed API functions stay authenticated-only with fixed search_path.
revoke all on function public.accept_group_invitation(uuid) from public, anon;
revoke all on function public.decline_group_invitation(uuid) from public, anon;
revoke all on function public.create_group_conversation(text, uuid[]) from public, anon;
revoke all on function public.create_or_get_direct_conversation(uuid) from public, anon;
revoke all on function public.get_home_feed(integer, timestamptz) from public, anon;
revoke all on function public.list_blocked_profiles() from public, anon;
revoke all on function public.list_my_connections(text) from public, anon;
revoke all on function public.list_my_notifications() from public, anon;
revoke all on function public.search_profiles(text, integer) from public, anon;

grant execute on function public.accept_group_invitation(uuid) to authenticated;
grant execute on function public.decline_group_invitation(uuid) to authenticated;
grant execute on function public.create_group_conversation(text, uuid[]) to authenticated;
grant execute on function public.create_or_get_direct_conversation(uuid) to authenticated;
grant execute on function public.get_home_feed(integer, timestamptz) to authenticated;
grant execute on function public.list_blocked_profiles() to authenticated;
grant execute on function public.list_my_connections(text) to authenticated;
grant execute on function public.list_my_notifications() to authenticated;
grant execute on function public.search_profiles(text, integer) to authenticated;
