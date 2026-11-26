#!/usr/bin/env python3
"""Apply all Nipto-specific settings to a generated Android platform project."""

from pathlib import Path
import re
import sys

import configure_android_manifest

ROOT = Path(__file__).resolve().parents[1]
ANDROID = ROOT / "mobile" / "app" / "android"
MANIFEST = ANDROID / "app" / "src" / "main" / "AndroidManifest.xml"
SETTINGS = ANDROID / "settings.gradle.kts"
BUILD = ANDROID / "app" / "build.gradle.kts"

AGP_VERSION = "9.3.2"
MIN_SDK = 24

MANIFEST_ENTRIES = [
    '<uses-feature android:name="android.hardware.camera" android:required="false" />',
    '<uses-feature android:name="android.hardware.camera.autofocus" android:required="false" />',
    '<uses-permission android:name="android.permission.INTERNET" />',
    '<uses-permission android:name="android.permission.RECORD_AUDIO" />',
    '<uses-permission android:name="android.permission.CAMERA" />',
    '<uses-permission android:name="android.permission.MODIFY_AUDIO_SETTINGS" />',
    '<uses-permission android:name="android.permission.ACCESS_NETWORK_STATE" />',
    '<uses-permission android:name="android.permission.CHANGE_NETWORK_STATE" />',
]


def _entry_name(entry: str) -> str:
    match = re.search(r'android:name="([^"]+)"', entry)
    if not match:
        raise ValueError(f"Malformed manifest entry: {entry}")
    return match.group(1)


def configure_manifest() -> None:
    """Configure the OAuth callback, app label, and WebRTC/media permissions."""
    if configure_android_manifest.main() != 0:
        raise ValueError("Could not configure the Nipto OAuth callback.")

    text = MANIFEST.read_text(encoding="utf-8")
    text = re.sub(
        r'android:label="[^"]*"',
        'android:label="Nipto"',
        text,
        count=1,
    )
    missing = [entry for entry in MANIFEST_ENTRIES if _entry_name(entry) not in text]
    if missing:
        insertion = "\n    ".join(missing)
        text = text.replace("<application", insertion + "\n\n    <application", 1)
    MANIFEST.write_text(text, encoding="utf-8")


def configure_gradle() -> None:
    """Pin the tested Android Gradle plugin and enforce the supported API level."""
    settings = SETTINGS.read_text(encoding="utf-8")

    repositories = re.search(r"repositories\s*\{", settings)
    if not repositories:
        raise ValueError("Could not find the plugin repositories block.")
    block_start = repositories.end()
    block_end = settings.find("}", block_start)
    if block_end == -1:
        raise ValueError("Unterminated plugin repositories block.")
    block = settings[block_start:block_end]
    additions = []
    if "google()" not in block:
        additions.append("        google()")
    if "mavenCentral()" not in block:
        additions.append("        mavenCentral()")
    if additions:
        settings = (
            settings[:block_start]
            + "\n"
            + "\n".join(additions)
            + settings[block_start:]
        )

    settings, agp_count = re.subn(
        r'(id\("com\.android\.application"\)\s+version\s+")[^"]+(")',
        lambda match: match.group(1) + AGP_VERSION + match.group(2),
        settings,
    )
    if agp_count != 1:
        raise ValueError("Expected exactly one Android Gradle plugin declaration.")
    SETTINGS.write_text(settings, encoding="utf-8")

    build = BUILD.read_text(encoding="utf-8")
    build = re.sub(
        r"minSdk\s*=\s*flutter\.minSdkVersion|minSdk\s*=\s*\d+",
        f"minSdk = {MIN_SDK}",
        build,
        count=1,
    )
    BUILD.write_text(build, encoding="utf-8")


def main() -> int:
    missing = [path for path in (MANIFEST, SETTINGS, BUILD) if not path.is_file()]
    if missing:
        print(
            "Generated Android platform files are missing: "
            + ", ".join(str(path) for path in missing),
            file=sys.stderr,
        )
        return 1

    try:
        configure_manifest()
        configure_gradle()
    except (OSError, ValueError) as error:
        print(f"Could not configure the Android platform: {error}", file=sys.stderr)
        return 1

    print("Configured Nipto Android manifest, permissions and Gradle settings.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
