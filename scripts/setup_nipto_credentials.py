#!/usr/bin/env python3
"""Local-only helper for Nipto credential setup.

Secret values are read from local ignored .env files and are never printed by
this script. Nothing here embeds a private key in the Flutter app or Git.
"""

import argparse
import hashlib
import json
import os
from pathlib import Path
import secrets
import shutil
import subprocess
import sys
import tempfile


ROOT = Path(__file__).resolve().parents[1]
SUPABASE_ENV = ROOT / ".env.supabase.local"
FIREBASE_ENV = ROOT / ".env.firebase.local"
GOOGLE_SERVICES = ROOT / "mobile" / "app" / "android" / "app" / "google-services.json"
TURN_ENV = ROOT / "deploy" / "turn" / ".env"
PROJECT_REF = "advmjribduqzyuwktkod"
ANDROID_PACKAGE = "com.nipto.nipto"

SUPABASE_SECRET_KEYS = (
    "CRON_SECRET",
    "FCM_SERVICE_ACCOUNT_JSON",
    "TURN_SHARED_SECRET",
    "TURN_URLS",
    "TURN_STUN_URL",
)
FIREBASE_DEFINE_KEYS = (
    "NIPTO_FIREBASE_API_KEY",
    "NIPTO_FIREBASE_PROJECT_ID",
    "NIPTO_FIREBASE_APP_ID",
    "NIPTO_FIREBASE_MESSAGING_SENDER_ID",
    "NIPTO_FIREBASE_STORAGE_BUCKET",
)


class CredentialSetupError(Exception):
    """Raised for invalid or missing local credential inputs."""


def read_env(path: Path) -> dict[str, str]:
    """Read a simple KEY=VALUE file without executing or expanding anything."""
    values: dict[str, str] = {}
    if not path.is_file():
        return values
    for raw_line in path.read_text(encoding="utf-8").splitlines():
        line = raw_line.strip()
        if not line or line.startswith("#") or "=" not in line:
            continue
        key, value = line.split("=", 1)
        key = key.strip()
        value = value.strip()
        if len(value) >= 2 and value[0] == value[-1] and value[0] in ("'", '"'):
            value = value[1:-1]
        if key:
            values[key] = value
    return values


def _quote(value: str) -> str:
    if value == "":
        return "''"
    if any(char.isspace() for char in value) or value[0] in ("'", '"', "#", "{", "["):
        if "'" in value:
            raise CredentialSetupError(
                "A local credential value contains a single quote; use a JSON "
                "file with the Supabase dashboard instead."
            )
        return "'" + value + "'"
    return value


def write_env(path: Path, updates: dict[str, str]) -> None:
    """Update an ignored local env file and restrict its permissions."""
    values = read_env(path)
    values.update(updates)
    path.parent.mkdir(parents=True, exist_ok=True)
    lines = [
        "# Local Nipto credential file. Never commit this file.",
        "# Values are intentionally not printed by setup_nipto_credentials.py.",
        "",
    ]
    for key in sorted(values):
        lines.append(f"{key}={_quote(values[key])}")
    path.write_text("\n".join(lines) + "\n", encoding="utf-8")
    try:
        path.chmod(0o600)
    except OSError:
        pass


def fingerprint(value: str) -> str:
    return "sha256:" + hashlib.sha256(value.encode("utf-8")).hexdigest()[:12]


def load_json_file(path_text: str) -> dict:
    path = Path(path_text).expanduser().resolve()
    if not path.is_file():
        raise CredentialSetupError(f"File not found: {path}")
    try:
        data = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as error:
        raise CredentialSetupError(f"Could not read JSON from {path}: {error}") from error
    if not isinstance(data, dict):
        raise CredentialSetupError(f"Expected a JSON object in {path}")
    return data


def extract_google_services(data: dict) -> dict[str, str]:
    """Extract client-safe Firebase identifiers for the Nipto Android app."""
    project = data.get("project_info")
    clients = data.get("client")
    if not isinstance(project, dict) or not isinstance(clients, list):
        raise CredentialSetupError("Invalid google-services.json structure.")
    project_id = str(project.get("project_id") or "").strip()
    project_number = str(project.get("project_number") or "").strip()
    storage_bucket = str(project.get("storage_bucket") or "").strip()
    if not project_id or not project_number:
        raise CredentialSetupError("google-services.json is missing project identifiers.")

    for client in clients:
        if not isinstance(client, dict):
            continue
        client_info = client.get("client_info")
        if not isinstance(client_info, dict):
            continue
        android = client_info.get("android_client_info")
        if not isinstance(android, dict):
            continue
        if str(android.get("package_name") or "").strip() != ANDROID_PACKAGE:
            continue
        app_id = str(client_info.get("mobilesdk_app_id") or "").strip()
        api_keys = client.get("api_key")
        if not app_id or not isinstance(api_keys, list) or not api_keys:
            raise CredentialSetupError("The Nipto Android client is incomplete.")
        api_key = str(api_keys[0].get("current_key") or "").strip()
        if not api_key:
            raise CredentialSetupError("The Nipto Android client has no current API key.")
        return {
            "NIPTO_FIREBASE_API_KEY": api_key,
            "NIPTO_FIREBASE_PROJECT_ID": project_id,
            "NIPTO_FIREBASE_APP_ID": app_id,
            "NIPTO_FIREBASE_MESSAGING_SENDER_ID": project_number,
            "NIPTO_FIREBASE_STORAGE_BUCKET": storage_bucket,
            "NIPTO_FIREBASE_ANDROID_PACKAGE_NAME": ANDROID_PACKAGE,
        }
    raise CredentialSetupError(
        f"google-services.json has no Android app for {ANDROID_PACKAGE}."
    )


