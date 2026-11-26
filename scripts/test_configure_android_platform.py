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
            """android {
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
        self.assertIn("google()", settings)
        self.assertIn("mavenCentral()", settings)
        self.assertIn('version "9.3.2"', settings)
        self.assertIn("minSdk = 24", build)

    def test_fails_cleanly_when_platform_is_missing(self):
        with patch.object(configure_android_platform, "BUILD", self.build.parent / "missing.gradle.kts"):
            self.assertEqual(configure_android_platform.main(), 1)


if __name__ == "__main__":
    unittest.main()
