from pathlib import Path
import json
import re
import unittest


ROOT = Path(__file__).resolve().parents[1]
APP = ROOT / "mobile" / "app"
PUBSPEC = APP / "pubspec.yaml"


def declared_packages():
    text = PUBSPEC.read_text(encoding="utf-8")
    active_section = None
    declared = set()
    for line in text.splitlines():
        if line and not line.startswith(" ") and line.endswith(":"):
            active_section = line[:-1]
            continue
        if active_section in {"dependencies", "dev_dependencies"}:
            match = re.match(r"^  ([A-Za-z0-9_]+):", line)
            if match:
                declared.add(match.group(1))
    return declared


class FlutterProjectContractTests(unittest.TestCase):
    def test_all_direct_dart_package_imports_are_declared(self):
        imported = set()
        for source in (APP / "lib").rglob("*.dart"):
            imported.update(
                re.findall(
                    r"import\s+['\"]package:([^/]+)/",
                    source.read_text(encoding="utf-8"),
                )
            )
        imported.discard("flutter")
        imported.discard("flutter_test")
        self.assertTrue(imported, "Expected application package imports")
        self.assertLessEqual(
            imported,
            declared_packages(),
            "Every direct package import must be declared in pubspec.yaml",
        )

    def test_required_platform_and_application_packages_are_declared(self):
        declared = declared_packages()
        expected = {
            "supabase_flutter",
            "image_picker",
            "video_player",
            "flutter_webrtc",
            "flutter_secure_storage",
            "shared_preferences",
        }
        self.assertLessEqual(expected, declared)

    def test_development_config_contains_only_client_safe_supabase_values(self):
        config = json.loads((APP / "config" / "dev.json").read_text(encoding="utf-8"))
        self.assertEqual(
            set(config),
            {"SUPABASE_URL", "SUPABASE_PUBLISHABLE_KEY"},
        )
        self.assertTrue(config["SUPABASE_URL"].startswith("https://"))
        self.assertTrue(config["SUPABASE_PUBLISHABLE_KEY"].startswith("sb_publishable_"))

    def test_vscode_android_launch_uses_flutter_package_root(self):
        launch = json.loads((ROOT / ".vscode" / "launch.json").read_text(encoding="utf-8"))
        configuration = next(
            item for item in launch["configurations"]
            if item["name"] == "Nipto (Android)"
        )
        self.assertEqual(configuration["cwd"], "${workspaceFolder}/mobile/app")
        self.assertIn("--dart-define-from-file=config/dev.json", configuration["args"])

    def test_android_project_is_generated_not_committed_as_machine_specific_state(self):
        ignore = (ROOT / ".gitignore").read_text(encoding="utf-8")
        self.assertIn("mobile/app/android/local.properties", ignore)
        self.assertIn(".dart_tool/", ignore)
        self.assertIn("build/", ignore)


if __name__ == "__main__":
    unittest.main()
