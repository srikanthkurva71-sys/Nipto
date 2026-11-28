-- Storage RLS policies evaluate these helpers as the authenticated role. The
-- least-privilege grant migration removed EXECUTE from them, so uploads and
-- private media reads failed with "permission denied for function ...".
-- Keep them out of the PostgREST surface by granting only to authenticated.
revoke all on function private.nipto_media_valid_owner_path(text, text, uuid) from public, anon, authenticated;
revoke all on function private.can_read_avatar(text) from public, anon, authenticated;
revoke all on function private.can_read_post_media(text) from public, anon, authenticated;
revoke all on function private.can_read_short_media(text) from public, anon, authenticated;
revoke all on function private.can_read_status_media(text) from public, anon, authenticated;

grant execute on function private.nipto_media_valid_owner_path(text, text, uuid) to authenticated;
grant execute on function private.can_read_avatar(text) to authenticated;
grant execute on function private.can_read_post_media(text) to authenticated;
grant execute on function private.can_read_short_media(text) to authenticated;
grant execute on function private.can_read_status_media(text) to authenticated;
