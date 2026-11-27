#!/usr/bin/env python3
"""Apply Nipto's Android OAuth deep-link intent filter to a generated Flutter project."""

from pathlib import Path
import re
import sys

ROOT = Path(__file__).resolve().parents[1]
MANIFEST = ROOT / "mobile/app/android/app/src/main/AndroidManifest.xml"
INTENT_FILTER = """            <intent-filter>
                <action android:name="android.intent.action.VIEW" />
                <category android:name="android.intent.category.DEFAULT" />
                <category android:name="android.intent.category.BROWSABLE" />
                <data android:scheme="nipto" android:host="auth-callback" />
            </intent-filter>
"""


def main() -> int:
    if not MANIFEST.is_file():
        print(f"Android manifest not found: {MANIFEST}", file=sys.stderr)
        return 1

    manifest = MANIFEST.read_text(encoding="utf-8")
    if 'android:scheme="nipto"' in manifest and 'android:host="auth-callback"' in manifest:
        print("Nipto OAuth callback is already configured.")
        return 0

    activity = re.search(
        r'<activity\b(?=[^>]*android:name="[^"]*MainActivity")[^>]*>(.*?)</activity>',
        manifest,
        flags=re.DOTALL,
    )
    if activity is None:
        print("Could not find the generated Flutter MainActivity element.", file=sys.stderr)
        return 1

    activity_text = activity.group(0)
    opening_tag = activity_text.split(">", 1)[0]
    if "android:launchMode=" not in opening_tag:
        activity_text = re.sub(
            r'(<activity\b[^>]*)(>)',
            r'\1 android:launchMode="singleTop"\2',
            activity_text,
            count=1,
        )
    opening_tag = activity_text.split(">", 1)[0]
    if "android:exported=" not in opening_tag:
        activity_text = re.sub(
            r'(<activity\b[^>]*)(>)',
            r'\1 android:exported="true"\2',
            activity_text,
            count=1,
        )

    closing = activity_text.rfind("</activity>")
    updated_activity = (
        activity_text[:closing].rstrip()
        + "\n"
        + INTENT_FILTER
        + activity_text[closing:]
    )
    manifest = manifest[:activity.start()] + updated_activity + manifest[activity.end():]
    MANIFEST.write_text(manifest, encoding="utf-8")
    print("Configured nipto://auth-callback for Supabase OAuth.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
