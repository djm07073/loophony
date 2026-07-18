#!/usr/bin/env python3
"""Idempotent macOS bootstrap helper for the local Loophony daemon."""

from __future__ import annotations

import argparse
import json
import os
import plistlib
import shlex
import shutil
import subprocess
import sys
import tempfile
import time
import urllib.error
import urllib.request
from pathlib import Path


DEFAULT_REPO_URL = "https://github.com/djm07073/loophony.git"
DEFAULT_REPO_DIR = Path.home() / "dev" / "agents" / "loophony"
DEFAULT_STATE_ROOT = Path.home() / ".local" / "share" / "loophony"
DEFAULT_LAUNCH_AGENT = Path.home() / "Library" / "LaunchAgents" / "com.loophony.daemon.plist"
DEFAULT_CODEX = Path("/Applications/Codex.app/Contents/Resources/codex")
DEFAULT_BASE_URL = "http://127.0.0.1:8787"
DEFAULT_MARKETPLACE_SOURCE = "djm07073/loophony"
PUBLIC_MARKETPLACE = "loophony-public"
SERVICE_LABEL = "com.loophony.daemon"
LEGACY_SERVICE_LABELS = ("com.suhajin.symphony-quant",)
KEYCHAIN_SERVICE = "symphony-quant"


class SetupError(RuntimeError):
    pass


def resolved_path(value: str | Path) -> Path:
    return Path(value).expanduser().resolve()


def command_text(command: list[str]) -> str:
    return " ".join(shlex.quote(part) for part in command)


def run(
    command: list[str],
    *,
    cwd: Path | None = None,
    capture: bool = False,
    quiet: bool = False,
) -> subprocess.CompletedProcess[str]:
    if not quiet:
        print(f"+ {command_text(command)}")
    return subprocess.run(
        command,
        cwd=cwd,
        check=True,
        text=True,
        stdout=subprocess.PIPE if capture else None,
        stderr=subprocess.PIPE if capture else None,
    )


def atomic_write(path: Path, data: bytes, mode: int = 0o600) -> bool:
    path.parent.mkdir(parents=True, exist_ok=True)
    if path.exists() and path.read_bytes() == data:
        return False
    with tempfile.NamedTemporaryFile(dir=path.parent, delete=False) as handle:
        handle.write(data)
        temporary = Path(handle.name)
    os.chmod(temporary, mode)
    os.replace(temporary, path)
    return True


def keychain_item_exists(account: str) -> bool:
    security = shutil.which("security")
    if security is None:
        return False
    result = subprocess.run(
        [security, "find-generic-password", "-s", KEYCHAIN_SERVICE, "-a", account],
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
        check=False,
    )
    return result.returncode == 0


def preflight_payload() -> dict[str, object]:
    commands = {
        name: shutil.which(name) is not None
        for name in ("git", "mise", "security", "launchctl")
    }
    return {
        "platform": sys.platform,
        "macos": sys.platform == "darwin",
        "commands": commands,
        "codex_app_cli": DEFAULT_CODEX.is_file() and os.access(DEFAULT_CODEX, os.X_OK),
        "keychain": {
            "linear_api_token": keychain_item_exists("linear-api-token"),
            "alpaca_api_key_id": keychain_item_exists("alpaca-api-key-id"),
            "alpaca_api_secret_key": keychain_item_exists("alpaca-api-secret-key"),
        },
        "services": {
            SERVICE_LABEL: launchd_service_loaded(SERVICE_LABEL),
            **{label: launchd_service_loaded(label) for label in LEGACY_SERVICE_LABELS},
        },
    }


def cmd_preflight(args: argparse.Namespace) -> None:
    payload = preflight_payload()
    if args.json:
        print(json.dumps(payload, indent=2, sort_keys=True))
    else:
        print(f"macOS: {'ok' if payload['macos'] else 'missing'}")
        for name, present in payload["commands"].items():
            print(f"{name}: {'ok' if present else 'missing'}")
        print(f"Codex App CLI: {'ok' if payload['codex_app_cli'] else 'missing'}")
        for name, present in payload["keychain"].items():
            print(f"Keychain {name}: {'ok' if present else 'missing'}")
        for name, loaded in payload["services"].items():
            print(f"Service {name}: {'loaded' if loaded else 'not loaded'}")


