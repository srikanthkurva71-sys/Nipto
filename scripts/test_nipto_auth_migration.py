from pathlib import Path
import unittest


ROOT = Path(__file__).resolve().parents[1]
AUTH_MIGRATION = ROOT / "supabase/migrations/20261116170000_nipto_native_auth.sql"
CORE_MIGRATION = ROOT / "supabase/migrations/20261116000100_nipto_social_core.sql"
REGISTRATION_MIGRATION = ROOT / "supabase/migrations/20261117100000_nipto_registration_assistance.sql"


class NiptoAuthMigrationTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.auth_sql = AUTH_MIGRATION.read_text(encoding="utf-8")
        cls.core_sql = CORE_MIGRATION.read_text(encoding="utf-8")
        cls.registration_sql = REGISTRATION_MIGRATION.read_text(encoding="utf-8")

    def test_existing_auth_trigger_calls_replaced_public_handler(self):
        self.assertIn("create trigger on_auth_user_created_nipto", self.core_sql)
        self.assertIn("execute function public.handle_new_nipto_user()", self.core_sql)
        self.assertIn("create or replace function private.handle_new_nipto_user()", self.auth_sql)
        self.assertIn("drop trigger if exists on_auth_user_created_nipto on auth.users;", self.auth_sql)
        self.assertIn("execute function private.handle_new_nipto_user();", self.auth_sql)
        self.assertIn("new.raw_app_meta_data->>'provider' is distinct from 'custom:nipto'", self.auth_sql)
        self.assertIn("set supabase_user_id=new.id", self.auth_sql)

    def test_recovery_starts_are_serialized_per_identity(self):
        start = self.auth_sql.split(
            "create or replace function public.nipto_native_start_recovery", 1
        )[1].split("create or replace function public.nipto_native_recovery_status", 1)[0]
        self.assertIn("pg_advisory_xact_lock", start)
        self.assertIn("hashtextextended(v_identity::text, 0)", start)
        self.assertIn("where owner_identity_id=v_identity and status='pending'", start)

    def test_reset_grants_are_short_lived_and_single_use(self):
        claim = self.auth_sql.split(
            "create or replace function public.nipto_native_claim_reset_grant", 1
        )[1].split("create or replace function public.nipto_native_consume_reset_grant", 1)[0]
        consume = self.auth_sql.split(
            "create or replace function public.nipto_native_consume_reset_grant", 1
        )[1].split("create or replace function public.nipto_native_account_for_user", 1)[0]
        self.assertIn("interval '10 minutes'", claim)
        self.assertIn("on conflict(challenge_id) do nothing", claim)
        self.assertIn("for update", consume)
        self.assertIn("consumed_at is not null", consume)
        self.assertIn("expires_at<=pg_catalog.now()", consume)
        self.assertIn("join public.account_recovery_contacts rc", claim)
        self.assertIn("for update of c, owner_account, rc", claim)
        self.assertIn("join public.account_recovery_contacts rc", consume)
        self.assertIn("for update of a, owner_profile, c, rc", consume)

    def test_recovery_approval_rechecks_active_accounts_and_block_state(self):
        listing = self.auth_sql.split(
            "create or replace function public.nipto_native_list_recovery_requests", 1
        )[1].split("create or replace function public.nipto_native_respond_password_recovery", 1)[0]
        approval = self.auth_sql.split(
            "create or replace function public.nipto_native_respond_password_recovery", 1
        )[1].split("create or replace function public.nipto_native_claim_reset_grant", 1)[0]
        contact = self.auth_sql.split(
            "create or replace function public.nipto_native_respond_recovery_contact", 1
        )[1].split("create or replace function public.nipto_native_remove_recovery_contact", 1)[0]
        self.assertIn("op.account_state='active'", listing)
        self.assertIn("owner_profile.account_state='active'", approval)
        self.assertIn("recovery_profile.account_state='active'", approval)
        self.assertIn("not private.is_blocked_between(owner_account.supabase_user_id,rc.recovery_user_id)", approval)
        self.assertIn("not private.is_blocked_between(rc.owner_id,rc.recovery_user_id)", contact)

    def test_migration_tickets_are_serialized_and_single_active(self):
        ticket = self.auth_sql.split(
            "create or replace function public.nipto_oidc_create_migration_ticket", 1
        )[1].split("create or replace function public.nipto_oidc_consume_migration_ticket", 1)[0]
        self.assertIn("pg_advisory_xact_lock", ticket)
        self.assertIn("hashtextextended(p_user_id::text, 1)", ticket)
        self.assertIn("delete from private.nipto_migration_tickets where user_id=p_user_id", ticket)

    def test_password_reset_revokes_sessions_atomically(self):
        consume = self.auth_sql.split(
            "create or replace function public.nipto_native_consume_reset_grant", 1
        )[1].split("create or replace function public.nipto_native_account_for_user", 1)[0]
        self.assertIn("update private.nipto_password_reset_grants set consumed_at", consume)
        self.assertIn("update private.nipto_accounts set password_hash", consume)
        self.assertIn("delete from auth.sessions where user_id=v_owner_user", consume)

    def test_sensitive_identity_rpcs_are_service_role_only(self):
        for signature in (
            "nipto_oidc_register(text,text,text,text)",
            "nipto_oidc_login_record(text)",
            "nipto_native_start_recovery(text,text)",
            "nipto_native_claim_reset_grant(uuid,text,text)",
            "nipto_native_consume_reset_grant(text,text)",
        ):
            self.assertIn(f"revoke all on function public.{signature} from public,anon,authenticated;", self.auth_sql)
            self.assertIn(f"grant execute on function public.{signature} to service_role;", self.auth_sql)

    def test_legacy_auth_contact_data_is_scrubbed_after_link(self):
        cleanup = self.auth_sql.split(
            "create or replace function public.nipto_native_clear_legacy_email", 1
        )[1].split("create or replace function public.nipto_native_start_recovery", 1)[0]
        for field in (
            "email=null",
            "phone=null",
            "encrypted_password=''",
            "confirmation_token=''",
            "recovery_token=''",
            "email_change_token_new=''",
            "email_change_token_current=''",
            "phone_change_token=''",
            "reauthentication_token=''",
            "- 'email' - 'phone' - 'email_verified' - 'phone_verified'",
        ):
            self.assertIn(field, cleanup)
        self.assertIn("delete from auth.identities", cleanup)

    def test_nipto_id_constraints_use_canonical_handle_format(self):
        self.assertIn("nipto_id ~ '^[a-z0-9]+(_[a-z0-9]+)*$'", self.registration_sql)
        self.assertIn("grant execute on function public.nipto_oidc_check_id(text) to service_role;", self.registration_sql)


if __name__ == "__main__":
    unittest.main()
