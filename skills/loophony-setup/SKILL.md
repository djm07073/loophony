---
name: loophony-setup
description: Install, bootstrap, update, repair, or verify Loophony on macOS from its public GitHub repository. Use when Codex needs to register the public Loophony plugin marketplace, install the Loophony, Linear, and Alpaca plugins, clone the daemon, configure a Linear project and review issue, build the Elixir runtime, register launchd, or diagnose local daemon health.
---

# Loophony Setup

Bootstrap from the public repository without assuming any pre-existing local plugin checkout.

## Workflow

1. Require macOS and Codex App. Use the App-bundled CLI at
   `/Applications/Codex.app/Contents/Resources/codex`.
2. Clone `https://github.com/djm07073/loophony.git` into `~/dev/agents/loophony`, or reuse a clean
   matching clone. Never overwrite a directory or discard local changes.
3. Set `SETUP_SCRIPT=~/dev/agents/loophony/plugins/loophony/scripts/loophony_setup.py` and run
   `preflight --json`.
4. If `mise` is absent, ask before installing it. Do not silently install a package manager.
5. Run `plugins`. It registers the `djm07073/loophony` marketplace when missing and installs
   `loophony@loophony-public`, `linear@openai-curated`, and `alpaca@openai-curated`.
6. Tell the user to connect Linear and Alpaca in Codex App. Plugin installation does not complete
   OAuth. New skills and tools require a new Codex task.
7. Collect only these non-secret values when absent: Linear project slug, persistent review issue
   identifier, reviewer handle, and research repository clone URL.
8. Run `configure` with those values. It writes the rendered workflow under
   `~/.local/share/loophony`, not inside the Git clone.
   The default quant profile is autonomous: `review.enabled` remains `false`, routine scheduled
   reviews do not pause dispatch, and human feedback arrives asynchronously through the operator
   control plane. Do not enable scheduled review gates unless the user explicitly requests them.
9. If the `linear-api-token` Keychain item is absent, ask the user to enter it directly in a local
   terminal with `security add-generic-password -U -s symphony-quant -a linear-api-token -w`.
   Never request or echo the token in chat.
   When a separate Linear agent identity should own all tracker work, its token may instead be
   stored with `security add-generic-password -U -s symphony-quant -a linear-notifier-api-token -w`.
   The launcher prefers this compatibility item over `linear-api-token`; reviewer mentions still
   target the configured human handle.
10. Run `build`.
11. Run `service install` only when the user asked to begin 24/7 operation. Starting may dispatch an
    existing Ready issue immediately.
12. Run `health`. Do not report success unless the loopback API responds.

Typical commands after cloning:

```sh
python3 "$SETUP_SCRIPT" preflight --json
python3 "$SETUP_SCRIPT" plugins
python3 "$SETUP_SCRIPT" configure \
  --repo-dir ~/dev/agents/loophony \
  --project-slug PROJECT \
  --review-issue TEAM-123 \
  --reviewer @name \
  --research-repo-url git@github.com:org/research.git
python3 "$SETUP_SCRIPT" build --repo-dir ~/dev/agents/loophony
python3 "$SETUP_SCRIPT" service install
python3 "$SETUP_SCRIPT" health
```

## Boundaries

- Keep the API on loopback.
- Refuse to start beside a legacy Symphony service or another daemon on port 8787.
- Keep credentials out of files, Linear, SQLite, logs, prompts, and command arguments.
- Keep the managed Linear project single-writer: the daemon owns runtime transitions.
- Keep routine execution autonomous. Only a genuine Blocked condition and separately authorized
  actions such as SC-06 live trading may wait for human input.
- Never enable live trading during setup.
- Preserve the generated workflow and SQLite state during updates.
- The current daemon does not refresh Linear OAuth tokens; do not claim durable OAuth until that is
  implemented and verified.
