#!/usr/bin/env python3
"""Invoke trusted Nipto worker endpoints without exposing secrets.

The worker secret is read from the CRON_SECRET environment variable or from the
local ignored .env.supabase.local file. The script prints only HTTP statuses.
"""

import argparse
import json
import os
from pathlib import Path
import sys
import urllib.error
import urllib.request


ROOT = Path(__file__).resolve().parents[1]
SUPABASE_ENV = ROOT / ".env.supabase.local"
PROJECT_REF = "advmjribduqzyuwktkod"
PUBLISHABLE_KEY = (
    "sb_publishable_zxqki-GLfT6zi-BXT1h6zw_nWq9Nhye"
)
BASE_URL = f"https://{PROJECT_REF}.supabase.co/functions/v1"
WORKERS = {
    "push": f"{BASE_URL}/nipto-push-dispatch/worker/run",
    "privacy": f"{BASE_URL}/nipto-privacy/worker/run",
}


class InvocationError(Exception):
    """Raised when a worker cannot be invoked safely."""


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


def resolve_secret() -> str:
    """Resolve CRON_SECRET from the environment or local ignored config."""
    secret = os.environ.get("CRON_SECRET", "").strip()
    if secret:
        return secret
    return read_env(SUPABASE_ENV).get("CRON_SECRET", "").strip()


def build_request(worker: str, secret: str) -> urllib.request.Request:
    """Build a worker POST request with only non-secret values in its URL."""
    if worker not in WORKERS:
        raise InvocationError(f"unknown worker: {worker}")
    if not secret:
        raise InvocationError("CRON_SECRET is not configured")
    body = json.dumps({} if worker == "push" else {"limit": 5}).encode("utf-8")
    return urllib.request.Request(
        WORKERS[worker],
        data=body,
        method="POST",
        headers={
            "Authorization": f"Bearer {secret}",
            "apikey": PUBLISHABLE_KEY,
            "Content-Type": "application/json",
        },
    )


def invoke(
    worker: str,
    secret: str,
    timeout: float = 60.0,
    opener=None,
) -> int:
    """Invoke one worker and return its HTTP status without logging the body."""
    request = build_request(worker, secret)
    urlopen = opener or urllib.request.urlopen
    try:
        with urlopen(request, timeout=timeout) as response:
            return int(response.status)
    except urllib.error.HTTPError as error:
        return int(error.code)


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    target = parser.add_mutually_exclusive_group(required=True)
    target.add_argument("--worker", choices=sorted(WORKERS), help="worker to invoke")
    target.add_argument("--all", action="store_true", help="invoke all workers")
    parser.add_argument("--timeout", type=float, default=60.0, help="HTTP timeout")
    args = parser.parse_args(argv)

    try:
        secret = resolve_secret()
        workers = sorted(WORKERS) if args.all else [args.worker]
        failures = 0
        for worker in workers:
            status = invoke(worker, secret, timeout=args.timeout)
            print(f"{worker}: HTTP {status}")
            if status >= 400:
                failures += 1
        return 1 if failures else 0
    except (InvocationError, OSError) as error:
        print(f"worker invocation failed: {error}", file=sys.stderr)
        return 2


if __name__ == "__main__":
    raise SystemExit(main())
