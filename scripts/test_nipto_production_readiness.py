from pathlib import Path
import re
import unittest


ROOT = Path(__file__).resolve().parents[1]
APP_ROOT = ROOT / "mobile/app"
HARDENING_MIGRATION = (
    ROOT / "supabase/migrations/20261126160836_nipto_least_privilege_hardening.sql"
)
NOTIFICATIONS_SCREEN = APP_ROOT / "lib/screens/notifications_screen.dart"
LAUNCHER_CONFIG = APP_ROOT / "flutter_launcher_icons.yaml"
SPLASH_CONFIG = APP_ROOT / "flutter_native_splash.yaml"


class NiptoProductionReadinessTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.hardening_sql = HARDENING_MIGRATION.read_text(encoding="utf-8")
        cls.notifications_source = NOTIFICATIONS_SCREEN.read_text(encoding="utf-8")
        cls.lib_sources = {
            path: path.read_text(encoding="utf-8")
            for path in (APP_ROOT / "lib").rglob("*.dart")
        }
        cls.config_toml = (ROOT / "supabase/config.toml").read_text(encoding="utf-8")

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

    def test_official_branding_generators_are_configured(self):
        launcher = LAUNCHER_CONFIG.read_text(encoding="utf-8")
        splash = SPLASH_CONFIG.read_text(encoding="utf-8")
        self.assertIn("assets/branding/nipto_logo.png", launcher)
        self.assertIn("android: true", launcher)
        self.assertIn("assets/branding/nipto_logo.png", splash)
        self.assertIn("android: true", splash)


if __name__ == "__main__":
    unittest.main()