def normalized_repo(value: str) -> str:
    normalized = value.removesuffix("/").removesuffix(".git")
    if ":" in normalized and "//" not in normalized:
        normalized = normalized.replace(":", "/", 1)
    return "/".join(normalized.rsplit("/", 2)[-2:])


def cmd_clone(args: argparse.Namespace) -> None:
    repo_dir = resolved_path(args.repo_dir)
    if not repo_dir.exists():
        repo_dir.parent.mkdir(parents=True, exist_ok=True)
        run(["git", "clone", args.repo_url, str(repo_dir)])
        return

    if not (repo_dir / ".git").is_dir():
        raise SetupError(f"refusing to overwrite non-repository directory: {repo_dir}")

    origin = run(
        ["git", "remote", "get-url", "origin"], cwd=repo_dir, capture=True, quiet=True
    ).stdout.strip()
    if normalized_repo(origin) != normalized_repo(args.repo_url):
        raise SetupError(f"existing clone has a different origin: {origin}")

    if args.update:
        dirty = run(
            ["git", "status", "--porcelain"], cwd=repo_dir, capture=True, quiet=True
        ).stdout.strip()
        if dirty:
            raise SetupError("refusing to update a clone with local changes")
        run(["git", "pull", "--ff-only"], cwd=repo_dir)
    else:
        print(f"reusing clone: {repo_dir}")


def replace_required(template: str, old: str, new: str) -> str:
    if old not in template:
        raise SetupError(f"workflow template is missing expected placeholder: {old}")
    return template.replace(old, new)


def write_if_allowed(path: Path, data: bytes, force: bool, mode: int = 0o600) -> bool:
    if path.exists() and path.read_bytes() != data and not force:
        raise SetupError(f"refusing to replace existing file without --force: {path}")
    return atomic_write(path, data, mode)


def cmd_configure(args: argparse.Namespace) -> None:
    repo_dir = resolved_path(args.repo_dir)
    state_root = resolved_path(args.state_root)
    launch_agent = resolved_path(args.launch_agent)
    template_path = repo_dir / "quant" / "WORKFLOW.md"
    run_path = repo_dir / "quant" / "run.sh"
    if not template_path.is_file() or not run_path.is_file():
        raise SetupError(f"not a Loophony clone: {repo_dir}")

    values = (args.project_slug, args.review_issue, args.reviewer, args.research_repo_url)
    if any(not value.strip() or "replace-with" in value for value in values):
        raise SetupError("configuration values must be non-empty and cannot contain placeholders")

    reviewer = args.reviewer if args.reviewer.startswith("@") else f"@{args.reviewer}"
    rendered = template_path.read_text()
    rendered = replace_required(rendered, "replace-with-linear-project-slug", args.project_slug)
    rendered = replace_required(rendered, "replace-with-linear-review-issue", args.review_issue)
    rendered = replace_required(rendered, "@replace-with-linear-reviewer", reviewer)

    workflow_path = state_root / "config" / "WORKFLOW.md"
    workflow_changed = write_if_allowed(
        workflow_path, rendered.encode(), args.force, mode=0o600
    )

    state_root.mkdir(parents=True, exist_ok=True)
    plist = {
        "Label": SERVICE_LABEL,
        "ProgramArguments": ["/bin/zsh", "-lc", f"exec {shlex.quote(str(run_path))}"],
        "EnvironmentVariables": {
            "LOOPHONY_WORKFLOW_PATH": str(workflow_path),
            "QUANT_RESEARCH_REPO_URL": args.research_repo_url,
            "SYMPHONY_QUANT_STATE_ROOT": str(state_root),
        },
        "RunAtLoad": True,
        "KeepAlive": {"SuccessfulExit": False},
        "ProcessType": "Background",
        "ThrottleInterval": 15,
        "StandardOutPath": str(state_root / "launchd.out.log"),
        "StandardErrorPath": str(state_root / "launchd.err.log"),
    }
    plist_data = plistlib.dumps(plist, fmt=plistlib.FMT_XML, sort_keys=False)
    plist_changed = write_if_allowed(launch_agent, plist_data, args.force, mode=0o600)

    print(
        json.dumps(
            {
                "workflow": str(workflow_path),
                "workflow_changed": workflow_changed,
                "launch_agent": str(launch_agent),
                "launch_agent_changed": plist_changed,
                "state_root": str(state_root),
            },
            indent=2,
        )
    )


