defmodule SymphonyElixir.DurableRuntimeTest do
  use SymphonyElixir.TestSupport

  alias Exqlite.Sqlite3
  alias SymphonyElixir.Config.Schema.Automation

  alias SymphonyElixir.{
    AuditLog,
    BudgetPolicy,
    Codex.DynamicTool,
    GoalPolicy,
    JobSupervisor,
    Linear.Issue,
    MemoryEvaluation,
    RuntimeStore,
    WaitCondition
  }

  setup do
    root =
      Path.join(
        System.tmp_dir!(),
        "loophony-durable-runtime-#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf(root) end)
    %{root: root}
  end

  test "audit log redacts secrets and detects offline tampering", %{root: root} do
    path = Path.join(root, "audit.sqlite3")
    name = Module.concat(__MODULE__, AuditStore)
    start_supervised!({AuditLog, name: name, path: path, enabled: true})

    assert {:ok, first} =
             AuditLog.record(
               "job.started",
               %{
                 actor: "agent",
                 resource_type: "job",
                 resource_id: "job-1",
                 metadata: %{
                   api_token: "never-store-this",
                   safe: "visible",
                   total_tokens: 42,
                   observed_at: ~U[2026-07-22 17:00:00Z]
                 }
               },
               name
             )

    assert first.sequence == 1
    assert first.hash_version == 1
    assert first.metadata["api_token"] == "[REDACTED]"
    assert first.metadata["safe"] == "visible"
    assert first.metadata["total_tokens"] == 42
    assert first.metadata["observed_at"] == "2026-07-22T17:00:00Z"

    assert {:ok, _second} =
             AuditLog.record(
               "job.completed",
               %{resource_type: "job", resource_id: "job-1"},
               name
             )

    assert {:ok, %{valid: true, verified_events: 2}} = AuditLog.verify(name)

    {:ok, connection} = Sqlite3.open(path)
    :ok = Sqlite3.execute(connection, "UPDATE audit_events SET action = 'tampered' WHERE sequence = 1")
    :ok = Sqlite3.close(connection)

    assert {:ok, %{valid: false, failed_sequence: 1}} = AuditLog.verify(name)
  end

  test "automated waits, resume context, and budget usage survive turn boundaries", %{root: root} do
    name = Module.concat(__MODULE__, RuntimeStore)
    path = Path.join(root, "runtime.sqlite3")
    start_supervised!({RuntimeStore, name: name, path: path, enabled: true})

    issue = %Issue{id: "issue-1", identifier: "LOOP-1"}

    assert {:ok, wait} =
             RuntimeStore.register_wait(
               issue,
               %{
                 reason: "collector window is still open",
                 after_ms: 50,
                 resume_hint: "read the durable cursor"
               },
               name
             )

    assert {:ok, %{wait_id: wait_id}} = RuntimeStore.active_wait("issue-1", name)
    assert wait_id == wait.wait_id
    assert :waiting = WaitCondition.ready?(wait, now: DateTime.utc_now())

    future = DateTime.utc_now() |> DateTime.add(100, :millisecond)
    assert {:ready, "wake_at_reached"} = WaitCondition.ready?(wait, now: future)
    assert {:ok, %{status: "released"}} = RuntimeStore.release_wait(wait.wait_id, "wake_at_reached", name)
    assert {:error, :wait_not_found} = RuntimeStore.release_wait("missing-wait", "operator", name)
    assert RuntimeStore.prompt_context("issue-1", name) =~ "read the durable cursor"

    assert {:ok, usage} =
             RuntimeStore.add_token_usage(
               issue.id,
               issue.identifier,
               %{input_tokens: 70, output_tokens: 30, total_tokens: 100},
               name
             )

    assert usage.issue.total_tokens == 100

    assert {:ok, %{runtime_recorded: true}} =
             RuntimeStore.finish_run("run-1", issue.id, issue.identifier, 12, name)

    assert {:ok, %{runtime_recorded: false}} =
             RuntimeStore.finish_run("run-1", issue.id, issue.identifier, 12, name)

    assert {:ok, final_usage} = RuntimeStore.budget_usage(issue.id, name)
    assert final_usage.issue.runtime_seconds == 12
  end

  test "durable job supervisor records completion and artifacts", %{root: root} do
    workspace = Path.join(root, "workspace")
    File.mkdir_p!(workspace)
    store = Module.concat(__MODULE__, JobRuntimeStore)
    supervisor = Module.concat(__MODULE__, JobSupervisor)
    start_supervised!({RuntimeStore, name: store, path: Path.join(root, "jobs.sqlite3"), enabled: true})

    start_supervised!({JobSupervisor, name: supervisor, runtime_store: store, poll_interval_ms: 20})

    issue = %Issue{id: "issue-job", identifier: "LOOP-JOB"}

    assert {:ok, job} =
             JobSupervisor.start_job(
               issue,
               %{executable: "/bin/sh", args: ["-c", "printf durable-job; exit 0"]},
               workspace: workspace,
               server: supervisor
             )

    assert_eventually(fn ->
      match?({:ok, %{status: "completed", exit_code: 0}}, RuntimeStore.get_job(job.job_id, store))
    end)

    assert {:ok, completed} = RuntimeStore.get_job(job.job_id, store)
    assert File.read!(completed.log_path) =~ "durable-job"

    owner_status =
      DynamicTool.execute("symphony_job_status", %{"job_id" => job.job_id},
        issue: issue,
        runtime_store: store
      )

    assert owner_status["success"]

    other_issue_status =
      DynamicTool.execute("symphony_job_status", %{"job_id" => job.job_id},
        issue: %Issue{id: "issue-other", identifier: "LOOP-OTHER"},
        runtime_store: store
      )

    refute other_issue_status["success"]
    assert Jason.decode!(other_issue_status["output"])["error"]["message"] =~ "does not belong"

    assert {:ready, "job_completed"} =
             WaitCondition.ready?(%{condition: %{"type" => "job_complete", "job_id" => job.job_id}},
               job_status: fn job_id -> RuntimeStore.get_job(job_id, store) end
             )

    assert {:ok, long_job} =
             JobSupervisor.start_job(
               issue,
               %{executable: "/bin/sleep", args: ["10"]},
               workspace: workspace,
               server: supervisor
             )

    assert {:ok, %{status: "stopping"}} = JobSupervisor.stop_job(long_job.job_id, server: supervisor)

    assert_eventually(fn ->
      result = RuntimeStore.get_job(long_job.job_id, store)

      match?(
        {:ok, %{status: "failed", exit_code: exit_code}} when is_integer(exit_code),
        result
      )
    end)
  end

  test "goal policy rejects stale mappings and identifies stale review decisions" do
    settings = %{SymphonyElixir.Config.settings!().goal_policy | enabled: true}

    issue = %Issue{
      id: "issue-goal",
      identifier: "LOOP-3",
      title: "SC-03 prospective gate",
      description: "Mapped stage: SC-03",
      project_description: "Goal version: 5\nActive stage: SC-03",
      state: "Todo"
    }

    policy = GoalPolicy.evaluate([issue], settings: settings)
    assert policy.valid
    assert policy.goal_version == 5
    assert policy.active_stage == "SC-03"

    markdown_policy =
      GoalPolicy.evaluate(
        [
          %{
            issue
            | description: "* Mapped stage: **SC-03 — Fair-value calibration**",
              project_description: "**Active stage:** SC-03 — Fair-value calibration\n**Goal version:** 5"
          }
        ],
        settings: settings
      )

    assert markdown_policy.valid
    assert markdown_policy.goal_version == 5
    assert markdown_policy.active_stage == "SC-03"
    assert markdown_policy.eligible_issue_ids == ["issue-goal"]

    second_todo = %{issue | id: "issue-goal-2", identifier: "LOOP-4"}
    todo_queue = GoalPolicy.evaluate([issue, second_todo], settings: settings)
    assert todo_queue.valid
    assert todo_queue.todo_count == 2
    assert todo_queue.in_progress_count == 0
    assert Enum.sort(todo_queue.eligible_issue_ids) == ["issue-goal", "issue-goal-2"]

    in_progress = %{second_todo | state: "In Progress"}
    resumed = GoalPolicy.evaluate([issue, in_progress], settings: settings)
    assert resumed.valid
    assert resumed.todo_count == 1
    assert resumed.in_progress_count == 1
    assert resumed.eligible_issue_ids == ["issue-goal-2"]

    second_in_progress = %{issue | state: "In Progress"}
    conflict = GoalPolicy.evaluate([second_in_progress, in_progress], settings: settings)
    refute conflict.valid
    assert conflict.eligible_issue_ids == []
    assert "multiple_in_progress" in conflict.violations

    stale = GoalPolicy.review_staleness(%{feedback: "Goal version 1을 유지한다"}, policy)
    assert stale.stale

    mismatch = GoalPolicy.evaluate([%{issue | description: "Mapped stage: SC-04"}], settings: settings)
    refute mismatch.valid
    assert "LOOP-3:mapped_stage_mismatch" in mismatch.violations
  end

  test "budget policy and multilingual retrieval evaluation expose deterministic gates" do
    budget_settings = %{
      SymphonyElixir.Config.settings!().budget
      | enabled: true,
        max_tokens_per_issue: 100,
        max_tokens_per_day: 1_000,
        max_active_seconds_per_issue: 100,
        warn_at_percent: 70
    }

    warning =
      BudgetPolicy.evaluate(
        %{
          issue: %{total_tokens: 75, runtime_seconds: 10},
          daily: %{total_tokens: 75}
        },
        settings: budget_settings
      )

    assert warning.status == "warning"
    assert warning.action == "warn"

    exhausted =
      BudgetPolicy.evaluate(
        %{
          issue: %{total_tokens: 101, runtime_seconds: 10},
          daily: %{total_tokens: 101}
        },
        settings: budget_settings
      )

    assert exhausted.status == "exhausted"
    assert "issue_tokens" in exhausted.exhausted_reasons

    searcher = fn query, _filters ->
      evidence_id = if query =~ "왜", do: "ev-ko", else: "ev-en"
      {:ok, %{matches: [%{evidence_id: evidence_id}]}}
    end

    evaluation =
      MemoryEvaluation.evaluate(
        [
          %{id: "ko", query: "왜 실패했나?", expected_evidence_ids: ["ev-ko"]},
          %{id: "en", query: "What failed?", expected_evidence_ids: ["ev-en"]}
        ],
        searcher,
        k: 5
      )

    assert evaluation.passed_cases == 2
    assert evaluation.mean_recall_at_k == 1.0

    assert BudgetPolicy.evaluate(%{}).status == "disabled"

    ok =
      BudgetPolicy.evaluate(
        %{issue: %{total_tokens: "unknown", runtime_seconds: 10}, daily: %{total_tokens: 10}},
        settings: budget_settings
      )

    assert ok.status == "ok"
    assert ok.metrics.issue_tokens.used == 0

    failed_evaluation =
      MemoryEvaluation.evaluate(
        [
          %{id: "error", query: "failed", expected_evidence_ids: ["ev-error"]},
          %{id: "malformed", query: "malformed", expected_evidence_ids: []}
        ],
        fn
          "failed", _filters -> {:error, :search_down}
          "malformed", _filters -> {:ok, %{matches: [:invalid]}}
        end
      )

    assert failed_evaluation.failed_cases == 1
    assert failed_evaluation.passed_cases == 1
    assert Enum.find(failed_evaluation.results, &(&1.id == "error")).error =~ "search_down"

    empty_evaluation = MemoryEvaluation.evaluate([], fn _query, _filters -> {:ok, %{matches: []}} end)
    assert empty_evaluation.mean_recall_at_k == 0.0
  end

  test "automation host configuration is normalized and deduplicated" do
    settings =
      %Automation{}
      |> Automation.changeset(%{
        "allowed_http_hosts" => [" LOCALHOST ", "localhost", "127.0.0.1", ""]
      })
      |> Ecto.Changeset.apply_changes()

    assert settings.allowed_http_hosts == ["localhost", "127.0.0.1"]
  end

  defp assert_eventually(fun, attempts \\ 50)

  defp assert_eventually(fun, attempts) when attempts > 0 do
    if fun.() do
      :ok
    else
      Process.sleep(20)
      assert_eventually(fun, attempts - 1)
    end
  end

  defp assert_eventually(_fun, 0), do: flunk("condition not met in time")
end