def validate_service_account(data: dict) -> str:
    """Validate an FCM service-account JSON object and return its project ID."""
    if data.get("type") != "service_account":
        raise CredentialSetupError("Expected a Google service-account JSON key.")
    project_id = str(data.get("project_id") or "").strip()
    client_email = str(data.get("client_email") or "").strip()
    private_key = str(data.get("private_key") or "")
    if not project_id or not client_email:
        raise CredentialSetupError("Service account JSON is missing identifiers.")
    if not private_key.startswith("-----BEGIN PRIVATE KEY-----"):
        raise CredentialSetupError("Service account JSON has no valid private key.")
    return project_id


def supabase_cli() -> str:
    configured = os.environ.get("SUPABASE_CLI")
    if configured and Path(configured).is_file():
        return configured
    found = shutil.which("supabase")
    if found:
        return found
    fallback = Path(os.environ.get("APPDATA", "")) / "npm" / "supabase.cmd"
    if fallback.is_file():
        return str(fallback)
    raise CredentialSetupError("Supabase CLI not found. Install it or set SUPABASE_CLI.")


def _run_supabase(args: list[str]) -> str:
    cli = supabase_cli()
    command = subprocess.list2cmdline([str(cli), *args])
    result = subprocess.run(
        command,
        cwd=ROOT,
        check=False,
        capture_output=True,
        text=True,
        shell=True,
    )
    if result.returncode != 0:
        detail = (result.stderr or result.stdout).strip()
        raise CredentialSetupError(f"Supabase CLI failed: {detail}")
    return result.stdout


def cmd_worker_secret(args: argparse.Namespace) -> int:
    values = read_env(SUPABASE_ENV)
    existing = values.get("CRON_SECRET", "")
    if existing and not args.force:
        print(f"CRON_SECRET is already stored locally ({fingerprint(existing)}).")
        print("Use --force only when you intentionally want to rotate it.")
        return 0
    secret = secrets.token_urlsafe(48)
    write_env(SUPABASE_ENV, {"CRON_SECRET": secret})
    print(f"Generated CRON_SECRET locally ({fingerprint(secret)}).")
    print(f"Stored in {SUPABASE_ENV.relative_to(ROOT)}; value not printed.")
    return 0


def cmd_import_google_services(args: argparse.Namespace) -> int:
    data = load_json_file(args.path)
    identifiers = extract_google_services(data)
    google_env = read_env(FIREBASE_ENV)
    expected_project = google_env.get("NIPTO_FIREBASE_PROJECT_ID")
    if expected_project and expected_project != identifiers["NIPTO_FIREBASE_PROJECT_ID"]:
        raise CredentialSetupError(
            "This google-services.json belongs to a different Firebase project "
            "than the one already imported locally."
        )
    GOOGLE_SERVICES.parent.mkdir(parents=True, exist_ok=True)
    shutil.copyfile(Path(args.path).expanduser().resolve(), GOOGLE_SERVICES)
    write_env(FIREBASE_ENV, identifiers)
    print(
        "Imported Firebase client identifiers and copied google-services.json "
        f"to {GOOGLE_SERVICES.relative_to(ROOT)}."
    )
    print("Use --dart-define-from-file=.env.firebase.local when building.")
    return 0


def cmd_import_service_account(args: argparse.Namespace) -> int:
    data = load_json_file(args.path)
    project_id = validate_service_account(data)
    firebase_project = read_env(FIREBASE_ENV).get("NIPTO_FIREBASE_PROJECT_ID")
    if firebase_project and firebase_project != project_id:
        raise CredentialSetupError(
            "The service account project does not match the Firebase Android app."
        )
    minified = json.dumps(data, separators=(",", ":"), ensure_ascii=False)
    write_env(SUPABASE_ENV, {"FCM_SERVICE_ACCOUNT_JSON": minified})
    print(
        f"Imported FCM service account for project {project_id} "
        f"({fingerprint(minified)})."
    )
    print(f"Stored in {SUPABASE_ENV.relative_to(ROOT)}; value not printed.")
    return 0


