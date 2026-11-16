-- The rate-limit table is only accessed by the service_role-only
-- SECURITY DEFINER consume_nipto_login_attempt RPC. No client policies
-- are intentionally created.
alter table private.nipto_auth_attempts enable row level security;
