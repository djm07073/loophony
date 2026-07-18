# Symphony Quant profile

This profile runs the official Symphony Elixir orchestrator as the 24/7 control plane for one
quant-research worker. The former TypeScript goal loop is not part of this execution path.

## Runtime contract

- Linear Project: immutable big objective and the human-visible system of record.
- `[Goal]` issue: measurable success criteria. Do not give it the `symphony-quant` label.
- Child issue: one isolated Codex session and one bounded research/coding objective.
- Pending queue: `Candidate` + `Ready`, maximum five. Running work is separate.
- Concurrency: one.
- Wake-up: a 20-minute idle heartbeat/watchdog. Terminal completion triggers an immediate poll, so
  the next issue starts after the prior issue exits rather than waiting for the timer.
- Terminal decisions: `Done` and `Rejected` are automatic when evidence passes the workflow rules.
  Only `Blocked` waits for a human.
- Human review gate: at the first safe checkpoint at or after 10:00 and 22:00 KST, publish a
  Linear report and pause all new work until the user submits `maintain` or `adjust` with feedback.
- Loop memory: structured `observe → orient → act → verify → learn/handoff` checkpoints are stored
  in local SQLite. One loop is exactly one Linear child issue, identified by its immutable
  `issue_id`.

The globally installed Loophony plugin supplies the Codex App operator console. The official
Alpaca plugin supplies read-only market-data capabilities, and the Linear plugin is available to
the App for initial project provisioning and inspection. Symphony owns Linear scheduling and all
managed-project writes; workers must not call `loophony_*` control tools or the Linear plugin from
inside an issue turn.

The workflow calls the Codex App's bundled CLI directly because it supports `app-server` and shares
the App's installed plugins and authentication. The older Homebrew `codex` binary is not used.

## One-time setup

1. In the Linear team, create or map these states: `Candidate`, `Ready`, `In Progress`, `Blocked`,
   `Done`, and either `Rejected` or `Canceled`.
2. Create label `symphony-quant` and apply it only to executable child issues.
3. Create a Linear Project, a root `[Goal] ...` issue with measurable success criteria, and the
   persistent `[Agent Goal Review] Quant Research` issue without the `symphony-quant` label.
4. Render a local workflow copy with the Linear project slug, review issue, and reviewer. Prefer
   the Loophony plugin's `loophony-setup` skill so the tracked `WORKFLOW.md` stays unchanged.
5. Prepare a Git repository that stores research code, immutable data references, and result
   artifacts. Put its clone URL in the launchd plist as `QUANT_RESEARCH_REPO_URL`.
6. Install the Elixir runtime and build Symphony:

   ```sh
   cd /Users/suhajin/dev/agents/symphony-quant/elixir
   mise trust
   mise install
   mise exec -- mix setup
   mise exec -- mix build
   ```

7. Store secrets in macOS Keychain without writing them into Linear or the plist:

   ```sh
   security add-generic-password -U -s symphony-quant -a linear-api-token -w
   security add-generic-password -U -s symphony-quant -a alpaca-api-key-id -w
   security add-generic-password -U -s symphony-quant -a alpaca-api-secret-key -w
   ```

   The first item may contain a Linear personal API key or a currently valid OAuth access token.
   The present minimal runner does not yet refresh OAuth tokens; durable Linear OAuth refresh is a
   separate hardening item. Alpaca uses API keys, not OAuth, and remains read-only in this profile.

The Loophony plugin bundles a `loophony-setup` skill that automates clone verification, plugin
installation, local workflow rendering, the Elixir build, launchd registration, and health checks.
It writes the rendered workflow outside the Git clone and selects it with
`LOOPHONY_WORKFLOW_PATH`. Credential entry and connector OAuth remain explicit user steps.

## Run and supervise

Test interactively first:

```sh
export QUANT_RESEARCH_REPO_URL='git@github.com:your-org/quant-research.git'
/Users/suhajin/dev/agents/symphony-quant/quant/run.sh
```

The dashboard is available only on `127.0.0.1:8787`; Linear remains the primary dashboard.
The installed Loophony plugin uses this loopback endpoint as the Codex App operator console:
it can read the current report, request an immediate refresh, and persist instructions, goal
adjustments, or unblock decisions as Linear comments. A running turn consumes input at its next
safe continuation checkpoint; it is not interrupted mid-command. `unblock` additionally returns the
target issue to `Ready`.

At the 10:00 and 22:00 KST review windows, `loophony_status` reports an open `review_gate` and the
daemon stops dispatching new issues. Use `loophony_submit_review_decision` with `maintain` or
`adjust` plus non-empty feedback. The decision is written to the review issue and SQLite before
dispatch resumes. Silence never counts as approval.

## Loop engineering and local state

Linear remains the human-facing source of truth: objectives, issues, workpads, evidence links, and
daily reports live there. Symphony additionally writes compact machine checkpoints to
`~/.local/share/symphony-quant/loop/symphony-loop.sqlite3` by default. Each checkpoint records the
issue, phase, root-goal alignment, observation summary, decision, evidence, next action, outcome,
and turn number.

On a fresh worker session, only the current issue's recent checkpoints are appended to the initial
prompt as historical context. Checkpoints from other issues are never injected, even when their
phase is `learn` or `handoff`. The worker must reconcile current-issue memory with current Linear
and repository evidence before acting. Stable checkpoint keys make a retried or corrected cycle
update the same record. `Done` and `Rejected` checkpoints are rejected unless they contain concrete
evidence.

Cross-issue handoff is explicit rather than implicit: before finishing, the current loop writes the
reusable evidence, artifact references, next falsification test, and acceptance checks into the
next Linear Candidate. The next issue then starts a new, isolated loop and independently evaluates
its alignment with the root goal.

The JSON status API and Codex App report expose the checkpoint count, outcome totals, and recent
loop decisions. If the database is temporarily unavailable, the status report marks loop memory
unavailable. With mandatory review enabled, dispatch fails closed because Symphony cannot safely
prove that the human gate was resolved.

The scheduled review gate is orchestration state, not another research loop. It can pause an issue
after its current Codex turn reaches a safe boundary, but it does not merge SQLite checkpoints
between issues. The latest resolved human decision is injected as operator guidance when work
resumes.

After the smoke test, edit the repository URL in `launchd/com.suhajin.symphony-quant.plist`, copy it
to `~/Library/LaunchAgents`, and bootstrap it with `launchctl`. `RunAtLoad` plus `KeepAlive` restarts
unexpected exits while Symphony itself prevents overlapping issue execution.

## First Linear child issue

Create one `Candidate` child under the root goal, apply `symphony-quant`, and include:

- the root success criterion it advances;
- one bounded objective;
- deterministic acceptance checks;
- expected artifact paths and explicit non-goals.

Every completed worker either reuses or creates the next Candidate. The next session always repeats
project/root alignment before execution.
