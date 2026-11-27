import json
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

import configure_android_manifest
import configure_android_platform


class ConfigureAndroidPlatformTests(unittest.TestCase):
    def setUp(self):
        self.temp_dir = tempfile.TemporaryDirectory()
        root = Path(self.temp_dir.name)
        self.manifest = root / "AndroidManifest.xml"
        self.settings = root / "settings.gradle.kts"
        self.build = root / "build.gradle.kts"
        self.google_services = root / "google-services.json"

        self.manifest.write_text(
            """<manifest xmlns:android="http://schemas.android.com/apk/res/android">
    <application android:label="nipto">
        <activity android:name=".MainActivity" android:exported="true">
            <meta-data android:name="flutterEmbedding" android:value="2" />
        </activity>
    </application>
</manifest>
""",
            encoding="utf-8",
        )
        self.settings.write_text(
            """pluginManagement {
    repositories {
    }
}

plugins {
    id("com.android.application") version "9.3.1" apply false
}
""",
            encoding="utf-8",
        )
        self.build.write_text(
            """plugins {
    id("com.android.application")
    id("dev.flutter.flutter-gradle-plugin")
}

android {
    defaultConfig {
        minSdk = flutter.minSdkVersion
    }
}
""",
            encoding="utf-8",
        )

        self.patches = [
            patch.object(configure_android_manifest, "MANIFEST", self.manifest),
            patch.object(configure_android_platform, "MANIFEST", self.manifest),
            patch.object(configure_android_platform, "SETTINGS", self.settings),
            patch.object(configure_android_platform, "BUILD", self.build),
            patch.object(
                configure_android_platform, "GOOGLE_SERVICES", self.google_services
            ),
        ]
        for item in self.patches:
            item.start()

    def tearDown(self):
        for item in reversed(self.patches):
            item.stop()
        self.temp_dir.cleanup()

    def test_configures_all_generated_platform_settings_idempotently(self):
        self.assertEqual(configure_android_platform.main(), 0)
        first = (
            self.manifest.read_text(encoding="utf-8"),
            self.settings.read_text(encoding="utf-8"),
            self.build.read_text(encoding="utf-8"),
        )

        self.assertEqual(configure_android_platform.main(), 0)
        second = (
            self.manifest.read_text(encoding="utf-8"),
            self.settings.read_text(encoding="utf-8"),
            self.build.read_text(encoding="utf-8"),
        )
        self.assertEqual(first, second)

        manifest = second[0]
        settings = second[1]
        build = second[2]
        self.assertIn('android:label="Nipto"', manifest)
        self.assertIn('android:scheme="nipto"', manifest)
        self.assertIn('android.permission.CAMERA', manifest)
        self.assertIn('android.permission.RECORD_AUDIO', manifest)
        self.assertIn('android.permission.POST_NOTIFICATIONS', manifest)
        self.assertIn('android.permission.WAKE_LOCK', manifest)
        self.assertIn(
            'android:name="com.google.firebase.messaging.default_notification_channel_id"',
            manifest,
        )
        self.assertIn('android:value="nipto_default"', manifest)
        self.assertIn("<application", manifest)
        self.assertIn("google()", settings)
        self.assertIn("mavenCentral()", settings)
        self.assertIn('version "9.3.2"', settings)
        self.assertIn("minSdk = 24", build)
        self.assertIn("isCoreLibraryDesugaringEnabled = true", build)
        self.assertIn(
            'coreLibraryDesugaring("com.android.tools:desugar_jdk_libs:2.1.4")',
            build,
        )
        self.assertEqual(build.count("isCoreLibraryDesugaringEnabled"), 1)
        self.assertEqual(build.count("coreLibraryDesugaring("), 1)
        self.assertNotIn("com.google.gms.google-services", settings)
        self.assertNotIn("com.google.gms.google-services", build)

    def test_google_services_plugin_requires_a_real_credentials_file(self):
        self.google_services.write_text(
            """{
  "project_info": {"project_number": "1234567890", "project_id": "nipto-test"},
  "client": [{"client_info": {"mobilesdk_app_id": "1:1234567890:android:abc"}}]
}
""",
            encoding="utf-8",
        )
        self.assertEqual(configure_android_platform.main(), 0)
        settings = self.settings.read_text(encoding="utf-8")
        build = self.build.read_text(encoding="utf-8")
        self.assertIn(
            'id("com.google.gms.google-services") version "4.4.4" apply false',
            settings,
        )
        self.assertIn('id("com.google.gms.google-services")', build)

        # A second run must not duplicate plugin declarations.
        self.assertEqual(configure_android_platform.main(), 0)
        self.assertEqual(settings, self.settings.read_text(encoding="utf-8"))
        self.assertEqual(build, self.build.read_text(encoding="utf-8"))

        # A malformed or removed credential file must remove both declarations.
        self.google_services.write_text("not json", encoding="utf-8")
        self.assertEqual(configure_android_platform.main(), 0)
        self.assertNotIn("com.google.gms.google-services", self.settings.read_text(encoding="utf-8"))
        self.assertNotIn("com.google.gms.google-services", self.build.read_text(encoding="utf-8"))

    def test_google_services_plugin_rejects_wrong_client_id_level(self):
        payload = {
            "project_info": {
                "project_number": "1234567890",
                "project_id": "nipto-test",
            },
            "client": [{"client_info": {}, "mobilesdk_app_id": "wrong-level-id"}],
        }
        self.google_services.write_text(json.dumps(payload), encoding="utf-8")
        self.assertEqual(configure_android_platform.main(), 0)
        self.assertNotIn(
            "com.google.gms.google-services",
            self.settings.read_text(encoding="utf-8"),
        )
        self.assertNotIn(
            "com.google.gms.google-services",
            self.build.read_text(encoding="utf-8"),
        )

    def test_desugaring_is_added_once_to_existing_gradle_blocks(self):
        self.build.write_text(
            """plugins {
    id("com.android.application")
}

android {
    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
    }
}

dependencies {
    implementation("androidx.core:core-ktx")
}
""",
            encoding="utf-8",
        )
        self.assertEqual(configure_android_platform.main(), 0)
        build = self.build.read_text(encoding="utf-8")
        self.assertEqual(build.count("isCoreLibraryDesugaringEnabled"), 1)
        self.assertEqual(build.count("coreLibraryDesugaring("), 1)

        self.assertEqual(configure_android_platform.main(), 0)
        self.assertEqual(build, self.build.read_text(encoding="utf-8"))

    def test_fails_cleanly_when_platform_is_missing(self):
        with patch.object(configure_android_platform, "BUILD", self.build.parent / "missing.gradle.kts"):
            self.assertEqual(configure_android_platform.main(), 1)


if __name__ == "__main__":
    unittest.main()
