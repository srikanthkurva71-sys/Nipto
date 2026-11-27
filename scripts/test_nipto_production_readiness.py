from pathlib import Path
import re
import unittest


ROOT = Path(__file__).resolve().parents[1]
APP_ROOT = ROOT / "mobile/app"
HARDENING_MIGRATION = (
    ROOT / "supabase/migrations/20261126115641_nipto_least_privilege_hardening.sql"
)
OIDC_CLAIMS_MIGRATION = (
    ROOT / "supabase/migrations/20261126122909_nipto_oidc_custom_claims_provisioning.sql"
)
PUSH_MIGRATION = ROOT / "supabase/migrations/20261126132328_nipto_push_delivery.sql"
MESSAGE_RPC_HARDENING = (
    ROOT / "supabase/migrations/20261126132330_nipto_message_rpc_search_path.sql"
)
OIDC_DEPLOYMENT_DOC = ROOT / "docs/NIPTO_OIDC_DEPLOYMENT.md"
NOTIFICATIONS_SCREEN = APP_ROOT / "lib/screens/notifications_screen.dart"
LAUNCHER_CONFIG = APP_ROOT / "flutter_launcher_icons.yaml"
SPLASH_CONFIG = APP_ROOT / "flutter_native_splash.yaml"
AUTH_SCREEN = APP_ROOT / "lib/screens/auth_screen.dart"
SESSION_MANAGER = APP_ROOT / "lib/services/nipto_session_manager.dart"
IDENTITY_FUNCTION = ROOT / "supabase/functions/nipto-identity/index.ts"
PUSH_FUNCTION = ROOT / "supabase/functions/nipto-push-dispatch/index.ts"
PUSH_HELPERS = ROOT / "supabase/functions/nipto-push-dispatch/push_helpers.ts"
CLOUD_INTEGRATION_WORKFLOW = (
    ROOT / ".github/workflows/cloud-integration-test.yml"
)


class NiptoProductionReadinessTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.hardening_sql = HARDENING_MIGRATION.read_text(encoding="utf-8")
        cls.oidc_claims_sql = OIDC_CLAIMS_MIGRATION.read_text(encoding="utf-8")
        cls.push_sql = PUSH_MIGRATION.read_text(encoding="utf-8")
        cls.message_rpc_hardening_sql = MESSAGE_RPC_HARDENING.read_text(encoding="utf-8")
        cls.oidc_deployment_doc = OIDC_DEPLOYMENT_DOC.read_text(encoding="utf-8")
        cls.notifications_source = NOTIFICATIONS_SCREEN.read_text(encoding="utf-8")
        cls.lib_sources = {
            path: path.read_text(encoding="utf-8")
            for path in (APP_ROOT / "lib").rglob("*.dart")
        }
        cls.config_toml = (ROOT / "supabase/config.toml").read_text(encoding="utf-8")
        cls.auth_screen = AUTH_SCREEN.read_text(encoding="utf-8")
        cls.session_manager = SESSION_MANAGER.read_text(encoding="utf-8")
        cls.identity_function = IDENTITY_FUNCTION.read_text(encoding="utf-8")
        cls.push_function = PUSH_FUNCTION.read_text(encoding="utf-8")
        cls.push_helpers = PUSH_HELPERS.read_text(encoding="utf-8")
        cls.cloud_integration_workflow = CLOUD_INTEGRATION_WORKFLOW.read_text(
            encoding="utf-8"
        )

    def test_cloud_probe_installs_emulator_runtime_libraries(self):
        self.assertIn("CREATE-PROBE", self.cloud_integration_workflow)
        self.assertIn("android-emulator-runner@v2", self.cloud_integration_workflow)
        self.assertIn("libpulse0", self.cloud_integration_workflow)
        self.assertIn("libgl1", self.cloud_integration_workflow)
        self.assertIn('ANDROID_I_WANT_MY_TCG: "yes"', self.cloud_integration_workflow)
        self.assertIn("emulator-boot-timeout: 1200", self.cloud_integration_workflow)
        self.assertIn(
            "flutter test integration_test/nipto_live_auth_and_data_test.dart -d emulator-5554",
            self.cloud_integration_workflow,
        )
        self.assertNotIn("-d chrome", self.cloud_integration_workflow)

    def test_least_privilege_migration_restores_column_scoped_inserts(self):
        protected_columns = {
            "follows": "(follower_id, following_id)",
            "blocked_users": "(blocker_id, blocked_id)",
            "close_friends": "(owner_id, friend_id)",
            "messages": "(conversation_id, sender_id, message_type, body, media_path, reply_to_id)",
            "statuses": "(owner_id, status_type, text_content, media_path, background_color, visibility)",
            "posts": "(author_id, caption, media_path, media_type, visibility)",
            "shorts": "(creator_id, video_path, thumbnail_path, caption, duration_seconds, visibility)",
            "user_feedback": "(user_id, category, rating, subject, message, platform)",
            "user_reports": "(reporter_id, reported_user_id, content_type, content_id, reason, details)",
        }
        self.assertIn("revoke insert on public.follows", self.hardening_sql)
        for table, columns in protected_columns.items():
            with self.subTest(table=table):
                pattern = rf"grant insert {re.escape(columns)}\s+on public\.{table} to authenticated;"
                self.assertRegex(self.hardening_sql, pattern)
        self.assertIn(
            "create index if not exists notifications_inbox_all_idx",
            self.hardening_sql,
        )

    def test_profile_search_escapes_like_wildcards(self):
        self.assertIn(
            "create or replace function public.search_profiles(p_query text, p_limit integer default 20)",
            self.hardening_sql,
        )
        self.assertIn("replace(lower(trim(p_query)), '!', '!!')", self.hardening_sql)
        self.assertIn("like (i.prefix || '%') escape '!'", self.hardening_sql)
        self.assertNotIn("lower(trim(p_query)) || '%'", self.hardening_sql)

    def test_notification_read_uses_recipient_id(self):
        self.assertIn(".eq('recipient_id', userId)", self.notifications_source)
        self.assertNotIn(".eq('user_id', userId)", self.notifications_source)

    def test_no_empty_callbacks_remain_in_production_code(self):
        offenders = [
            str(path.relative_to(ROOT))
            for path, source in self.lib_sources.items()
            if re.search(r"on(?:Pressed|Tap|Changed):\s*\(\)\s*\{\s*\}", source)
        ]
        self.assertEqual(offenders, [], "Empty callbacks are not production behaviour")

    def test_retired_unauthenticated_function_is_not_configured_or_deployed(self):
        self.assertNotIn("[functions.nipto-login]", self.config_toml)
        self.assertFalse((ROOT / "supabase/functions/nipto-login").exists())

    def test_auth_screen_opens_native_credential_forms(self):
        self.assertIn("NativeNiptoLoginScreen", self.auth_screen)
        self.assertIn("NativeNiptoRegistrationScreen", self.auth_screen)
        self.assertIn("_openSignIn", self.auth_screen)
        self.assertIn("_openRegistration", self.auth_screen)
        self.assertIn("Sign in with Nipto ID", self.auth_screen)
        self.assertIn("onPressed: _busy ? null : _openSignIn", self.auth_screen)
        self.assertIn("onPressed: _busy ? null : _openRegistration", self.auth_screen)
        self.assertIn("signInWithNiptoId", self.auth_screen)
        self.assertIn("registerNiptoAccount", self.auth_screen)
        self.assertIn("Use browser sign-in instead", self.auth_screen)

    def test_native_credentials_finish_real_supabase_pkce_session(self):
        self.assertIn("getOAuthSignInUrl", self.session_manager)
        self.assertIn("authorize/prepare", self.session_manager)
        self.assertIn("authorize/native", self.session_manager)
        self.assertIn("getSessionFromUrl(callback)", self.session_manager)
        self.assertNotIn("..followRedirects = false", self.session_manager)
        self.assertNotIn("signInWithPassword", self.session_manager)
        self.assertNotIn("signUp(email", self.session_manager)

    def test_identity_function_supports_native_oidc_bridge(self):
        self.assertIn('path.endsWith("/authorize/prepare")', self.identity_function)
        self.assertIn('path.endsWith("/authorize/native")', self.identity_function)
        self.assertIn("async function authorizePrepare", self.identity_function)
        self.assertIn("exchangeSupabaseAuthorizationCode", self.identity_function)
        self.assertIn('redirect: "manual"', self.identity_function)
        self.assertIn("nipto_oidc_create_transaction", self.identity_function)
        self.assertIn("nipto_oidc_consume_transaction", self.identity_function)
        self.assertIn("resolveOidcIdentity", self.identity_function)

    def test_custom_oidc_claims_are_provisioned_into_profiles(self):
        self.assertIn(
            "new.raw_user_meta_data->'custom_claims'", self.oidc_claims_sql
        )
        self.assertIn("v_claims->>'nipto_id'", self.oidc_claims_sql)
        self.assertIn("v_claims->>'display_name'", self.oidc_claims_sql)
        self.assertIn("array['nipto_id','display_name']", self.oidc_claims_sql)
        self.assertIn(
            "where identifier = 'custom:nipto'", self.oidc_claims_sql
        )

    def test_deployment_runbook_records_required_claim_allowlist(self):
        self.assertIn('`custom_claims_allowlist`: `["nipto_id", "display_name"]`', self.oidc_deployment_doc)
        self.assertIn("email_optional=true", self.oidc_deployment_doc)
        self.assertIn("Verified deployment snapshot — 2026-11-26", self.oidc_deployment_doc)

    def test_client_reads_supabase_custom_claims(self):
        session_source = SESSION_MANAGER.read_text(encoding="utf-8")
        self.assertIn("metadata['custom_claims']", session_source)
        self.assertIn("custom[customKey]", session_source)
        self.assertIn("custom[standardKey]", session_source)

    def test_message_rpcs_use_empty_search_path(self):
        self.assertIn("public.edit_own_message(", self.message_rpc_hardening_sql)
        self.assertIn("public.delete_own_message(", self.message_rpc_hardening_sql)
        self.assertEqual(self.message_rpc_hardening_sql.count("set search_path = ''"), 2)
        self.assertNotIn("set search_path = public, pg_temp", self.message_rpc_hardening_sql)

    def test_push_delivery_uses_durable_outbox_and_narrow_rpcs(self):
        for fragment in (
            "create table if not exists private.push_delivery_outbox",
            "notifications_after_insert_push",
            "call_sessions_after_insert_push",
            "public.register_device_push_token(",
            "public.unregister_device_push_token(",
            "public.nipto_push_claim(",
            "grant execute on function public.register_device_push_token(text, text) to authenticated",
            "grant execute on function public.nipto_push_claim(integer) to service_role",
        ):
            with self.subTest(fragment=fragment):
                self.assertIn(fragment, self.push_sql)

    def test_push_worker_never_trusts_client_for_dispatch(self):
        self.assertIn('path.endsWith("/worker/run")', self.push_function)
        self.assertIn("x-nipto-worker-secret", self.push_function)
        self.assertIn("FCM_SERVICE_ACCOUNT_JSON", self.push_function)
        self.assertIn("nipto_push_claim", self.push_function)
        self.assertNotIn("service_role", "\n".join(self.lib_sources.values()))
        self.assertNotIn("FCM_SERVICE_ACCOUNT_JSON", "\n".join(self.lib_sources.values()))

    def test_push_payload_contains_only_opaque_identifiers(self):
        self.assertIn('click_action: "FLUTTER_NOTIFICATION_CLICK"', self.push_helpers)
        self.assertIn("pushDataForJob", self.push_helpers)
        self.assertNotIn("sdp", self.push_helpers)
        self.assertNotIn("candidate", self.push_helpers)

    def test_new_edge_functions_are_configured(self):
        for function in ("nipto-push-dispatch", "nipto-media", "nipto-privacy"):
            with self.subTest(function=function):
                self.assertIn(f"[functions.{function}]", self.config_toml)

    def test_official_branding_generators_are_configured(self):
        launcher = LAUNCHER_CONFIG.read_text(encoding="utf-8")
        splash = SPLASH_CONFIG.read_text(encoding="utf-8")
        self.assertIn("assets/branding/nipto_logo.png", launcher)
        self.assertIn("android: true", launcher)
        self.assertIn("assets/branding/nipto_logo.png", splash)
        self.assertIn("android: true", splash)


if __name__ == "__main__":
    unittest.main()
