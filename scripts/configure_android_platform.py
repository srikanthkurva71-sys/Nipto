#!/usr/bin/env python3
"""Apply all Nipto-specific settings to a generated Android platform project."""

import json
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

# FCM channel id used by both the system-delivered and the in-app notifications.
FCM_CHANNEL_ID = "nipto_default"
GOOGLE_SERVICES = ANDROID / "app" / "google-services.json"
GOOGLE_SERVICES_PLUGIN_ID = "com.google.gms.google-services"
GOOGLE_SERVICES_PLUGIN_VERSION = "4.4.4"

# flutter_local_notifications needs desugaring for its Java 8+ APIs.
DESUGAR_LIBRARY = "com.android.tools:desugar_jdk_libs:2.1.4"
DESUGAR_FLAG = "isCoreLibraryDesugaringEnabled = true"

MANIFEST_ENTRIES = [
    '<uses-feature android:name="android.hardware.camera" android:required="false" />',
    '<uses-feature android:name="android.hardware.camera.autofocus" android:required="false" />',
    '<uses-permission android:name="android.permission.INTERNET" />',
    '<uses-permission android:name="android.permission.RECORD_AUDIO" />',
    '<uses-permission android:name="android.permission.CAMERA" />',
    '<uses-permission android:name="android.permission.MODIFY_AUDIO_SETTINGS" />',
    '<uses-permission android:name="android.permission.ACCESS_NETWORK_STATE" />',
    '<uses-permission android:name="android.permission.CHANGE_NETWORK_STATE" />',
    '<uses-permission android:name="android.permission.POST_NOTIFICATIONS" />',
    '<uses-permission android:name="android.permission.WAKE_LOCK" />',
]

APPLICATION_METADATA = [
    '<meta-data android:name="com.google.firebase.messaging.default_notification_channel_id" '
    f'android:value="{FCM_CHANNEL_ID}" />',
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

    for entry in APPLICATION_METADATA:
        if _entry_name(entry) in text:
            continue
        application = re.search(r"<application\b[^>]*>", text)
        if application is None:
            raise ValueError("Could not find the application element.")
        position = application.end()
        text = text[:position] + "\n        " + entry + text[position:]

    MANIFEST.write_text(text, encoding="utf-8")


def has_google_services() -> bool:
    """True only for a real, parseable google-services.json.

    The generated ``android/`` tree is gitignored, so a valid file found here
    is developer-supplied credential material that is never committed. A
    missing or malformed file leaves the Google Services plugin unapplied; the
    Dart side still supplies Firebase options at build time.
    """
    if not GOOGLE_SERVICES.is_file():
        return False
    try:
        data = json.loads(GOOGLE_SERVICES.read_text(encoding="utf-8"))
    except (OSError, UnicodeDecodeError, json.JSONDecodeError):
        return False
    if not isinstance(data, dict):
        return False
    project = data.get("project_info")
    clients = data.get("client")
    if not isinstance(project, dict) or not isinstance(clients, list):
        return False
    project_number = project.get("project_number")
    if not isinstance(project_number, str) or not project_number.strip():
        return False
    return any(
        isinstance(client, dict)
        and isinstance(client.get("mobilesdk_app_id"), str)
        and bool(client["mobilesdk_app_id"].strip())
        for client in clients
    )


def configure_desugaring(build: str) -> str:
    """Enable core library desugaring without duplicating Gradle declarations."""
    if DESUGAR_FLAG not in build:
        compile_options = re.search(r"compileOptions\s*\{", build)
        if compile_options is not None:
            insertion = compile_options.end()
        else:
            android = re.search(r"android\s*\{", build)
            if android is None:
                raise ValueError("Could not find the android configuration block.")
            insertion = android.end()
            build = (
                build[:insertion]
                + "\n    compileOptions {\n    }"
                + build[insertion:]
            )
            insertion = build.index("{", insertion) + 1
        build = (
            build[:insertion]
            + "\n        "
            + DESUGAR_FLAG
            + build[insertion:]
        )

    declaration = f'    coreLibraryDesugaring("{DESUGAR_LIBRARY}")\n'
    if DESUGAR_LIBRARY not in build:
        dependencies = re.search(r"^dependencies\s*\{", build, flags=re.MULTILINE)
        if dependencies is not None:
            insertion = dependencies.end()
            build = build[:insertion] + "\n" + declaration.rstrip() + build[insertion:]
        else:
            build = build.rstrip() + "\n\ndependencies {\n" + declaration + "}\n"
    return build


def configure_gradle() -> None:
    """Pin AGP, enforce API level, and conditionally wire Google Services."""
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

    credentials_present = has_google_services()
    declaration = (
        f'    id("{GOOGLE_SERVICES_PLUGIN_ID}") '
        f'version "{GOOGLE_SERVICES_PLUGIN_VERSION}" apply false\n'
    )
    if credentials_present:
        if GOOGLE_SERVICES_PLUGIN_ID not in settings:
            anchor = re.search(
                r'^[ \t]*id\("com\.android\.application"\)[^\n]*\n',
                settings,
                flags=re.MULTILINE,
            )
            if anchor is None:
                raise ValueError(
                    "Expected exactly one Android Gradle plugin declaration."
                )
            settings = settings[: anchor.end()] + declaration + settings[anchor.end() :]
    else:
        settings = re.sub(
            r'^[ \t]*id\("com\.google\.gms\.google-services"\)[^\n]*\n',
            "",
            settings,
            flags=re.MULTILINE,
        )
    SETTINGS.write_text(settings, encoding="utf-8")

    build = BUILD.read_text(encoding="utf-8")
    build = re.sub(
        r"minSdk\s*=\s*flutter\.minSdkVersion|minSdk\s*=\s*\d+",
        f"minSdk = {MIN_SDK}",
        build,
        count=1,
    )
    apply_line = f'    id("{GOOGLE_SERVICES_PLUGIN_ID}")\n'
    if credentials_present:
        if GOOGLE_SERVICES_PLUGIN_ID not in build:
            plugins = re.search(r"plugins\s*\{", build)
            if plugins is None:
                raise ValueError("Could not find the app plugins block.")
            block_end = build.find("}", plugins.end())
            if block_end == -1:
                raise ValueError("Unterminated app plugins block.")
            build = build[:block_end] + apply_line + build[block_end:]
    else:
        build = re.sub(
            r'^[ \t]*id\("com\.google\.gms\.google-services"\)[ \t]*\n',
            "",
            build,
            flags=re.MULTILINE,
        )
    build = configure_desugaring(build)
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