def cmd_import_turn(args: argparse.Namespace) -> int:
    if not args.shared_secret:
        raise CredentialSetupError("A TURN shared secret is required.")
    urls = [url.strip() for url in args.urls.split(",") if url.strip()]
    for url in urls:
        if not (url.startswith("turn:") or url.startswith("turns:")):
            raise CredentialSetupError(f"Invalid TURN URL: {url}")
    if not urls:
        raise CredentialSetupError("At least one TURN URL is required.")
    if args.stun_url and not args.stun_url.startswith("stun:"):
        raise CredentialSetupError("TURN_STUN_URL must start with stun:")
    write_env(
        SUPABASE_ENV,
        {
            "TURN_SHARED_SECRET": args.shared_secret,
            "TURN_URLS": ",".join(urls),
            "TURN_STUN_URL": args.stun_url,
        },
    )
    write_env(
        TURN_ENV,
        {
            "TURN_REALM": args.realm,
            "TURN_PUBLIC_IP": args.public_ip,
            "TURN_SHARED_SECRET": args.shared_secret,
        },
    )
    print(
        "Imported TURN configuration into local Supabase and coturn env files; "
        "values not printed."
    )
    return 0


def cmd_push(args: argparse.Namespace) -> int:
    values = read_env(SUPABASE_ENV)
    selected = {key: values[key] for key in SUPABASE_SECRET_KEYS if values.get(key)}
    if not selected:
        raise CredentialSetupError(
            f"No local Supabase secrets found in {SUPABASE_ENV.relative_to(ROOT)}."
        )
    fd, temp_name = tempfile.mkstemp(prefix=".env.supabase.push.", dir=ROOT)
    temp_path = Path(temp_name)
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as handle:
            for key, value in selected.items():
                handle.write(f"{key}={_quote(value)}\n")
        _run_supabase(
            [
                "secrets",
                "set",
                f"--remote={PROJECT_REF}",
                "--yes",
                "--env-file",
                str(temp_path),
            ]
        )
    finally:
        temp_path.unlink(missing_ok=True)
    print("Set Supabase Edge Function secrets: " + ", ".join(selected))
    print("No redeploy is needed after setting secrets.")
    return 0


def cmd_check(args: argparse.Namespace) -> int:
    firebase = read_env(FIREBASE_ENV)
    supabase = read_env(SUPABASE_ENV)
    print("Local Firebase client config: " + ("complete" if all(
        firebase.get(key) for key in FIREBASE_DEFINE_KEYS if key != "NIPTO_FIREBASE_STORAGE_BUCKET"
    ) else "incomplete"))
    print(
        "google-services.json: "
        + ("present" if GOOGLE_SERVICES.is_file() else "missing")
    )
    print("Local Supabase secrets: " + ", ".join(
        key for key in SUPABASE_SECRET_KEYS if supabase.get(key)
    ) or "none")
    output = _run_supabase(
        ["secrets", "list", f"--remote={PROJECT_REF}", "--output-format", "json"]
    )
    try:
        payload = json.loads(output)
    except json.JSONDecodeError as error:
        raise CredentialSetupError("Could not parse Supabase secret list.") from error
    remote = {
        str(item.get("name"))
        for item in payload.get("secrets", [])
        if isinstance(item, dict)
    }
    print("Remote Supabase secrets: " + ", ".join(
        key for key in SUPABASE_SECRET_KEYS if key in remote
    ) or "none of the Nipto-specific secrets")
    missing = [key for key in SUPABASE_SECRET_KEYS if key not in remote]
    if missing:
        print("Missing remote secrets: " + ", ".join(missing))
    return 0


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description=__doc__)
    subparsers = parser.add_subparsers(dest="command", required=True)

    worker = subparsers.add_parser("worker-secret", help="Generate CRON_SECRET locally")
    worker.add_argument("--force", action="store_true", help="Rotate an existing secret")
    worker.set_defaults(func=cmd_worker_secret)

    google = subparsers.add_parser(
        "import-google-services", help="Import Firebase Android config"
    )
    google.add_argument("path", help="Path to downloaded google-services.json")
    google.set_defaults(func=cmd_import_google_services)

    service = subparsers.add_parser(
        "import-service-account", help="Import FCM service-account JSON"
    )
    service.add_argument("path", help="Path to downloaded service-account JSON")
    service.set_defaults(func=cmd_import_service_account)

    turn = subparsers.add_parser("import-turn", help="Import coturn and TURN secrets")
    turn.add_argument("--realm", required=True, help="TURN DNS realm")
    turn.add_argument("--public-ip", required=True, help="TURN server public IP")
    turn.add_argument("--shared-secret", required=True, help="TURN shared secret")
    turn.add_argument("--urls", required=True, help="Comma-separated turn/turns URLs")
    turn.add_argument("--stun-url", default="", help="Optional stun: URL")
    turn.set_defaults(func=cmd_import_turn)

    push = subparsers.add_parser("push", help="Push local secrets to Supabase")
    push.set_defaults(func=cmd_push)

    check = subparsers.add_parser("check", help="Show credential setup status")
    check.set_defaults(func=cmd_check)

    return parser


def main(argv: list[str] | None = None) -> int:
    parser = build_parser()
    args = parser.parse_args(argv)
    try:
        return int(args.func(args))
    except CredentialSetupError as error:
        print(f"Credential setup error: {error}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
