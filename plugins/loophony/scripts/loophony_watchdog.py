#!/usr/bin/env python3
"""Frequent localhost watchdog for the Loophony launchd service."""

from __future__ import annotations

import argparse
import json
import subprocess
import sys
import time
import urllib.error
import urllib.request
from datetime import datetime, timezone
from typing import Any, Callable

DEFAULT_URL = "http://127.0.0.1:8787/api/v1/state"
DEFAULT_LABEL = "com.loophony.daemon"


def fetch_health(url: str, timeout: float = 5.0) -> dict[str, Any]:
    request = urllib.request.Request(url, headers={"Accept": "application/json"})
    with urllib.request.urlopen(request, timeout=timeout) as response:
        if response.status != 200:
            raise RuntimeError(f"unexpected HTTP status {response.status}")
        payload = json.load(response)
    if not isinstance(payload, dict):
        raise RuntimeError("health response is not an object")
    state = payload.get("state", payload)
    if not isinstance(state, dict) or "polling" not in state:
        raise RuntimeError("health response is missing polling state")
    return {"state": state}


def restart_service(label: str) -> None:
    domain = f"gui/{subprocess.check_output(['id', '-u'], text=True).strip()}"
    subprocess.run(
        ["launchctl", "kickstart", "-k", f"{domain}/{label}"],
        check=True,
        stdout=subprocess.DEVNULL,
        stderr=subprocess.PIPE,
        text=True,
    )


def run_watchdog(
    url: str,
    label: str,
    attempts: int = 6,
    delay_seconds: float = 2.0,
    fetcher: Callable[[str], dict[str, Any]] = fetch_health,
    restarter: Callable[[str], None] = restart_service,
    failure_threshold: int = 2,
) -> dict[str, Any]:
    if failure_threshold < 1:
        raise ValueError("failure_threshold must be at least 1")

    checked_at = datetime.now(timezone.utc).isoformat()
    try:
        payload = fetcher(url)
        return {"status": "healthy", "checked_at": checked_at, "restarted": False, "state": payload["state"]}
    except Exception as initial_error:
        last_error: Exception = initial_error

        for _ in range(1, failure_threshold):
            time.sleep(delay_seconds)
            try:
                payload = fetcher(url)
                return {
                    "status": "recovered",
                    "checked_at": checked_at,
                    "restarted": False,
                    "initial_error": str(initial_error),
                    "state": payload["state"],
                }
            except Exception as error:
                last_error = error

        restarter(label)
        for _ in range(attempts):
            time.sleep(delay_seconds)
            try:
                payload = fetcher(url)
                return {
                    "status": "recovered",
                    "checked_at": checked_at,
                    "restarted": True,
                    "initial_error": str(initial_error),
                    "state": payload["state"],
                }
            except Exception as error:
                last_error = error
        raise RuntimeError(f"Loophony remained unhealthy after restart: {last_error}") from last_error


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--url", default=DEFAULT_URL)
    parser.add_argument("--label", default=DEFAULT_LABEL)
    parser.add_argument("--attempts", type=int, default=6)
    parser.add_argument("--delay-seconds", type=float, default=2.0)
    parser.add_argument("--failure-threshold", type=int, default=2)
    args = parser.parse_args()
    try:
        result = run_watchdog(
            args.url,
            args.label,
            attempts=args.attempts,
            delay_seconds=args.delay_seconds,
            failure_threshold=args.failure_threshold,
        )
        print(json.dumps(result, ensure_ascii=False, sort_keys=True))
        return 0
    except Exception as error:
        print(
            json.dumps(
                {
                    "status": "failed",
                    "checked_at": datetime.now(timezone.utc).isoformat(),
                    "error": str(error),
                },
                ensure_ascii=False,
                sort_keys=True,
            ),
            file=sys.stderr,
        )
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
