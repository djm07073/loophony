#!/usr/bin/env python3
"""Start and configure the local Onyx/OpenSearch memory stack."""

from __future__ import annotations

import argparse
import http.cookiejar
import json
import os
from pathlib import Path
import secrets
import shutil
import subprocess
import sys
import time
import urllib.error
import urllib.parse
import urllib.request


SCRIPT_DIR = Path(__file__).resolve().parent
ELIXIR_DIR = SCRIPT_DIR.parent
COMPOSE_FILE = ELIXIR_DIR / "docker-compose.onyx.yml"
ENV_FILE = ELIXIR_DIR / ".env.onyx"
API_URL = "http://127.0.0.1:8780"
KEYCHAIN_SERVICE = "symphony-quant"
KEYCHAIN_ACCOUNT = "onyx-api-key"
PAT_NAME = "loophony-memory"
EMBEDDING_MODEL = "intfloat/multilingual-e5-base"


def random_password() -> str:
    return "Lo0!" + secrets.token_urlsafe(28)


def read_env(path: Path) -> dict[str, str]:
    values: dict[str, str] = {}
    if not path.exists():
        return values
    for raw_line in path.read_text(encoding="utf-8").splitlines():
        line = raw_line.strip()
        if not line or line.startswith("#") or "=" not in line:
            continue
        key, value = line.split("=", 1)
        values[key] = value
    return values


def ensure_env(path: Path) -> dict[str, str]:
    values = read_env(path)
    defaults = {
        "POSTGRES_USER": "postgres",
        "POSTGRES_PASSWORD": random_password(),
        "OPENSEARCH_ADMIN_PASSWORD": random_password(),
        "USER_AUTH_SECRET": secrets.token_hex(32),
        "ENCRYPTION_KEY_SECRET": secrets.token_hex(32),
        "ONYX_ADMIN_EMAIL": "loophony-admin@example.com",
        "ONYX_ADMIN_PASSWORD": random_password(),
    }
    changed = False
    for key, value in defaults.items():
        if not values.get(key):
            values[key] = value
            changed = True

    if changed or not path.exists():
        path.write_text(
            "".join(f"{key}={value}\n" for key, value in values.items()),
            encoding="utf-8",
        )
        path.chmod(0o600)
    return values


def run(command: list[str], *, quiet: bool = False) -> subprocess.CompletedProcess[str]:
    return subprocess.run(
        command,
        check=True,
        text=True,
        stdout=subprocess.DEVNULL if quiet else None,
        stderr=subprocess.DEVNULL if quiet else None,
    )


class OnyxSession:
    def __init__(self, base_url: str) -> None:
        self.base_url = base_url.rstrip("/")
        self.cookies = http.cookiejar.CookieJar()
        self.opener = urllib.request.build_opener(
            urllib.request.HTTPCookieProcessor(self.cookies)
        )

    def request(
        self,
        method: str,
        path: str,
        *,
        payload: object | None = None,
        form: dict[str, str] | None = None,
        api_key: str | None = None,
        allowed_statuses: tuple[int, ...] = (200, 201, 204),
    ) -> tuple[int, object | None]:
        headers = {"Accept": "application/json"}
        data = None
        if payload is not None:
            data = json.dumps(payload).encode("utf-8")
            headers["Content-Type"] = "application/json"
        elif form is not None:
            data = urllib.parse.urlencode(form).encode("utf-8")
            headers["Content-Type"] = "application/x-www-form-urlencoded"
        if api_key:
            headers["Authorization"] = f"Bearer {api_key}"

        request = urllib.request.Request(
            f"{self.base_url}{path}", data=data, headers=headers, method=method
        )
        try:
            response = self.opener.open(request, timeout=180)
            status = response.status
            raw_body = response.read()
        except urllib.error.HTTPError as error:
            status = error.code
            raw_body = error.read()

        body: object | None = None
        if raw_body:
            try:
                body = json.loads(raw_body)
            except json.JSONDecodeError:
                body = raw_body.decode("utf-8", errors="replace")
        if status not in allowed_statuses:
            summary = str(body)[:1_000]
            raise RuntimeError(f"Onyx {method} {path} returned HTTP {status}: {summary}")
        return status, body


