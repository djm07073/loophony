# Symphony Quant profile

This profile runs the official Symphony Elixir orchestrator as the 24/7 control plane for one
quant-research worker. The former TypeScript goal loop is not part of this execution path.

## Runtime contract

- Linear Project: immutable big objective and the human-visible system of record.
- `[Goal]` issue: measurable success criteria. Do not give it the `symphony-quant` label.
- Child issue: one isolated Codex session and one bounded research/coding objective.
- Internal pending dispatch window: maximum one. Linear may hold multiple Todo issues; running
  work is separate and at most one executable issue may be In Progress.
- Concurrency: one.
- Model routing: one `gpt-5.6-sol` medium parent owns planning, research decisions, review, and
  acceptance. Only a bounded source/test implementation is delegated to one
  `gpt-5.3-codex-spark` medium subagent in the same issue workspace; non-coding issues do not spawn
  it.
- Wake-up: a 30-second idle heartbeat/watchdog. Terminal completion triggers an immediate poll, so
  the next issue starts after the prior issue exits rather than waiting for the timer.
- Terminal decisions: `Done` and `Rejected` are automatic when evidence passes the workflow rules.
  Only `Blocked` waits for a human.
- Human feedback: each accepted Linear/Codex operator input creates a visible `[Human]` Todo issue.
  Loophony selects these tickets by Linear priority and age, creates a linked `[Work]` issue, and
  runs only the Work issue. Ordinary feedback never disturbs current work. Explicit `preempt` stops
  the current Codex turn and preserves its workspace before scheduling resumes. Routine scheduled
  review does not pause work. Genuine `Blocked` conditions and the SC-06 live-trading decision
  remain gated.
- Linear record language: Korean for issue titles, descriptions, workpads, progress, validation,
  outcomes, and handoffs. Exact technical identifiers, paths, commands, and machine markers may
  remain in their original language.
- Loop memory: structured `observe → orient → act → verify → learn/handoff` checkpoints are stored
  in local SQLite and indexed by Onyx v4/OpenSearch 3.6 for cross-session natural-language search.
  One loop is exactly one Linear child issue, identified by its immutable `issue_id`.

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
   security add-generic-password -U -s symphony-quant -a linear-notifier-api-token -w
   security add-generic-password -U -s symphony-quant -a alpaca-api-key-id -w
   security add-generic-password -U -s symphony-quant -a alpaca-api-secret-key -w
   ```

   The first item may contain a Linear personal API key or a currently valid OAuth access token.
   When present, `linear-notifier-api-token` is preferred as the separate Linear agent identity for
   all issue reads, updates, and comments; reviewer mentions still target the configured human.
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
adjustments, preemption requests, or unblock decisions as prioritized `[Human]` Linear issues.
Loophony claims the highest-priority oldest Human issue, creates or recovers its linked `[Work]`
issue, and lets the normal scheduler execute that Work issue. Explicit `preempt` additionally uses
Codex `turn/interrupt` and preserves the workspace; a 30-second timeout falls back to restarting
only the worker. `unblock` additionally returns the target issue to `Ready`.

This autonomous profile disables scheduled review gates. Inspect Linear whenever convenient and use
operator `instruction` or `goal_adjustment` input to create queued Human tickets. Use `preempt` only
for an explicit request to stop or replace active work now; status questions and RAG searches never
change execution. A true `Blocked` state still requires explicit unblock input, and SC-06 still
requires explicit live-trading approval.

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
unavailable. When scheduled review is explicitly enabled, dispatch fails closed because Symphony cannot safely
prove that the human gate was resolved.

The `loophony-query` skill searches Onyx's OpenSearch keyword/vector index, expands the strongest
matching session when needed, and lets Codex write the final answer with exact
issue/session/evidence citations. Onyx's local model servers run multilingual E5 embeddings; the
retrieval path makes no generative-LLM call, and Codex remains the answering agent.
Successful tracker reads also upsert a stable current Linear issue snapshot. At turn completion,
Loophony adds a deterministic session summary built from same-session checkpoints and recent final
agent messages. The query skill uses that summary to navigate but verifies progress claims against
live state and the separately retained raw evidence.

When enabled for another profile, the scheduled review gate is orchestration state, not another
research loop. It does not merge SQLite checkpoints between issues. This autonomous profile instead
accepts human feedback asynchronously without a routine global pause.

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
