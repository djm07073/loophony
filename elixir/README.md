# Symphony Elixir

This directory contains the current Elixir/OTP implementation of Symphony, based on
[`SPEC.md`](../SPEC.md) at the repository root.

> [!WARNING]
> Symphony Elixir is prototype software intended for evaluation only and is presented as-is.
> We recommend implementing your own hardened version based on `SPEC.md`.

## Screenshot

![Symphony Elixir screenshot](../.github/media/elixir-screenshot.png)

## How it works

1. Polls Linear for candidate work
2. Creates a workspace per issue
3. Launches Codex in [App Server mode](https://developers.openai.com/codex/app-server/) inside the
   workspace
4. Sends a workflow prompt to Codex
5. Keeps Codex working on the issue until the work is done

During app-server sessions, Symphony also serves client-side `linear_graphql`,
`symphony_loop_checkpoint`, `symphony_wait`, and `symphony_job_*` tools. They support bounded
Linear access, semantic checkpoints, durable automated waits, and supervised commands whose
status and logs survive fresh turns and daemon restarts. The checkpoint tool records
structured observations, decisions, verification evidence, and next actions in local SQLite so a
fresh Codex session can resume the feedback loop without depending on chat history. Each semantic
checkpoint revision is also appended to Linear as a new immutable comment with UTC and KST times;
identical retries are deduplicated with a deterministic content marker.

When `observability.linear_heartbeat_interval_ms` is positive, the orchestrator also appends a
timestamped Linear health comment for each running issue at that interval. It reports the daemon
boot ID, worker process state, session, latest Codex event time, silence age, configured stall
threshold, and next heartbeat. Stall detection still runs independently on every poll and restarts
a silent worker after `codex.stall_timeout_ms`.

If a claimed issue moves to a terminal state (`Done`, `Closed`, `Cancelled`, or `Duplicate`),
Symphony stops the active agent for that issue and cleans up matching workspaces.

If Codex reports that operator input, approval, or MCP elicitation is required, Symphony keeps the
issue claimed and exposes it as blocked in the runtime state, JSON API, and dashboard. Blocked
entries are in memory only; restarting the orchestrator clears that blocked map, so any still-active
Linear issue can become a dispatch candidate again after restart.

## How to use it

1. Make sure your codebase is set up to work well with agents: see
   [Harness engineering](https://openai.com/index/harness-engineering/).
2. Get a new personal token in Linear via Settings → Security & access → Personal API keys, and
   set it as the `LINEAR_API_KEY` environment variable.
3. Copy this directory's `WORKFLOW.md` to your repo.
4. Optionally copy the `commit`, `push`, `pull`, `land`, and `linear` skills to your repo.
   - The `linear` skill expects Symphony's `linear_graphql` app-server tool for raw Linear GraphQL
     operations such as comment editing or upload flows.
5. Customize the copied `WORKFLOW.md` file for your project.
   - To get your project's slug, right-click the project and copy its URL. The slug is part of the
     URL.
   - When creating a workflow based on this repo, note that it depends on non-standard Linear
     issue statuses: "Rework", "Human Review", and "Merging". You can customize them in
     Team Settings → Workflow in Linear.
6. Follow the instructions below to install the required runtime dependencies and start the service.

## Prerequisites

We recommend using [mise](https://mise.jdx.dev/) to manage Elixir/Erlang versions.

```bash
mise install
mise exec -- elixir --version
```

## Run

```bash
git clone https://github.com/openai/symphony
cd symphony/elixir
mise trust
mise install
mise exec -- mix setup
mise exec -- mix build
mise exec -- ./bin/symphony ./WORKFLOW.md
```

## Configuration

Pass a custom workflow file path to `./bin/symphony` when starting the service:

```bash
./bin/symphony /path/to/custom/WORKFLOW.md
```

If no path is passed, Symphony defaults to `./WORKFLOW.md`.

Optional flags:

- `--logs-root` tells Symphony to write logs under a different directory (default: `./log`)
- `--port` also starts the Phoenix observability service (default: disabled)

The `WORKFLOW.md` file uses YAML front matter for configuration, plus a Markdown body used as the
Codex session prompt.

Minimal example:

```md
---
tracker:
  kind: linear
  project_slug: "..."
workspace:
  root: ~/code/workspaces
loop:
  database_path: ~/code/workspaces/_loop/symphony-loop.sqlite3
  recent_limit: 12
audit:
  enabled: true
  database_path: ~/.local/share/loophony/audit.sqlite3
automation:
  enabled: true
  database_path: ~/.local/share/loophony/runtime.sqlite3
intake:
  enabled: true
  todo_state: Todo
  completed_state: Done
  max_claims_per_poll: 1
handoff:
  enabled: true
  planner_model: gpt-5.6-sol
  default_execution_model: gpt-5.3-codex-spark
  allowed_models: [gpt-5.6-sol, gpt-5.3-codex-spark]
budget:
  enabled: true
  max_tokens_per_issue: 5000000
  max_tokens_per_day: 20000000
  max_active_seconds_per_issue: 3600
  warn_at_percent: 70
  on_exhausted: warn
goal_policy:
  enabled: true
memory:
  enabled: true
  onyx_api_url: http://127.0.0.1:8780
  onyx_api_key: $ONYX_API_KEY
  project: loophony
  search_limit: 12
observability:
  linear_heartbeat_interval_ms: 900000
review:
  enabled: true
  timezone: Asia/Seoul
  times: ["10:00", "22:00"]
  issue_identifier: QNT-REVIEW
  reviewer: "@owner"
hooks:
  after_create: |
    git clone git@github.com:your-org/your-repo.git .
agent:
  max_concurrent_agents: 1
  max_queued_issues: 1
  max_turns: 20
codex:
  command: codex app-server
---

You are working on a Linear issue {{ issue.identifier }}.

Title: {{ issue.title }} Body: {{ issue.description }}
```

Notes:

- If a value is missing, defaults are used.
- `tracker.required_labels` is optional. When set, an issue must have every
  configured label to dispatch or continue running. Label matching ignores
  case and surrounding whitespace. A blank configured label matches no issue.
- Safer Codex defaults are used when policy fields are omitted:
  - `codex.approval_policy` defaults to `{"reject":{"sandbox_approval":true,"rules":true,"mcp_elicitations":true}}`
  - `codex.thread_sandbox` defaults to `workspace-write`
  - `codex.turn_sandbox_policy` defaults to a `workspaceWrite` policy rooted at the current issue workspace
- Supported `codex.approval_policy` values depend on the targeted Codex app-server version. In the current local Codex schema, string values include `untrusted`, `on-failure`, `on-request`, and `never`, and object-form `reject` is also supported.
- Supported `codex.thread_sandbox` values: `read-only`, `workspace-write`, `danger-full-access`.
- `handoff.enabled` routes each issue to a top-level model at `thread/start`. Unmarked issues use
  `handoff.planner_model`. A successor description containing exactly one
  `loophony-handoff:v1` marker uses its allowed `target_model`, so a Sol judgment session can hand
  bounded implementation/tests to a fresh Spark session or complex implementation to a fresh Sol
  session.
- Handoff startup fails closed unless the source issue is distinct and terminal. Terminal
  completion fails closed unless Linear contains a distinct marked Todo successor created after
  the current session began, tied to the current issue, and named in the final checkpoint, or the
  checkpoint records an explicit root-goal termination reason. Older Todo issues cannot be
  repurposed as successors.
- When `codex.turn_sandbox_policy` is set explicitly, Symphony passes the map through to Codex
  unchanged. Compatibility then depends on the targeted Codex app-server version rather than local
  Symphony validation.
- Workflows that run package managers or other commands that resolve external hosts should set
  `networkAccess: true` in `codex.turn_sandbox_policy`; otherwise DNS/network access may be denied
  by the Codex turn sandbox.
- `agent.max_turns` caps how many back-to-back Codex turns Symphony will run in a single agent
  invocation when a turn completes normally but the issue is still in an active state. Default: `20`.
- `agent.max_concurrent_agents` and `agent.max_queued_issues` are fixed at `1`. Values other than
  `1` are invalid. This guarantees one top-level Codex worker and one pending candidate globally;
  subsessions or subagents created inside the active worker remain available.
- `loop.database_path` selects the local SQLite checkpoint ledger. It defaults to
  `<workspace.root>/_loop/symphony-loop.sqlite3` and may use `$VAR`.
- `loop.recent_limit` controls how many recent checkpoints appear in status and fresh-session
  context. Default: `12`; valid range: `1..100`.
- Stable checkpoint keys are idempotent per issue. Terminal `done` and `rejected` checkpoints
  require non-empty evidence.
- `audit` stores a secret-redacted append-only event ledger with a SHA-256 hash chain. Verify it
  with `GET /api/v1/audit/verify`; the chain detects local tampering but is not a substitute for
  exporting the head hash to an independently controlled system.
- `automation` stores durable waits, job metadata, and budget counters. `symphony_wait` releases on
  time, a workspace file/hash change, a loopback HTTP status, or durable job completion.
  `symphony_job_start` accepts an executable plus an argument array, runs only from the issue
  workspace, and writes a durable log and exit-code marker.
- `intake.enabled` turns operator feedback into a new `[Human]` issue in `intake.todo_state`.
  Loophony sorts pending Human issues by Linear priority (`1` urgent through `4` low, then no
  priority) and oldest creation time, claims at most `max_claims_per_poll`, and creates a linked
  `[Work]` issue with the same project, team, assignee, labels, and priority. Only Work issues enter
  the normal dispatch queue. Description markers recover an existing Work issue after restart, so
  a partially completed claim does not create a duplicate. The Human source stays in Todo while
  Work or any marked downstream handoff issue is open, avoiding a second In Progress record. Only
  completion of the entire handoff chain moves its source Human issue to
  `intake.completed_state`. Human and Work descriptions inherit the source issue's mapped goal
  stage so goal-policy validation remains valid.
- `budget.on_exhausted: warn` records a one-time Linear warning and audit event while work
  continues. `block` remains an explicit fail-closed option. `wait` pauses a daily-token-only
  exhaustion until the next UTC day; issue token or runtime limits still block in `wait` mode.
- `goal_policy` can require a versioned goal, exactly one active `SC-XX` stage, at most one
  executable `In Progress` issue, and exact issue-to-stage mappings before dispatch. Any number of
  aligned `Todo` issues may wait; when one issue is already `In Progress`, only that issue is
  eligible to resume.
- `memory.enabled` sends the canonical Linear project description, current issue snapshots,
  deterministic completed-session summaries, existing and new checkpoints, final agent messages,
  errors, and selected session events to Onyx v4. Loophony creates contextual paragraph-aware
  sections; Onyx embeds them and provides LLM-free OpenSearch 3.6 keyword/vector hybrid retrieval.
  Codex generates the answer.
- Linear project and issue snapshots use stable IDs and update after successful tracker reads.
  Session summaries use the project objective as a compact goal lens: active stage, intended
  outcome, rationale, mapped `SC-XX` criteria, and recorded checkpoint alignment. These summaries
  are derived navigation records; raw checkpoint and response evidence remains indexed for
  verification. In-process content hashes skip unchanged re-embedding.
- Run `python3 scripts/onyx_bootstrap.py` before enabling memory. The bootstrap pins Onyx v4.0.0
  and OpenSearch 3.6.0, configures the 768-dimensional
  `intfloat/multilingual-e5-base` model, and stores an Onyx administrator personal access token in
  Keychain.
- `memory.onyx_api_key` is required when memory is enabled. Prefer `$ONYX_API_KEY`; the bundled
  launcher loads it from the `symphony-quant` / `onyx-api-key` macOS Keychain item.
- Memory availability is based on a functional hybrid-search canary. Search and ingestion health,
  consecutive failures, circuit-breaker state, and last successful timestamps are exposed
  separately in the dashboard and status API.
- The read-only memory API is `GET /api/v1/memory/status`, `POST /api/v1/memory/search`, and
  `GET /api/v1/memory/sessions/:session_id`. Search results retain issue, session, and evidence IDs;
  the session endpoint returns its derived summary separately from ordered raw evidence.
- `rejected` is an evidence outcome for a valid negative result; the managed Linear issue still
  closes as `Done`. Workers must not choose `Canceled`, `Cancelled`, or `Duplicate`.
- `review.enabled` activates a durable, global human-feedback gate. This implementation supports
  `Asia/Seoul`; `review.times` defaults to `10:00` and `22:00`.
- Enabled review requires a persistent `review.issue_identifier` and Linear `review.reviewer`.
  The first poll after each window posts a report, pauses new dispatch, and waits for explicit
  `maintain` or `adjust` feedback. The same reviewer is mentioned on the affected issue when a
  runtime input or approval request puts work into `Blocked`.
- When a completed worker has moved its issue out of the active states, Symphony immediately polls
  for the next single issue. `polling.interval_ms` is only an idle heartbeat and watchdog; it never
  adds a fixed delay between completed issues.
- A worker cannot leave an issue terminal unless a terminal `learn`/`handoff` checkpoint exists and
  the tracker can re-read a different eligible Candidate. With handoff routing enabled, that
  Candidate must be Todo, contain one valid marker pointing to the current immutable issue ID, use
  an allowed target model, and be named in the checkpoint. If any proof is missing, Symphony
  restores the issue to `In Progress` and continues or retries the same worker. A fully proven root
  may omit a successor only with `termination_reason=<reason>` in the checkpoint.
- If the Markdown body is blank, Symphony uses a default prompt template that includes the issue
  identifier, title, and body.
- Use `hooks.after_create` to bootstrap a fresh workspace. For a Git-backed repo, you can run
  `git clone ... .` there, along with any other setup commands you need.
- If a hook needs `mise exec` inside a freshly cloned workspace, trust the repo config and fetch
  the project dependencies in `hooks.after_create` before invoking `mise` later from other hooks.
- `tracker.api_key` reads from `LINEAR_API_KEY` when unset or when value is `$LINEAR_API_KEY`.
- For path values, `~` is expanded to the home directory.
- For env-backed path values, use `$VAR`. `workspace.root` resolves `$VAR` before path handling,
  while `codex.command` stays a shell command string and any `$VAR` expansion there happens in the
  launched shell.

```yaml
tracker:
  api_key: $LINEAR_API_KEY
workspace:
  root: $SYMPHONY_WORKSPACE_ROOT
loop:
  database_path: $SYMPHONY_LOOP_DB_PATH
hooks:
  after_create: |
    git clone --depth 1 "$SOURCE_REPO_URL" .
codex:
  command: "$CODEX_BIN --config 'model=\"gpt-5.5\"' app-server"
```

- If `WORKFLOW.md` is missing or has invalid YAML at startup, Symphony does not boot.
- If a later reload fails, Symphony keeps running with the last known good workflow and logs the
  reload error until the file is fixed.
- `server.port` or CLI `--port` enables the optional Phoenix LiveView dashboard and JSON API at
  `/`, `/api/v1/state`, `/api/v1/<issue_identifier>`, `/api/v1/refresh`,
  `/api/v1/operator-input`, `/api/v1/review-decision`, `/api/v1/audit`,
  `/api/v1/audit/verify`, `/api/v1/jobs`, and `/api/v1/waits`. Stopping a durable job requires the
  same local operator header as other mutations.
- `/api/v1/operator-input` accepts optional `title` and Linear `priority` fields. With intake
  enabled, every accepted `instruction`, `goal_adjustment`, `preempt`, or `unblock` creates a new
  `[Human]` issue and returns its identifier. Ordinary requests remain in the priority queue and do
  not interrupt active work. Only explicit `preempt` returns the source issue to Todo and sends
  Codex `turn/interrupt`; if priority is omitted the request defaults to Urgent. A 30-second grace
  timeout falls back to restarting only the worker. `unblock` also returns the named source issue
  to the requested active state.

## Web dashboard

The observability UI now runs on a minimal Phoenix stack:

- LiveView for the dashboard at `/`
- JSON API for operational debugging under `/api/v1/*`
- Bandit as the HTTP server
- Phoenix dependency static assets for the LiveView client bootstrap
- Tracker issue identifiers link to the tracker-provided URL when it uses `http` or `https`

## Project Layout

- `lib/`: application code and Mix tasks
- `test/`: ExUnit coverage for runtime behavior
- `WORKFLOW.md`: in-repo workflow contract used by local runs
- `../.codex/`: repository-local Codex skills and setup helpers

## Testing

```bash
make all
```

Run the real external end-to-end test only when you want Symphony to create disposable Linear
resources and launch a real `codex app-server` session:

```bash
cd elixir
export LINEAR_API_KEY=...
make e2e
```

Optional environment variables:

- `SYMPHONY_LIVE_LINEAR_TEAM_KEY` defaults to `SYME2E`
- `SYMPHONY_LIVE_SSH_WORKER_HOSTS` uses those SSH hosts when set, as a comma-separated list

`make e2e` runs two live scenarios:
- one with a local worker
- one with SSH workers

If `SYMPHONY_LIVE_SSH_WORKER_HOSTS` is unset, the SSH scenario uses `docker compose` to start two
disposable SSH workers on `localhost:<port>`. The live test generates a temporary SSH keypair,
mounts the host `~/.codex/auth.json` into each worker, verifies that Symphony can talk to them
over real SSH, then runs the same orchestration flow against those worker addresses. This keeps
the transport representative without depending on long-lived external machines.

Set `SYMPHONY_LIVE_SSH_WORKER_HOSTS` if you want `make e2e` to target real SSH hosts instead.

The live test creates a temporary Linear project and issue, writes a temporary `WORKFLOW.md`, runs
a real agent turn, verifies the workspace side effect, requires Codex to comment on and close the
Linear issue, then marks the project completed so the run remains visible in Linear.

## FAQ

### Why Elixir?

Elixir is built on Erlang/BEAM/OTP, which is great for supervising long-running processes. It has an
active ecosystem of tools and libraries. It also supports hot code reloading without stopping
actively running subagents, which is very useful during development.

### What's the easiest way to set this up for my own codebase?

Launch `codex` in your repo, give it the URL to the Symphony repo, and ask it to set things up for
you.

## License

This project is licensed under the [Apache License 2.0](../LICENSE).