def wait_for_api(session: OnyxSession, timeout_seconds: int = 600) -> None:
    deadline = time.monotonic() + timeout_seconds
    while time.monotonic() < deadline:
        try:
            with urllib.request.urlopen("http://127.0.0.1:8780/health", timeout=10):
                pass
            return
        except OSError:
            time.sleep(2)
    raise RuntimeError("Onyx API did not become healthy within 10 minutes")


def login(session: OnyxSession, env: dict[str, str]) -> None:
    email = env["ONYX_ADMIN_EMAIL"]
    password = env["ONYX_ADMIN_PASSWORD"]
    session.request(
        "POST",
        "/auth/register",
        payload={"email": email, "password": password},
        allowed_statuses=(201, 400),
    )
    session.request(
        "POST", "/auth/login", form={"username": email, "password": password}
    )


def keychain_api_key() -> str | None:
    if not shutil.which("security"):
        return None
    result = subprocess.run(
        [
            "security",
            "find-generic-password",
            "-s",
            KEYCHAIN_SERVICE,
            "-a",
            KEYCHAIN_ACCOUNT,
            "-w",
        ],
        check=False,
        capture_output=True,
        text=True,
    )
    return result.stdout.strip() if result.returncode == 0 else None


def api_key_is_valid(session: OnyxSession, api_key: str | None) -> bool:
    if not api_key:
        return False
    try:
        session.request(
            "GET", "/search-settings/get-current-search-settings", api_key=api_key
        )
        return True
    except RuntimeError:
        return False


def provision_api_key(session: OnyxSession) -> str:
    existing_key = keychain_api_key()
    if api_key_is_valid(session, existing_key):
        return existing_key or ""

    _, response = session.request("GET", "/user/pats")
    descriptors = response if isinstance(response, list) else []
    descriptor = next(
        (
            item
            for item in descriptors
            if isinstance(item, dict) and item.get("name") == PAT_NAME
        ),
        None,
    )
    if descriptor:
        session.request("DELETE", f"/user/pats/{descriptor.get('id')}")
    _, created = session.request(
        "POST", "/user/pats", payload={"name": PAT_NAME, "expiration_days": None}
    )
    if not isinstance(created, dict) or not isinstance(created.get("token"), str):
        raise RuntimeError("Onyx did not return a new personal access token")
    api_key = created["token"]

    if not shutil.which("security"):
        raise RuntimeError("macOS Keychain command 'security' is required")
    run(
        [
            "security",
            "add-generic-password",
            "-U",
            "-s",
            KEYCHAIN_SERVICE,
            "-a",
            KEYCHAIN_ACCOUNT,
            "-w",
            api_key,
        ],
        quiet=True,
    )
    return api_key


def verify_embedding(session: OnyxSession, api_key: str) -> dict[str, object]:
    _, settings = session.request(
        "GET", "/search-settings/get-current-search-settings", api_key=api_key
    )
    if not isinstance(settings, dict):
        raise RuntimeError("Onyx search settings response was not an object")
    if settings.get("model_name") != EMBEDDING_MODEL or settings.get("model_dim") != 768:
        raise RuntimeError(
            "Onyx was initialized with an unexpected embedding model. "
            "Use an empty Onyx data volume or change the embedding model in the Onyx admin UI."
        )
    return settings


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--skip-compose", action="store_true", help="Configure an already-running Onyx stack"
    )
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    if not shutil.which("docker"):
        raise RuntimeError("Docker is required")

    env = ensure_env(ENV_FILE)
    if not args.skip_compose:
        run(
            [
                "docker",
                "compose",
                "--env-file",
                str(ENV_FILE),
                "-f",
                str(COMPOSE_FILE),
                "up",
                "-d",
                "--remove-orphans",
                "--wait",
                "--wait-timeout",
                "600",
            ]
        )

    session = OnyxSession(API_URL)
    wait_for_api(session)
    login(session, env)
    api_key = provision_api_key(session)
    settings = verify_embedding(session, api_key)
    print("Onyx v4 is ready at http://127.0.0.1:8781")
    print("OpenSearch 3.6 is healthy and reachable only inside the Docker network")
    print(f"Embedding model: {settings['model_name']} ({settings['model_dim']} dimensions)")
    print("Retrieval: LLM-free OpenSearch keyword/vector hybrid; Codex generates answers")
    print("Loophony Onyx personal access token: stored in macOS Keychain")
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (OSError, RuntimeError, subprocess.CalledProcessError) as error:
        print(f"error: {error}", file=sys.stderr)
        raise SystemExit(1)