def cmd_build(args: argparse.Namespace) -> None:
    repo_dir = resolved_path(args.repo_dir)
    elixir_dir = repo_dir / "elixir"
    if not (elixir_dir / "mix.exs").is_file():
        raise SetupError(f"not a Loophony Elixir project: {elixir_dir}")
    if shutil.which("mise") is None:
        raise SetupError("mise is required")
    run(["mise", "trust"], cwd=elixir_dir)
    run(["mise", "install"], cwd=elixir_dir)
    run(["mise", "exec", "--", "mix", "setup"], cwd=elixir_dir)
    run(["mise", "exec", "--", "mix", "build"], cwd=elixir_dir)


def cmd_plugins(args: argparse.Namespace) -> None:
    codex = resolved_path(args.codex)
    if not codex.is_file():
        raise SetupError(f"Codex App CLI not found: {codex}")
    plugins = args.plugin or [
        f"loophony@{PUBLIC_MARKETPLACE}",
        "linear@openai-curated",
        "alpaca@openai-curated",
    ]
    if any(plugin.endswith(f"@{PUBLIC_MARKETPLACE}") for plugin in plugins):
        listed = run(
            [str(codex), "plugin", "marketplace", "list", "--json"],
            capture=True,
            quiet=True,
        )
        payload = json.loads(listed.stdout)
        names = {entry.get("name") for entry in payload.get("marketplaces", [])}
        if PUBLIC_MARKETPLACE not in names:
            run(
                [
                    str(codex),
                    "plugin",
                    "marketplace",
                    "add",
                    args.marketplace_source,
                ]
            )
    for plugin in plugins:
        run([str(codex), "plugin", "add", plugin])


def launchd_service_loaded(label: str) -> bool:
    if sys.platform != "darwin" or shutil.which("launchctl") is None:
        return False
    result = subprocess.run(
        ["launchctl", "print", f"gui/{os.getuid()}/{label}"],
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
        check=False,
    )
    return result.returncode == 0


def daemon_api_reachable(base_url: str) -> bool:
    try:
        with urllib.request.urlopen(
            f"{base_url.rstrip('/')}/api/v1/state", timeout=1.0
        ) as response:
            return response.status == 200
    except (OSError, urllib.error.URLError):
        return False


def cmd_service(args: argparse.Namespace) -> None:
    if sys.platform != "darwin" or shutil.which("launchctl") is None:
        raise SetupError("launchd service management requires macOS")
    launch_agent = resolved_path(args.launch_agent)
    domain = f"gui/{os.getuid()}"
    target = f"{domain}/{SERVICE_LABEL}"

    if args.action in {"install", "restart"}:
        if not launch_agent.is_file():
            raise SetupError(f"launch agent not found; run configure first: {launch_agent}")
        current_loaded = launchd_service_loaded(SERVICE_LABEL)
        legacy_loaded = [
            label for label in LEGACY_SERVICE_LABELS if launchd_service_loaded(label)
        ]
        if legacy_loaded:
            raise SetupError(
                "refusing to start beside legacy service(s): " + ", ".join(legacy_loaded)
            )
        if not current_loaded and daemon_api_reachable(args.base_url):
            raise SetupError(
                f"refusing to start a second daemon; {args.base_url} is already serving state"
            )
        if current_loaded:
            run(["launchctl", "bootout", domain, str(launch_agent)])
        run(["launchctl", "bootstrap", domain, str(launch_agent)])
        run(["launchctl", "kickstart", "-k", target])
        return

    if args.action == "start":
        if not launchd_service_loaded(SERVICE_LABEL):
            raise SetupError("service is not installed; use service install")
        run(["launchctl", "kickstart", "-k", target])
        return

    if args.action == "stop":
        if launchd_service_loaded(SERVICE_LABEL):
            run(["launchctl", "bootout", domain, str(launch_agent)])
        else:
            print("service is already stopped")
        return

    result = subprocess.run(["launchctl", "print", target], check=False, text=True)
    if result.returncode != 0:
        raise SetupError("service is not loaded")


