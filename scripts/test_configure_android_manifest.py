import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

import configure_android_manifest


class ConfigureAndroidManifestTests(unittest.TestCase):
    def setUp(self):
        self.temp_dir = tempfile.TemporaryDirectory()
        self.manifest_path = Path(self.temp_dir.name) / "AndroidManifest.xml"
        self.original_manifest = """<manifest xmlns:android="http://schemas.android.com/apk/res/android">
    <application>
        <activity android:name=".MainActivity" android:exported="true">
            <meta-data android:name="flutterEmbedding" android:value="2" />
        </activity>
    </application>
</manifest>
"""

    def tearDown(self):
        self.temp_dir.cleanup()

    def test_adds_nipto_callback_and_single_top_launch_mode(self):
        self.manifest_path.write_text(self.original_manifest, encoding="utf-8")
        with patch.object(configure_android_manifest, "MANIFEST", self.manifest_path):
            self.assertEqual(configure_android_manifest.main(), 0)
            updated = self.manifest_path.read_text(encoding="utf-8")

        self.assertIn('android:scheme="nipto"', updated)
        self.assertIn('android:host="auth-callback"', updated)
        self.assertIn('android:launchMode="singleTop"', updated)
        self.assertIn('android:exported="true"', updated)
        self.assertEqual(updated.count('android:scheme="nipto"'), 1)

    def test_is_idempotent(self):
        self.manifest_path.write_text(self.original_manifest, encoding="utf-8")
        with patch.object(configure_android_manifest, "MANIFEST", self.manifest_path):
            self.assertEqual(configure_android_manifest.main(), 0)
            first = self.manifest_path.read_text(encoding="utf-8")
            self.assertEqual(configure_android_manifest.main(), 0)
            second = self.manifest_path.read_text(encoding="utf-8")

        self.assertEqual(first, second)
        self.assertEqual(second.count('android:scheme="nipto"'), 1)

    def test_fails_when_main_activity_is_missing(self):
        self.manifest_path.write_text("<manifest><application /></manifest>", encoding="utf-8")
        with patch.object(configure_android_manifest, "MANIFEST", self.manifest_path):
            self.assertEqual(configure_android_manifest.main(), 1)


if __name__ == "__main__":
    unittest.main()