def cmd_health(args: argparse.Namespace) -> None:
    url = f"{args.base_url.rstrip('/')}/api/v1/state"
    last_error: Exception | None = None
    for _ in range(args.attempts):
        try:
            with urllib.request.urlopen(url, timeout=args.timeout) as response:
                body = response.read().decode()
                payload = json.loads(body)
                print(
                    json.dumps(
                        {"url": url, "status": response.status, "state": payload},
                        indent=2,
                    )
                )
                return
        except (OSError, ValueError, urllib.error.URLError) as error:
            last_error = error
            time.sleep(args.delay)
    raise SetupError(f"Loophony health check failed for {url}: {last_error}")


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description=__doc__)
    subparsers = parser.add_subparsers(dest="command", required=True)

    preflight = subparsers.add_parser(
        "preflight", help="check local requirements without changing state"
    )
    preflight.add_argument("--json", action="store_true")
    preflight.set_defaults(func=cmd_preflight)

    clone = subparsers.add_parser("clone", help="clone or verify the Loophony repository")
    clone.add_argument("--repo-url", default=DEFAULT_REPO_URL)
    clone.add_argument("--repo-dir", default=str(DEFAULT_REPO_DIR))
    clone.add_argument("--update", action="store_true")
    clone.set_defaults(func=cmd_clone)

    configure = subparsers.add_parser(
        "configure", help="render local workflow and launchd files"
    )
    configure.add_argument("--repo-dir", default=str(DEFAULT_REPO_DIR))
    configure.add_argument("--state-root", default=str(DEFAULT_STATE_ROOT))
    configure.add_argument("--launch-agent", default=str(DEFAULT_LAUNCH_AGENT))
    configure.add_argument("--project-slug", required=True)
    configure.add_argument("--review-issue", required=True)
    configure.add_argument("--reviewer", required=True)
    configure.add_argument("--research-repo-url", required=True)
    configure.add_argument("--force", action="store_true")
    configure.set_defaults(func=cmd_configure)

    build = subparsers.add_parser("build", help="install runtimes and build the Elixir daemon")
    build.add_argument("--repo-dir", default=str(DEFAULT_REPO_DIR))
    build.set_defaults(func=cmd_build)

    plugins = subparsers.add_parser("plugins", help="install Codex plugins")
    plugins.add_argument("--codex", default=str(DEFAULT_CODEX))
    plugins.add_argument("--marketplace-source", default=DEFAULT_MARKETPLACE_SOURCE)
    plugins.add_argument("--plugin", action="append")
    plugins.set_defaults(func=cmd_plugins)

    service = subparsers.add_parser("service", help="manage the launchd daemon")
    service.add_argument(
        "action", choices=("install", "start", "stop", "restart", "status")
    )
    service.add_argument("--launch-agent", default=str(DEFAULT_LAUNCH_AGENT))
    service.add_argument("--base-url", default=DEFAULT_BASE_URL)
    service.set_defaults(func=cmd_service)

    health = subparsers.add_parser("health", help="query the loopback status API")
    health.add_argument("--base-url", default=DEFAULT_BASE_URL)
    health.add_argument("--attempts", type=int, default=10)
    health.add_argument("--delay", type=float, default=1.0)
    health.add_argument("--timeout", type=float, default=3.0)
    health.set_defaults(func=cmd_health)

    return parser


def main() -> int:
    parser = build_parser()
    args = parser.parse_args()
    try:
        args.func(args)
    except (SetupError, subprocess.CalledProcessError) as error:
        print(f"error: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
