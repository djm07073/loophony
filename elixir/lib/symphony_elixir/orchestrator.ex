defmodule SymphonyElixir.Orchestrator do
  @moduledoc """
  Polls Linear and dispatches repository copies to Codex-backed workers.
  """

  use GenServer
  require Logger
  import Bitwise, only: [<<<: 2]

  alias SymphonyElixir.{
    AgentRunner,
    AuditLog,
    BudgetPolicy,
    Config,
    GoalPolicy,
    HumanIntake,
    LoopStore,
    MemoryStore,
    OperatorHandoffRecovery,
    RuntimeStore,
    StatusDashboard,
    Tracker,
    WaitCondition,
    Workspace
  }

  @snapshot_dependency_timeout_ms 250

  alias SymphonyElixir.Linear.Issue

  @continuation_retry_delay_ms 1_000
  @failure_retry_base_ms 10_000
  @preempt_grace_ms 30_000
  @top_level_session_limit 1
  @pending_issue_limit 1
  # Slightly above the dashboard render interval so "checking now…" can render.
  @poll_transition_render_delay_ms 20
  @empty_codex_totals %{
    input_tokens: 0,
    output_tokens: 0,
    total_tokens: 0,
    seconds_running: 0
  }

  defmodule State do
    @moduledoc """
    Runtime state for the orchestrator polling loop.
    """

    defstruct [
      :poll_interval_ms,
      :max_concurrent_agents,
      :next_poll_due_at_ms,
      :poll_check_in_progress,
      :tick_timer_ref,
      :tick_token,
      :runtime_id,
      :runtime_started_at,
      :linear_heartbeat_interval_ms,
      running: %{},
      queued: [],
      completed: MapSet.new(),
      claimed: MapSet.new(),
      blocked: %{},
      retry_attempts: %{},
      linear_health_heartbeats: %{},
      codex_totals: nil,
      codex_rate_limits: nil,
      goal_policy: %{enabled: false, valid: true, violations: []},
      intake: %{enabled: false, candidates: 0, claimed: [], completed: []}
    ]
  end

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @impl true
  def init(_opts) do
    now_ms = System.monotonic_time(:millisecond)
    config = Config.settings!()

    state = %State{
      poll_interval_ms: config.polling.interval_ms,
      max_concurrent_agents: config.agent.max_concurrent_agents,
      next_poll_due_at_ms: now_ms,
      poll_check_in_progress: false,
      tick_timer_ref: nil,
      tick_token: nil,
      runtime_id: runtime_id(),
      runtime_started_at: DateTime.utc_now(),
      linear_heartbeat_interval_ms: config.observability.linear_heartbeat_interval_ms,
      codex_totals: @empty_codex_totals,
      codex_rate_limits: nil
    }

    run_terminal_workspace_cleanup()
    audit("runtime.started", "runtime", state.runtime_id, %{started_at: state.runtime_started_at})
    state = schedule_tick(state, 0)

    {:ok, state}
  end

  @impl true
  def handle_info({:tick, tick_token}, %{tick_token: tick_token} = state)
      when is_reference(tick_token) do
    state = refresh_runtime_config(state)

    state = %{
      state
      | poll_check_in_progress: true,
        next_poll_due_at_ms: nil,
        tick_timer_ref: nil,
        tick_token: nil
    }

    notify_dashboard()
    :ok = schedule_poll_cycle_start()
    {:noreply, state}
  end

  def handle_info({:tick, _tick_token}, state), do: {:noreply, state}

  def handle_info(:tick, state) do
    state = refresh_runtime_config(state)

    state = %{
      state
      | poll_check_in_progress: true,
        next_poll_due_at_ms: nil,
        tick_timer_ref: nil,
        tick_token: nil
    }

    notify_dashboard()
    :ok = schedule_poll_cycle_start()
    {:noreply, state}
  end

  def handle_info(:run_poll_cycle, state) do
    state = refresh_runtime_config(state)
    state = release_ready_waits(state)
    state = maybe_dispatch(state)
    state = enforce_running_budgets(state)
    state = publish_due_linear_health_heartbeats(state)
    state = schedule_tick(state, state.poll_interval_ms)
    state = %{state | poll_check_in_progress: false}

    notify_dashboard()
    {:noreply, state}
  end

  def handle_info(
        {:DOWN, ref, :process, _pid, reason},
        %{running: running} = state
      ) do
    case find_issue_id_for_ref(running, ref) do
      nil ->
        {:noreply, state}

      issue_id ->
        {running_entry, state} = pop_running_entry(state, issue_id)
        state = record_session_completion_totals(state, running_entry)
        session_id = running_entry_session_id(running_entry)

        state = handle_agent_down(reason, state, issue_id, running_entry, session_id)

        Logger.info("Agent task finished for issue_id=#{issue_id} session_id=#{session_id} reason=#{inspect(reason)}")

        notify_dashboard()
        {:noreply, state}
    end
  end

  def handle_info({:worker_runtime_info, issue_id, runtime_info}, %{running: running} = state)
      when is_binary(issue_id) and is_map(runtime_info) do
    case Map.get(running, issue_id) do
      nil ->
        {:noreply, state}

      running_entry ->
        updated_running_entry =
          running_entry
          |> maybe_put_runtime_value(:worker_host, runtime_info[:worker_host])
          |> maybe_put_runtime_value(:workspace_path, runtime_info[:workspace_path])
          |> maybe_put_runtime_value(:model, runtime_info[:model])
          |> maybe_put_runtime_value(:session_role, runtime_info[:session_role])
          |> maybe_put_runtime_value(:source_issue_id, runtime_info[:source_issue_id])

        notify_dashboard()
        {:noreply, %{state | running: Map.put(running, issue_id, updated_running_entry)}}
    end
  end

  def handle_info(
        {:codex_worker_update, issue_id, %{event: _, timestamp: _} = update},
        %{running: running} = state
      ) do
    case Map.get(running, issue_id) do
      nil ->
        {:noreply, state}

      running_entry ->
        {updated_running_entry, token_delta} = integrate_codex_update(running_entry, update)

        state =
          state
          |> apply_codex_token_delta(token_delta)
          |> apply_codex_rate_limits(update)
          |> persist_issue_token_usage(issue_id, updated_running_entry, token_delta)
          |> enforce_issue_budget(issue_id)

        notify_dashboard()

        state =
          if Map.has_key?(state.running, issue_id) do
            %{state | running: Map.put(state.running, issue_id, updated_running_entry)}
          else
            state
          end

        {:noreply, state}
    end
  end

  def handle_info({:codex_worker_update, _issue_id, _update}, state), do: {:noreply, state}

  def handle_info({:worker_blocked, issue_id, reason}, %{running: running} = state)
      when is_binary(issue_id) and is_binary(reason) do
    case Map.get(running, issue_id) do
      nil ->
        {:noreply, state}

      running_entry ->
        completion = %{outcome: :input_required, reason: reason}
        updated_entry = Map.put(running_entry, :completion, completion)
        {:noreply, %{state | running: Map.put(running, issue_id, updated_entry)}}
    end
  end

  def handle_info({:retry_issue, issue_id, retry_token}, state) do
    result =
      case pop_retry_attempt_state(state, issue_id, retry_token) do
        {:ok, attempt, metadata, state} ->
          audit("retry.fired", "linear_issue", issue_id, %{
            outcome: "retry",
            issue_identifier: metadata[:identifier],
            attempt: attempt
          })

          handle_retry_issue(state, issue_id, attempt, metadata)

        :missing ->
          {:noreply, state}
      end

    notify_dashboard()
    result
  end

  def handle_info({:retry_issue, _issue_id}, state), do: {:noreply, state}

  def handle_info({:force_operator_preempt, issue_id, request_id}, state)
      when is_binary(issue_id) and is_binary(request_id) do
    next_state = force_operator_preempt(state, issue_id, request_id)
    notify_dashboard()
    {:noreply, next_state}
  end

  def handle_info(msg, state) do
    Logger.debug("Orchestrator ignored message: #{inspect(msg)}")
    {:noreply, state}
  end

  defp handle_agent_down(
         _reason,
         state,
         issue_id,
         %{preempt_request_id: request_id} = running_entry,
         session_id
       )
       when is_binary(request_id) do
    Logger.info("Operator preemption completed for issue_id=#{issue_id} session_id=#{session_id} request_id=#{request_id}; returning control to the scheduler")

    continue_after_operator_preempt(state, issue_id, running_entry, request_id)
  end

  defp handle_agent_down(:normal, state, issue_id, running_entry, session_id) do
    cond do
      automated_wait_active?(issue_id) ->
        Logger.info("Agent task entered durable automated wait for issue_id=#{issue_id} session_id=#{session_id}")
        audit("agent.waiting", "linear_issue", issue_id, %{session_id: session_id})
        complete_issue(state, issue_id)

      input_required_blocker?(running_entry) ->
        block_input_required_agent_down(state, issue_id, running_entry, session_id, :normal)

      LoopStore.review_gate_open?() ->
        block_review_gate_agent_down(state, issue_id, running_entry, session_id)

      true ->
        Logger.info("Agent task completed for issue_id=#{issue_id} session_id=#{session_id}; scheduling active-state continuation check")

        state
        |> complete_issue(issue_id)
        |> schedule_issue_retry(issue_id, 1, %{
          identifier: running_entry.identifier,
          issue_url: running_entry.issue.url,
          delay_type: :continuation,
          worker_host: Map.get(running_entry, :worker_host),
          workspace_path: Map.get(running_entry, :workspace_path)
        })
    end
  end

  defp handle_agent_down(reason, state, issue_id, running_entry, session_id) do
    cond do
      automated_wait_active?(issue_id) ->
        Logger.info("Agent task exited while durable automated wait is active for issue_id=#{issue_id} session_id=#{session_id}")
        audit("agent.waiting", "linear_issue", issue_id, %{session_id: session_id, exit_reason: inspect(reason)})
        complete_issue(state, issue_id)

      input_required_blocker?(running_entry) ->
        block_input_required_agent_down(state, issue_id, running_entry, session_id, reason)

      true ->
        retry_agent_down(state, issue_id, running_entry, session_id, reason)
    end
  end

  defp block_input_required_agent_down(state, issue_id, running_entry, session_id, reason) do
    error = blocker_error(running_entry, "agent exited: #{inspect(reason)}")

    Logger.warning("Agent task blocked for issue_id=#{issue_id} issue_identifier=#{running_entry.identifier} session_id=#{session_id}: #{error}")

    block_issue_from_entry(state, issue_id, running_entry, error, :runtime)
  end

  defp block_review_gate_agent_down(state, issue_id, running_entry, session_id) do
    error = "scheduled goal review requires human maintain/adjust feedback"

    Logger.warning("Agent paused at goal-review gate for issue_id=#{issue_id} issue_identifier=#{running_entry.identifier} session_id=#{session_id}")

    block_issue_from_entry(state, issue_id, running_entry, error, :review_gate)
  end

  defp retry_agent_down(state, issue_id, running_entry, session_id, reason) do
    Logger.warning("Agent task exited for issue_id=#{issue_id} session_id=#{session_id} reason=#{inspect(reason)}; scheduling retry")

    next_attempt = next_retry_attempt_from_running(running_entry)

    schedule_issue_retry(state, issue_id, next_attempt, %{
      identifier: running_entry.identifier,
      issue_url: running_entry.issue.url,
      error: "agent exited: #{inspect(reason)}",
      worker_host: Map.get(running_entry, :worker_host),
      workspace_path: Map.get(running_entry, :workspace_path)
    })
  end

  defp maybe_dispatch(%State{} = state) do
    state =
      state
      |> reconcile_running_issues()
      |> reconcile_blocked_issues()
      |> reconcile_human_intake()

    with :ok <- Config.validate!(),
         {:ok, issues} <- Tracker.fetch_candidate_issues() do
      issues = Enum.reject(issues, &HumanIntake.human_issue?/1)
      issues = reconcile_operator_handoff_overlap(issues)
      {eligible_issues, state} = apply_goal_policy(issues, state)
      choose_issues_or_pause_for_review(eligible_issues, state)
    else
      {:error, :missing_linear_api_token} ->
        Logger.error("Linear API token missing in WORKFLOW.md")
        state

      {:error, :missing_linear_project_slug} ->
        Logger.error("Linear project slug missing in WORKFLOW.md")
        state

      {:error, :missing_tracker_kind} ->
        Logger.error("Tracker kind missing in WORKFLOW.md")

        state

      {:error, {:unsupported_tracker_kind, kind}} ->
        Logger.error("Unsupported tracker kind in WORKFLOW.md: #{inspect(kind)}")

        state

      {:error, {:invalid_workflow_config, message}} ->
        Logger.error("Invalid WORKFLOW.md config: #{message}")
        state

      {:error, {:missing_workflow_file, path, reason}} ->
        Logger.error("Missing WORKFLOW.md at #{path}: #{inspect(reason)}")
        state

      {:error, :workflow_front_matter_not_a_map} ->
        Logger.error("Failed to parse WORKFLOW.md: workflow front matter must decode to a map")
        state

      {:error, {:workflow_parse_error, reason}} ->
        Logger.error("Failed to parse WORKFLOW.md: #{inspect(reason)}")
        state

      {:error, reason} ->
        Logger.error("Failed to fetch from Linear: #{inspect(reason)}")
        state
    end
  end

  defp reconcile_operator_handoff_overlap(issues) do
    case OperatorHandoffRecovery.reconcile(issues) do
      {:ok, reconciled} ->
        reconciled

      {:error, reason} ->
        Logger.warning("Operator handoff overlap recovery failed: #{inspect(reason)}")
        issues
    end
  end

  defp reconcile_human_intake(%State{} = state) do
    case HumanIntake.reconcile() do
      {:ok, summary} ->
        if summary.claimed != [] or summary.completed != [] do
          Logger.info(
            "Human intake reconciled claimed=#{length(summary.claimed)} " <>
              "completed=#{length(summary.completed)} candidates=#{summary.candidates}"
          )
        end

        %{state | intake: summary}

      {:error, reason} ->
        Logger.warning("Human intake reconciliation failed: #{inspect(reason)}")

        %{
          state
          | intake: %{
              enabled: true,
              candidates: 0,
              claimed: [],
              completed: [],
              error: inspect(reason)
            }
        }
    end
  rescue
    error ->
      Logger.warning("Human intake configuration unavailable: #{Exception.message(error)}")
      state
  end

  defp choose_issues_or_pause_for_review(issues, state) do
    case LoopStore.ensure_review_gate() do
      {:ok, %{status: "open"} = gate} ->
        state = queue_without_dispatch(issues, state)
        maybe_publish_review_report(gate, state)
        state

      {:ok, _gate} ->
        choose_issues(issues, state)

      {:error, reason} ->
        Logger.error("Goal-review gate state unavailable; failing closed: #{inspect(reason)}")
        queue_without_dispatch(issues, state)
    end
  end

  defp apply_goal_policy(issues, %State{} = state) do
    policy = GoalPolicy.evaluate(issues)

    if Map.get(state.goal_policy, :fingerprint) != Map.get(policy, :fingerprint) do
      outcome = if policy.valid, do: "ok", else: "rejected"

      audit("goal_policy.evaluated", "project", Config.settings!().tracker.project_slug || "unknown", %{
        outcome: outcome,
        goal_version: Map.get(policy, :goal_version),
        active_stage: Map.get(policy, :active_stage),
        violations: Map.get(policy, :violations, [])
      })
    end

    eligible = Enum.filter(issues, &GoalPolicy.eligible?(policy, &1))
    {eligible, %{state | goal_policy: policy}}
  end

  defp queue_without_dispatch(issues, state) do
    queued = queued_issues_for_dispatch(issues, state, active_state_set(), terminal_state_set())
    %{state | queued: queued}
  end

  defp maybe_publish_review_report(%{reported_at: reported_at}, _state) when is_binary(reported_at),
    do: :ok

  defp maybe_publish_review_report(gate, state) do
    review = Config.settings!().review

    with {:ok, %{id: issue_id}} <- Tracker.resolve_issue(review.issue_identifier),
         :ok <- Tracker.create_comment(issue_id, review_report(gate, state, review.reviewer)),
         {:ok, _gate} <- LoopStore.mark_review_reported(gate.window_key) do
      Logger.info("Published scheduled goal-review report window=#{gate.window_key}")
      :ok
    else
      {:error, reason} ->
        Logger.error("Unable to publish scheduled goal-review report window=#{gate.window_key}: #{inspect(reason)}")
        :error
    end
  end

  defp review_report(gate, state, reviewer) do
    loop = LoopStore.summary()
    latest = List.first(Map.get(loop, :recent, []))

    """
    ## 정기 목표 검토 — 피드백 필요

    <!-- symphony-goal-review:#{gate.window_key} -->
    #{reviewer}

    Loophony가 #{gate.window_key} 검토 gate에서 일시정지했습니다. 계속하려면 Codex App에서
    `maintain` 또는 `adjust`를 선택하고 구체적인 피드백을 입력하세요.

    - 실행 중: #{format_issue_identifiers(state.running)}
    - 대기 중: #{format_queued_identifiers(state.queued)}
    - 재시도 대기: #{map_size(state.retry_attempts)}
    - Runtime Blocked: #{map_size(state.blocked)}
    - Loop checkpoint: #{Map.get(loop, :total_checkpoints, 0)}
    - 최신 loop 결정: #{format_latest_loop_decision(latest)}
    - Token: #{Map.get(state.codex_totals, :total_tokens, 0)}

    필요한 결정: 현재 root goal과 우선순위를 유지할지, 아니면 근거·범위 변경·다음 검증
    대상을 명시해 조정할지 선택하세요.
    """
    |> String.trim()
  end

  defp format_issue_identifiers(running) do
    running
    |> Map.values()
    |> Enum.map_join(", ", &Map.get(&1, :identifier, "unknown"))
    |> empty_as_none()
  end

  defp format_queued_identifiers(queued) do
    queued |> Enum.map_join(", ", &(&1.identifier || &1.id)) |> empty_as_none()
  end

  defp format_latest_loop_decision(nil), do: "none"

  defp format_latest_loop_decision(checkpoint) do
    "#{Map.get(checkpoint, :issue_identifier)} / #{Map.get(checkpoint, :outcome)} / #{Map.get(checkpoint, :decision)}"
  end

  defp empty_as_none(""), do: "none"
  defp empty_as_none(value), do: value

  defp reconcile_running_issues(%State{} = state) do
    state = reconcile_stalled_running_issues(state)
    running_ids = Map.keys(state.running)

    if running_ids == [] do
      state
    else
      case Tracker.fetch_issue_states_by_ids(running_ids) do
        {:ok, issues} ->
          issues
          |> reconcile_running_issue_states(
            state,
            active_state_set(),
            terminal_state_set()
          )
          |> reconcile_missing_running_issue_ids(running_ids, issues)

        {:error, reason} ->
          Logger.debug("Failed to refresh running issue states: #{inspect(reason)}; keeping active workers")

          state
      end
    end
  end

  defp reconcile_blocked_issues(%State{} = state) do
    blocked_ids = Map.keys(state.blocked)

    if blocked_ids == [] do
      state
    else
      case Tracker.fetch_issue_states_by_ids(blocked_ids) do
        {:ok, issues} ->
          issues
          |> reconcile_blocked_issue_states(
            state,
            active_state_set(),
            terminal_state_set()
          )
          |> reconcile_missing_blocked_issue_ids(blocked_ids, issues)

        {:error, reason} ->
          Logger.debug("Failed to refresh blocked issue states: #{inspect(reason)}; keeping blocked issues")

          state
      end
    end
  end

  @doc false
  @spec reconcile_issue_states_for_test([Issue.t()], term()) :: term()
  def reconcile_issue_states_for_test(issues, %State{} = state) when is_list(issues) do
    reconcile_running_issue_states(issues, state, active_state_set(), terminal_state_set())
  end

  def reconcile_issue_states_for_test(issues, state) when is_list(issues) do
    reconcile_running_issue_states(issues, state, active_state_set(), terminal_state_set())
  end

  @doc false
  @spec reconcile_blocked_issue_states_for_test([Issue.t()], term()) :: term()
  def reconcile_blocked_issue_states_for_test(issues, %State{} = state) when is_list(issues) do
    reconcile_blocked_issue_states(issues, state, active_state_set(), terminal_state_set())
  end

  @doc false
  @spec handle_retry_issue_lookup_for_test(Issue.t(), term(), String.t(), non_neg_integer(), map()) ::
          term()
  def handle_retry_issue_lookup_for_test(%Issue{} = issue, %State{} = state, issue_id, attempt, metadata)
      when is_binary(issue_id) and is_integer(attempt) and attempt >= 0 and is_map(metadata) do
    {:noreply, updated_state} = handle_retry_issue_lookup(issue, state, issue_id, attempt, metadata)
    updated_state
  end

  @doc false
  @spec should_dispatch_issue_for_test(Issue.t(), term()) :: boolean()
  def should_dispatch_issue_for_test(%Issue{} = issue, %State{} = state) do
    should_dispatch_issue?(issue, state, active_state_set(), terminal_state_set())
  end

  @doc false
  @spec revalidate_issue_for_dispatch_for_test(Issue.t(), ([String.t()] -> term())) ::
          {:ok, Issue.t()} | {:skip, Issue.t() | :missing} | {:error, term()}
  def revalidate_issue_for_dispatch_for_test(%Issue{} = issue, issue_fetcher)
      when is_function(issue_fetcher, 1) do
    revalidate_issue_for_dispatch(issue, issue_fetcher, terminal_state_set())
  end

  @doc false
  @spec sort_issues_for_dispatch_for_test([Issue.t()]) :: [Issue.t()]
  def sort_issues_for_dispatch_for_test(issues) when is_list(issues) do
    sort_issues_for_dispatch(issues)
  end

  @doc false
  @spec queued_issues_for_dispatch_for_test([Issue.t()], term()) :: [Issue.t()]
  def queued_issues_for_dispatch_for_test(issues, %State{} = state) when is_list(issues) do
    queued_issues_for_dispatch(issues, state, active_state_set(), terminal_state_set())
  end

  @doc false
  @spec select_worker_host_for_test(term(), String.t() | nil) :: String.t() | nil | :no_worker_capacity
  def select_worker_host_for_test(%State{} = state, preferred_worker_host) do
    select_worker_host(state, preferred_worker_host)
  end

  @doc false
  @spec apply_budget_evaluation_for_test(term(), String.t(), map(), map()) :: term()
  def apply_budget_evaluation_for_test(
        %State{} = state,
        issue_id,
        running_entry,
        evaluation
      )
      when is_binary(issue_id) and is_map(running_entry) and is_map(evaluation) do
    apply_budget_evaluation(state, issue_id, running_entry, evaluation)
  end

  defp reconcile_running_issue_states([], state, _active_states, _terminal_states), do: state

  defp reconcile_running_issue_states([issue | rest], state, active_states, terminal_states) do
    reconcile_running_issue_states(
      rest,
      reconcile_issue_state(issue, state, active_states, terminal_states),
      active_states,
      terminal_states
    )
  end

  defp reconcile_issue_state(%Issue{} = issue, state, active_states, terminal_states) do
    cond do
      terminal_issue_state?(issue.state, terminal_states) ->
        Logger.info("Issue moved to terminal state: #{issue_context(issue)} state=#{issue.state}; stopping active agent")

        terminate_running_issue(state, issue.id, true)

      !issue_routable?(issue) ->
        Logger.info("Issue no longer routed to this worker: #{issue_context(issue)} assignee=#{inspect(issue.assignee_id)}; stopping active agent")

        terminate_running_issue(state, issue.id, false)

      active_issue_state?(issue.state, active_states) ->
        refresh_running_issue_state(state, issue)

      true ->
        Logger.info("Issue moved to non-active state: #{issue_context(issue)} state=#{issue.state}; stopping active agent")

        terminate_running_issue(state, issue.id, false)
    end
  end

  defp reconcile_issue_state(_issue, state, _active_states, _terminal_states), do: state

  defp reconcile_blocked_issue_states([], state, _active_states, _terminal_states), do: state

  defp reconcile_blocked_issue_states([issue | rest], state, active_states, terminal_states) do
    reconcile_blocked_issue_states(
      rest,
      reconcile_blocked_issue_state(issue, state, active_states, terminal_states),
      active_states,
      terminal_states
    )
  end

  defp reconcile_blocked_issue_state(%Issue{} = issue, state, active_states, terminal_states) do
    cond do
      terminal_issue_state?(issue.state, terminal_states) ->
        Logger.info("Blocked issue moved to terminal state: #{issue_context(issue)} state=#{issue.state}; releasing block")
        cleanup_issue_workspace(issue.identifier, blocked_issue_worker_host(state, issue.id))
        release_issue_claim(state, issue.id)

      !issue_routable?(issue) ->
        Logger.info("Blocked issue no longer routed to this worker: #{issue_context(issue)} assignee=#{inspect(issue.assignee_id)}; releasing block")
        release_issue_claim(state, issue.id)

      active_issue_state?(issue.state, active_states) ->
        refresh_blocked_issue_state(state, issue)

      true ->
        Logger.info("Blocked issue moved to non-active state: #{issue_context(issue)} state=#{issue.state}; releasing block")
        release_issue_claim(state, issue.id)
    end
  end

  defp reconcile_blocked_issue_state(_issue, state, _active_states, _terminal_states), do: state

  defp reconcile_missing_running_issue_ids(%State{} = state, requested_issue_ids, issues)
       when is_list(requested_issue_ids) and is_list(issues) do
    visible_issue_ids =
      issues
      |> Enum.flat_map(fn
        %Issue{id: issue_id} when is_binary(issue_id) -> [issue_id]
        _ -> []
      end)
      |> MapSet.new()

    Enum.reduce(requested_issue_ids, state, fn issue_id, state_acc ->
      if MapSet.member?(visible_issue_ids, issue_id) do
        state_acc
      else
        log_missing_running_issue(state_acc, issue_id)
        terminate_running_issue(state_acc, issue_id, false)
      end
    end)
  end

  defp reconcile_missing_running_issue_ids(state, _requested_issue_ids, _issues), do: state

  defp reconcile_missing_blocked_issue_ids(%State{} = state, requested_issue_ids, issues)
       when is_list(requested_issue_ids) and is_list(issues) do
    visible_issue_ids =
      issues
      |> Enum.flat_map(fn
        %Issue{id: issue_id} when is_binary(issue_id) -> [issue_id]
        _ -> []
      end)
      |> MapSet.new()

    Enum.reduce(requested_issue_ids, state, fn issue_id, state_acc ->
      if MapSet.member?(visible_issue_ids, issue_id) do
        state_acc
      else
        Logger.info("Blocked issue no longer visible during state refresh: issue_id=#{issue_id}; releasing block")
        release_issue_claim(state_acc, issue_id)
      end
    end)
  end

  defp reconcile_missing_blocked_issue_ids(state, _requested_issue_ids, _issues), do: state

  defp log_missing_running_issue(%State{} = state, issue_id) when is_binary(issue_id) do
    case Map.get(state.running, issue_id) do
      %{identifier: identifier} ->
        Logger.info("Issue no longer visible during running-state refresh: issue_id=#{issue_id} issue_identifier=#{identifier}; stopping active agent")

      _ ->
        Logger.info("Issue no longer visible during running-state refresh: issue_id=#{issue_id}; stopping active agent")
    end
  end

  defp log_missing_running_issue(_state, _issue_id), do: :ok

  defp refresh_running_issue_state(%State{} = state, %Issue{} = issue) do
    case Map.get(state.running, issue.id) do
      %{issue: _} = running_entry ->
        %{state | running: Map.put(state.running, issue.id, %{running_entry | issue: issue})}

      _ ->
        state
    end
  end

  defp refresh_blocked_issue_state(%State{} = state, %Issue{} = issue) do
    case Map.get(state.blocked, issue.id) do
      %{issue: _} = blocked_entry ->
        %{state | blocked: Map.put(state.blocked, issue.id, %{blocked_entry | issue: issue})}

      _ ->
        state
    end
  end

  defp terminate_running_issue(%State{} = state, issue_id, cleanup_workspace) do
    case Map.get(state.running, issue_id) do
      nil ->
        release_issue_claim(state, issue_id)

      %{pid: pid, ref: ref, identifier: identifier} = running_entry ->
        cancel_preempt_timer(running_entry)
        state = record_session_completion_totals(state, running_entry)
        worker_host = Map.get(running_entry, :worker_host)

        if cleanup_workspace do
          cleanup_issue_workspace(identifier, worker_host)
        end

        stop_running_task(pid, ref)

        %{
          state
          | running: Map.delete(state.running, issue_id),
            claimed: MapSet.delete(state.claimed, issue_id),
            blocked: Map.delete(state.blocked, issue_id),
            retry_attempts: Map.delete(state.retry_attempts, issue_id),
            linear_health_heartbeats: Map.delete(state.linear_health_heartbeats, issue_id)
        }

      _ ->
        release_issue_claim(state, issue_id)
    end
  end

  defp reconcile_stalled_running_issues(%State{} = state) do
    timeout_ms = Config.settings!().codex.stall_timeout_ms

    cond do
      timeout_ms <= 0 ->
        state

      map_size(state.running) == 0 ->
        state

      true ->
        now = DateTime.utc_now()

        Enum.reduce(state.running, state, fn {issue_id, running_entry}, state_acc ->
          maybe_restart_stalled_issue(state_acc, issue_id, running_entry, now, timeout_ms)
        end)
    end
  end

  defp maybe_restart_stalled_issue(state, issue_id, running_entry, now, timeout_ms) do
    if Map.has_key?(state.blocked, issue_id) do
      state
    else
      restart_stalled_issue(state, issue_id, running_entry, now, timeout_ms)
    end
  end

  defp restart_stalled_issue(state, issue_id, running_entry, now, timeout_ms) do
    elapsed_ms = stall_elapsed_ms(running_entry, now)

    if is_integer(elapsed_ms) and elapsed_ms > timeout_ms do
      identifier = Map.get(running_entry, :identifier, issue_id)
      session_id = running_entry_session_id(running_entry)

      if input_required_blocker?(running_entry) do
        error = blocker_error(running_entry, "stalled for #{elapsed_ms}ms after Codex requested operator input")

        Logger.warning("Issue blocked: issue_id=#{issue_id} issue_identifier=#{identifier} session_id=#{session_id} elapsed_ms=#{elapsed_ms}; #{error}")

        state
        |> record_session_completion_totals(running_entry)
        |> stop_and_block_issue(issue_id, running_entry, error)
      else
        Logger.warning("Issue stalled: issue_id=#{issue_id} issue_identifier=#{identifier} session_id=#{session_id} elapsed_ms=#{elapsed_ms}; restarting with backoff")
        publish_stale_health_event(running_entry, now, elapsed_ms, timeout_ms)

        next_attempt = next_retry_attempt_from_running(running_entry)

        state
        |> terminate_running_issue(issue_id, false)
        |> schedule_issue_retry(issue_id, next_attempt, %{
          identifier: identifier,
          issue_url: running_entry.issue.url,
          error: "stalled for #{elapsed_ms}ms without codex activity"
        })
      end
    else
      state
    end
  end

  defp stall_elapsed_ms(running_entry, now) do
    running_entry
    |> last_activity_timestamp()
    |> case do
      %DateTime{} = timestamp ->
        max(0, DateTime.diff(now, timestamp, :millisecond))

      _ ->
        nil
    end
  end

  defp last_activity_timestamp(running_entry) when is_map(running_entry) do
    Map.get(running_entry, :last_codex_timestamp) || Map.get(running_entry, :started_at)
  end

  defp last_activity_timestamp(_running_entry), do: nil

  defp publish_due_linear_health_heartbeats(%State{linear_heartbeat_interval_ms: interval_ms} = state)
       when is_integer(interval_ms) and interval_ms > 0 do
    now_ms = System.monotonic_time(:millisecond)
    observed_at = DateTime.utc_now()

    Enum.reduce(state.running, state, fn {issue_id, running_entry}, state_acc ->
      last_published_at_ms = Map.get(state_acc.linear_health_heartbeats, issue_id)

      if heartbeat_due?(last_published_at_ms, now_ms, interval_ms) do
        publish_linear_health_heartbeat(
          state_acc,
          issue_id,
          running_entry,
          observed_at,
          now_ms,
          interval_ms
        )
      else
        state_acc
      end
    end)
  end

  defp publish_due_linear_health_heartbeats(%State{} = state), do: state

  defp heartbeat_due?(nil, _now_ms, _interval_ms), do: true

  defp heartbeat_due?(last_published_at_ms, now_ms, interval_ms)
       when is_integer(last_published_at_ms),
       do: now_ms - last_published_at_ms >= interval_ms

  defp publish_linear_health_heartbeat(
         state,
         issue_id,
         running_entry,
         observed_at,
         now_ms,
         interval_ms
       ) do
    body = health_heartbeat_comment(state, running_entry, observed_at, interval_ms)

    case Tracker.create_comment(issue_id, body) do
      :ok ->
        Logger.info("Published Linear health heartbeat for #{issue_context(running_entry.issue)} session_id=#{running_entry_session_id(running_entry)}")

        %{
          state
          | linear_health_heartbeats: Map.put(state.linear_health_heartbeats, issue_id, now_ms)
        }

      {:error, reason} ->
        Logger.warning("Failed to publish Linear health heartbeat for #{issue_context(running_entry.issue)} session_id=#{running_entry_session_id(running_entry)} reason=#{inspect(reason)}")
        state
    end
  end

  defp health_heartbeat_comment(state, running_entry, observed_at, interval_ms) do
    last_event_at = last_activity_timestamp(running_entry)
    silence_seconds = activity_age_seconds(last_event_at, observed_at)
    next_heartbeat_at = DateTime.add(observed_at, interval_ms, :millisecond)
    stall_timeout_ms = Config.settings!().codex.stall_timeout_ms
    worker_alive = worker_alive?(Map.get(running_entry, :pid))
    health = if worker_alive, do: "healthy", else: "degraded"

    """
    ## Loophony Health — #{utc_time(observed_at)} UTC / #{kst_time(observed_at)} KST

    - 상태: `#{health}`
    - 확인 시각 (UTC): `#{utc_time(observed_at)}`
    - 확인 시각 (KST): `#{kst_time(observed_at)}`
    - daemon boot ID: `#{state.runtime_id}`
    - daemon 시작 (UTC): `#{utc_time(state.runtime_started_at)}`
    - worker process: `#{if(worker_alive, do: "alive", else: "not_alive")}`
    - session: `#{running_entry_session_id(running_entry)}`
    - 마지막 Codex event: `#{Map.get(running_entry, :last_codex_event) || "initializing"}`
    - 마지막 event (UTC): `#{optional_utc_time(last_event_at)}`
    - 마지막 event (KST): `#{optional_kst_time(last_event_at)}`
    - 무응답 경과: `#{silence_seconds}`초
    - silent-stall 자동 재시작 기준: `#{div(stall_timeout_ms, 1_000)}`초
    - 다음 Linear health 예정 (UTC): `#{utc_time(next_heartbeat_at)}`
    - 다음 Linear health 예정 (KST): `#{kst_time(next_heartbeat_at)}`
    """
    |> String.trim()
  end

  defp publish_stale_health_event(running_entry, observed_at, elapsed_ms, timeout_ms) do
    body =
      """
      ## Loophony Health Event — silent stall 감지

      - 감지 시각 (UTC): `#{utc_time(observed_at)}`
      - 감지 시각 (KST): `#{kst_time(observed_at)}`
      - 상태: `stale_detected_restart_scheduled`
      - session: `#{running_entry_session_id(running_entry)}`
      - 마지막 event (UTC): `#{optional_utc_time(last_activity_timestamp(running_entry))}`
      - 마지막 event (KST): `#{optional_kst_time(last_activity_timestamp(running_entry))}`
      - 무응답 경과: `#{div(elapsed_ms, 1_000)}`초
      - 자동 재시작 기준: `#{div(timeout_ms, 1_000)}`초
      - 조치: workspace를 보존하고 worker를 중단한 뒤 backoff 후 새 실행을 시작합니다.
      """
      |> String.trim()

    case Tracker.create_comment(running_entry.issue.id, body) do
      :ok -> :ok
      {:error, reason} -> Logger.warning("Failed to publish stale-worker Linear health event for #{issue_context(running_entry.issue)} reason=#{inspect(reason)}")
    end
  end

  defp worker_alive?(pid) when is_pid(pid), do: Process.alive?(pid)
  defp worker_alive?(_pid), do: false

  defp activity_age_seconds(%DateTime{} = timestamp, %DateTime{} = now),
    do: max(0, DateTime.diff(now, timestamp, :second))

  defp activity_age_seconds(_timestamp, _now), do: 0

  defp utc_time(%DateTime{} = datetime),
    do: datetime |> DateTime.truncate(:second) |> DateTime.to_iso8601()

  defp kst_time(%DateTime{} = datetime) do
    datetime
    |> DateTime.add(9, :hour)
    |> Calendar.strftime("%Y-%m-%dT%H:%M:%S+09:00")
  end

  defp optional_utc_time(%DateTime{} = datetime), do: utc_time(datetime)
  defp optional_utc_time(_datetime), do: "아직 없음"

  defp optional_kst_time(%DateTime{} = datetime), do: kst_time(datetime)
  defp optional_kst_time(_datetime), do: "아직 없음"

  defp input_required_blocker?(running_entry) when is_map(running_entry) do
    Map.get(running_entry, :last_codex_event) in [:turn_input_required, :approval_required] or
      not is_nil(input_required_completion_outcome(Map.get(running_entry, :completion))) or
      codex_message_method(Map.get(running_entry, :last_codex_message)) ==
        "mcpServer/elicitation/request"
  end

  defp input_required_blocker?(_running_entry), do: false

  defp input_required_completion_outcome(completion) when is_map(completion) do
    outcome = Map.get(completion, :outcome) || Map.get(completion, "outcome")
    normalize_input_required_outcome(outcome)
  end

  defp input_required_completion_outcome(_completion), do: nil

  defp normalize_input_required_outcome(outcome)
       when outcome in [:input_required, :needs_input, :approval_required],
       do: outcome

  defp normalize_input_required_outcome(outcome) when is_binary(outcome) do
    case outcome do
      "input_required" -> :input_required
      "needs_input" -> :needs_input
      "approval_required" -> :approval_required
      _ -> nil
    end
  end

  defp normalize_input_required_outcome(_outcome), do: nil

  defp blocker_error(running_entry, fallback) when is_map(running_entry) do
    codex_event_blocker_error(Map.get(running_entry, :last_codex_event)) ||
      completion_blocker_error(Map.get(running_entry, :completion)) ||
      codex_message_blocker_error(Map.get(running_entry, :last_codex_message)) ||
      fallback
  end

  defp blocker_error(_running_entry, fallback), do: fallback

  defp codex_event_blocker_error(:turn_input_required), do: "codex turn requires operator input"
  defp codex_event_blocker_error(:approval_required), do: "codex turn requires approval"
  defp codex_event_blocker_error(_event), do: nil

  defp completion_blocker_error(completion) do
    case input_required_completion_outcome(completion) do
      outcome when outcome in [:input_required, :needs_input] -> "codex turn requires operator input"
      :approval_required -> "codex turn requires approval"
      nil -> nil
    end
  end

  defp codex_message_blocker_error(message) do
    if codex_message_method(message) == "mcpServer/elicitation/request" do
      "codex MCP elicitation requires operator input"
    end
  end

  defp codex_message_method(%{message: %{"method" => method}}) when is_binary(method), do: method
  defp codex_message_method(%{message: %{method: method}}) when is_binary(method), do: method
  defp codex_message_method(%{"method" => method}) when is_binary(method), do: method
  defp codex_message_method(%{method: method}) when is_binary(method), do: method
  defp codex_message_method(_message), do: nil

  defp terminate_task(pid) when is_pid(pid) do
    case Task.Supervisor.terminate_child(SymphonyElixir.TaskSupervisor, pid) do
      :ok ->
        :ok

      {:error, :not_found} ->
        Process.exit(pid, :shutdown)
    end
  end

  defp terminate_task(_pid), do: :ok

  defp stop_running_task(pid, ref) do
    if is_pid(pid) do
      terminate_task(pid)
    end

    if is_reference(ref) do
      Process.demonitor(ref, [:flush])
    end

    :ok
  end

  defp request_operator_preempt(%State{} = state, issue_id, request_id) do
    case Map.get(state.running, issue_id) do
      %{preempt_request_id: existing_request_id} = running_entry
      when is_binary(existing_request_id) ->
        payload = %{
          requested: true,
          coalesced: true,
          status: "interrupt_requested",
          delivery: "turn_interrupt",
          issue_id: issue_id,
          request_id: existing_request_id,
          requested_at: Map.get(running_entry, :preempt_requested_at),
          grace_timeout_ms: @preempt_grace_ms
        }

        {payload, state}

      %{pid: pid} = running_entry when is_pid(pid) ->
        send(pid, {:operator_preempt, request_id})

        requested_at = DateTime.utc_now()

        timer_ref =
          Process.send_after(
            self(),
            {:force_operator_preempt, issue_id, request_id},
            @preempt_grace_ms
          )

        updated_entry =
          running_entry
          |> Map.put(:preempt_request_id, request_id)
          |> Map.put(:preempt_requested_at, requested_at)
          |> Map.put(:preempt_timer_ref, timer_ref)

        payload = %{
          requested: true,
          coalesced: false,
          status: "interrupt_requested",
          delivery: "turn_interrupt",
          issue_id: issue_id,
          request_id: request_id,
          requested_at: requested_at,
          grace_timeout_ms: @preempt_grace_ms
        }

        {payload, %{state | running: Map.put(state.running, issue_id, updated_entry)}}

      _other ->
        request_non_running_preempt(state, issue_id, request_id)
    end
  end

  defp request_non_running_preempt(%State{} = state, issue_id, request_id) do
    cond do
      Map.has_key?(state.blocked, issue_id) ->
        {%{
           requested: false,
           coalesced: false,
           status: "blocked_requires_unblock",
           delivery: "blocked",
           issue_id: issue_id,
           request_id: request_id
         }, state}

      retry = Map.get(state.retry_attempts, issue_id) ->
        timer_ref = Map.get(retry, :timer_ref)
        if is_reference(timer_ref), do: Process.cancel_timer(timer_ref)
        send(self(), {:retry_issue, issue_id, Map.fetch!(retry, :retry_token)})

        {%{
           requested: true,
           coalesced: false,
           status: "retry_woken",
           delivery: "next_dispatch",
           issue_id: issue_id,
           request_id: request_id
         }, state}

      Enum.any?(state.queued, &(&1.id == issue_id)) ->
        {%{
           requested: true,
           coalesced: false,
           status: "queued_for_dispatch",
           delivery: "next_dispatch",
           issue_id: issue_id,
           request_id: request_id
         }, schedule_tick(state, 0)}

      true ->
        {%{
           requested: true,
           coalesced: false,
           status: "refresh_requested",
           delivery: "next_dispatch",
           issue_id: issue_id,
           request_id: request_id
         }, schedule_tick(state, 0)}
    end
  end

  defp force_operator_preempt(%State{} = state, issue_id, request_id) do
    case Map.get(state.running, issue_id) do
      %{preempt_request_id: ^request_id} = running_entry ->
        Logger.warning("Codex turn did not acknowledge operator preemption within #{@preempt_grace_ms}ms; forcing worker restart issue_id=#{issue_id} request_id=#{request_id}")

        stop_running_task(Map.get(running_entry, :pid), Map.get(running_entry, :ref))

        state
        |> record_session_completion_totals(running_entry)
        |> then(&%{&1 | running: Map.delete(&1.running, issue_id)})
        |> continue_after_operator_preempt(issue_id, running_entry, request_id)

      _other ->
        state
    end
  end

  defp schedule_preempted_issue_retry(state, issue_id, running_entry, request_id) do
    issue_url = running_entry |> Map.get(:issue, %{}) |> Map.get(:url)

    schedule_issue_retry(state, issue_id, 1, %{
      identifier: Map.get(running_entry, :identifier, issue_id),
      issue_url: issue_url,
      error: "operator preempted the active run request_id=#{request_id}",
      delay_type: :continuation,
      worker_host: Map.get(running_entry, :worker_host),
      workspace_path: Map.get(running_entry, :workspace_path)
    })
  end

  defp continue_after_operator_preempt(state, issue_id, running_entry, request_id) do
    state = complete_issue(state, issue_id)

    if human_intake_enabled?() do
      audit("operator.preempt_requeued", "linear_issue", issue_id, %{
        outcome: "scheduler_queue",
        issue_identifier: Map.get(running_entry, :identifier, issue_id),
        request_id: request_id
      })

      state
      |> release_issue_claim(issue_id)
      |> schedule_tick(0)
    else
      schedule_preempted_issue_retry(state, issue_id, running_entry, request_id)
    end
  end

  defp human_intake_enabled? do
    Config.settings!().intake.enabled
  rescue
    _error -> false
  end

  defp cancel_preempt_timer(running_entry) when is_map(running_entry) do
    case Map.get(running_entry, :preempt_timer_ref) do
      timer_ref when is_reference(timer_ref) -> Process.cancel_timer(timer_ref)
      _other -> false
    end
  end

  defp cancel_preempt_timer(_running_entry), do: false

  defp stop_and_block_issue(%State{} = state, issue_id, running_entry, error) do
    stop_and_block_issue(state, issue_id, running_entry, error, :runtime)
  end

  defp stop_and_block_issue(%State{} = state, issue_id, running_entry, error, block_type) do
    cancel_preempt_timer(running_entry)
    stop_running_task(Map.get(running_entry, :pid), Map.get(running_entry, :ref))
    block_issue_from_entry(state, issue_id, running_entry, error, block_type)
  end

  defp block_issue_from_entry(%State{} = state, issue_id, running_entry, error, block_type) do
    blocked_entry = %{
      issue_id: issue_id,
      identifier: Map.get(running_entry, :identifier, issue_id),
      issue: Map.get(running_entry, :issue),
      worker_host: Map.get(running_entry, :worker_host),
      workspace_path: Map.get(running_entry, :workspace_path),
      session_id: running_entry_session_id(running_entry),
      error: error,
      block_type: block_type,
      blocked_at: DateTime.utc_now(),
      last_codex_message: Map.get(running_entry, :last_codex_message),
      last_codex_event: Map.get(running_entry, :last_codex_event),
      last_codex_timestamp: Map.get(running_entry, :last_codex_timestamp)
    }

    maybe_publish_blocked_report(blocked_entry)

    audit("agent.blocked", "linear_issue", issue_id, %{
      outcome: "blocked",
      issue_identifier: blocked_entry.identifier,
      block_type: block_type,
      error: error
    })

    %{
      state
      | running: Map.delete(state.running, issue_id),
        retry_attempts: Map.delete(state.retry_attempts, issue_id),
        claimed: MapSet.put(state.claimed, issue_id),
        blocked: Map.put(state.blocked, issue_id, blocked_entry)
    }
  end

  defp maybe_publish_blocked_report(%{block_type: block_type} = blocked_entry)
       when block_type in [:runtime, :budget] do
    reviewer = Config.settings!().review.reviewer

    case reviewer_mention(reviewer) do
      nil ->
        Logger.warning("Unable to publish Blocked mention for issue_identifier=#{blocked_entry.identifier}: review.reviewer is not configured")

      mention ->
        case Tracker.create_comment(blocked_entry.issue_id, blocked_report(blocked_entry, mention)) do
          :ok ->
            Logger.info("Published Blocked reviewer mention for issue_identifier=#{blocked_entry.identifier}")

          {:error, reason} ->
            Logger.warning("Unable to publish Blocked reviewer mention for issue_identifier=#{blocked_entry.identifier}: #{inspect(reason)}")
        end
    end

    :ok
  end

  defp maybe_publish_blocked_report(_blocked_entry), do: :ok

  defp reviewer_mention(reviewer) when is_binary(reviewer) do
    case String.trim(reviewer) do
      "" -> nil
      "@" <> _ = mention -> mention
      handle -> "@#{handle}"
    end
  end

  defp reviewer_mention(_reviewer), do: nil

  defp blocked_report(blocked_entry, reviewer) do
    """
    ## Loophony Blocked — 사람 입력 필요

    <!-- loophony-blocked:#{blocked_entry.identifier}:#{blocked_entry.session_id} -->
    #{reviewer}

    `#{blocked_entry.identifier}` 작업을 계속하려면 사람의 입력이 필요해 Loophony가
    일시정지했습니다.

    - 사유: #{blocked_entry.error}
    - Blocked 시각: #{DateTime.to_iso8601(blocked_entry.blocked_at)}

    Codex App에서 이 이슈에 명시적인 `unblock` 지침을 제출하세요. 자격 증명이나 secret은
    Linear에 입력하지 마세요.
    """
    |> String.trim()
  end

  defp choose_issues(issues, state) do
    active_states = active_state_set()
    terminal_states = terminal_state_set()

    queued_issues =
      queued_issues_for_dispatch(issues, state, active_states, terminal_states)

    queued_issues
    |> Enum.reduce(%{state | queued: queued_issues}, fn issue, state_acc ->
      if should_dispatch_issue?(issue, state_acc, active_states, terminal_states) do
        dispatch_issue(state_acc, issue)
      else
        state_acc
      end
    end)
    |> drop_claimed_queued_issues()
  end

  defp queued_issues_for_dispatch(issues, state, active_states, terminal_states) do
    issues
    |> sort_issues_for_dispatch()
    |> Enum.filter(&queue_eligible_issue?(&1, state, active_states, terminal_states))
    |> Enum.take(@pending_issue_limit)
  end

  defp drop_claimed_queued_issues(%State{} = state) do
    queued = Enum.reject(state.queued, &MapSet.member?(state.claimed, &1.id))
    %{state | queued: queued}
  end

  defp sort_issues_for_dispatch(issues) when is_list(issues) do
    Enum.sort_by(issues, fn
      %Issue{} = issue ->
        {priority_rank(issue.priority), issue_created_at_sort_key(issue), issue.identifier || issue.id || ""}

      _ ->
        {priority_rank(nil), issue_created_at_sort_key(nil), ""}
    end)
  end

  defp priority_rank(priority) when is_integer(priority) and priority in 1..4, do: priority
  defp priority_rank(_priority), do: 5

  defp issue_created_at_sort_key(%Issue{created_at: %DateTime{} = created_at}) do
    DateTime.to_unix(created_at, :microsecond)
  end

  defp issue_created_at_sort_key(%Issue{}), do: 9_223_372_036_854_775_807
  defp issue_created_at_sort_key(_issue), do: 9_223_372_036_854_775_807

  defp should_dispatch_issue?(
         %Issue{} = issue,
         %State{running: running} = state,
         active_states,
         terminal_states
       ) do
    queue_eligible_issue?(issue, state, active_states, terminal_states) and
      available_slots(state) > 0 and
      state_slots_available?(issue, running) and
      worker_slots_available?(state)
  end

  defp should_dispatch_issue?(_issue, _state, _active_states, _terminal_states), do: false

  defp queue_eligible_issue?(
         %Issue{} = issue,
         %State{running: running, claimed: claimed, blocked: blocked, goal_policy: goal_policy},
         active_states,
         terminal_states
       ) do
    candidate_issue?(issue, active_states, terminal_states) and
      !todo_issue_blocked_by_non_terminal?(issue, terminal_states) and
      GoalPolicy.eligible?(goal_policy, issue) and
      !automated_wait_active?(issue.id) and
      !MapSet.member?(claimed, issue.id) and
      !Map.has_key?(running, issue.id) and
      !Map.has_key?(blocked, issue.id)
  end

  defp queue_eligible_issue?(_issue, _state, _active_states, _terminal_states), do: false

  defp state_slots_available?(%Issue{state: issue_state}, running) when is_map(running) do
    limit = Config.max_concurrent_agents_for_state(issue_state)
    used = running_issue_count_for_state(running, issue_state)
    limit > used
  end

  defp state_slots_available?(_issue, _running), do: false

  defp running_issue_count_for_state(running, issue_state) when is_map(running) do
    normalized_state = normalize_issue_state(issue_state)

    Enum.count(running, fn
      {_id, %{issue: %Issue{state: state_name}}} ->
        normalize_issue_state(state_name) == normalized_state

      _ ->
        false
    end)
  end

  defp candidate_issue?(
         %Issue{
           id: id,
           identifier: identifier,
           title: title,
           state: state_name
         } = issue,
         active_states,
         terminal_states
       )
       when is_binary(id) and is_binary(identifier) and is_binary(title) and is_binary(state_name) do
    issue_routable?(issue) and
      active_issue_state?(state_name, active_states) and
      !terminal_issue_state?(state_name, terminal_states)
  end

  defp candidate_issue?(_issue, _active_states, _terminal_states), do: false

  defp issue_routable?(%Issue{} = issue) do
    Issue.routable?(issue, Config.settings!().tracker.required_labels)
  end

  defp todo_issue_blocked_by_non_terminal?(
         %Issue{state: issue_state, blocked_by: blockers},
         terminal_states
       )
       when is_binary(issue_state) and is_list(blockers) do
    normalize_issue_state(issue_state) == "todo" and
      Enum.any?(blockers, fn
        %{state: blocker_state} when is_binary(blocker_state) ->
          !terminal_issue_state?(blocker_state, terminal_states)

        _ ->
          true
      end)
  end

  defp todo_issue_blocked_by_non_terminal?(_issue, _terminal_states), do: false

  defp terminal_issue_state?(state_name, terminal_states) when is_binary(state_name) do
    MapSet.member?(terminal_states, normalize_issue_state(state_name))
  end

  defp terminal_issue_state?(_state_name, _terminal_states), do: false

  defp active_issue_state?(state_name, active_states) when is_binary(state_name) do
    MapSet.member?(active_states, normalize_issue_state(state_name))
  end

  defp normalize_issue_state(state_name) when is_binary(state_name) do
    String.downcase(String.trim(state_name))
  end

  defp terminal_state_set do
    Config.settings!().tracker.terminal_states
    |> Enum.map(&normalize_issue_state/1)
    |> Enum.filter(&(&1 != ""))
    |> MapSet.new()
  end

  defp active_state_set do
    Config.settings!().tracker.active_states
    |> Enum.map(&normalize_issue_state/1)
    |> Enum.filter(&(&1 != ""))
    |> MapSet.new()
  end

  defp dispatch_issue(%State{} = state, issue, attempt \\ nil, preferred_worker_host \\ nil) do
    case revalidate_issue_for_dispatch(issue, &Tracker.fetch_issue_states_by_ids/1, terminal_state_set()) do
      {:ok, %Issue{} = refreshed_issue} ->
        do_dispatch_issue(state, refreshed_issue, attempt, preferred_worker_host)

      {:skip, :missing} ->
        Logger.info("Skipping dispatch; issue no longer active or visible: #{issue_context(issue)}")
        state

      {:skip, %Issue{} = refreshed_issue} ->
        Logger.info("Skipping stale dispatch after issue refresh: #{issue_context(refreshed_issue)} state=#{inspect(refreshed_issue.state)} blocked_by=#{length(refreshed_issue.blocked_by)}")

        state

      {:error, reason} ->
        Logger.warning("Skipping dispatch; issue refresh failed for #{issue_context(issue)}: #{inspect(reason)}")
        state
    end
  end

  defp do_dispatch_issue(%State{} = state, issue, attempt, preferred_worker_host) do
    recipient = self()

    case select_worker_host(state, preferred_worker_host) do
      :no_worker_capacity ->
        Logger.debug("No SSH worker slots available for #{issue_context(issue)} preferred_worker_host=#{inspect(preferred_worker_host)}")
        state

      worker_host ->
        spawn_issue_on_worker_host(state, issue, attempt, recipient, worker_host)
    end
  end

  defp spawn_issue_on_worker_host(%State{} = state, issue, attempt, recipient, worker_host) do
    case Task.Supervisor.start_child(SymphonyElixir.TaskSupervisor, fn ->
           AgentRunner.run(issue, recipient, attempt: attempt, worker_host: worker_host)
         end) do
      {:ok, pid} ->
        ref = Process.monitor(pid)
        run_id = runtime_id()

        Logger.info("Dispatching issue to agent: #{issue_context(issue)} pid=#{inspect(pid)} attempt=#{inspect(attempt)} worker_host=#{worker_host || "local"}")

        audit("agent.dispatched", "linear_issue", issue.id, %{
          issue_identifier: issue.identifier,
          run_id: run_id,
          attempt: attempt,
          worker_host: worker_host || "local"
        })

        running =
          Map.put(state.running, issue.id, %{
            pid: pid,
            ref: ref,
            run_id: run_id,
            identifier: issue.identifier,
            issue: issue,
            worker_host: worker_host,
            workspace_path: nil,
            model: nil,
            session_role: nil,
            source_issue_id: nil,
            session_id: nil,
            last_codex_message: nil,
            last_codex_timestamp: nil,
            last_codex_event: nil,
            codex_app_server_pid: nil,
            codex_input_tokens: 0,
            codex_output_tokens: 0,
            codex_total_tokens: 0,
            codex_last_reported_input_tokens: 0,
            codex_last_reported_output_tokens: 0,
            codex_last_reported_total_tokens: 0,
            turn_count: 0,
            retry_attempt: normalize_retry_attempt(attempt),
            started_at: DateTime.utc_now()
          })

        %{
          state
          | running: running,
            claimed: MapSet.put(state.claimed, issue.id),
            retry_attempts: Map.delete(state.retry_attempts, issue.id)
        }

      {:error, reason} ->
        Logger.error("Unable to spawn agent for #{issue_context(issue)}: #{inspect(reason)}")
        next_attempt = if is_integer(attempt), do: attempt + 1, else: nil

        schedule_issue_retry(state, issue.id, next_attempt, %{
          identifier: issue.identifier,
          issue_url: issue.url,
          error: "failed to spawn agent: #{inspect(reason)}",
          worker_host: worker_host
        })
    end
  end

  defp revalidate_issue_for_dispatch(%Issue{id: issue_id}, issue_fetcher, terminal_states)
       when is_binary(issue_id) and is_function(issue_fetcher, 1) do
    case issue_fetcher.([issue_id]) do
      {:ok, [%Issue{} = refreshed_issue | _]} ->
        if retry_candidate_issue?(refreshed_issue, terminal_states) do
          {:ok, refreshed_issue}
        else
          {:skip, refreshed_issue}
        end

      {:ok, []} ->
        {:skip, :missing}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp revalidate_issue_for_dispatch(issue, _issue_fetcher, _terminal_states), do: {:ok, issue}

  defp complete_issue(%State{} = state, issue_id) do
    %{
      state
      | completed: MapSet.put(state.completed, issue_id),
        retry_attempts: Map.delete(state.retry_attempts, issue_id),
        linear_health_heartbeats: Map.delete(state.linear_health_heartbeats, issue_id)
    }
  end

  defp schedule_issue_retry(%State{} = state, issue_id, attempt, metadata)
       when is_binary(issue_id) and is_map(metadata) do
    previous_retry = Map.get(state.retry_attempts, issue_id, %{attempt: 0})
    next_attempt = if is_integer(attempt), do: attempt, else: previous_retry.attempt + 1
    delay_ms = retry_delay(next_attempt, metadata)
    old_timer = Map.get(previous_retry, :timer_ref)
    retry_token = make_ref()
    due_at_ms = System.monotonic_time(:millisecond) + delay_ms
    identifier = pick_retry_identifier(issue_id, previous_retry, metadata)
    issue_url = pick_retry_issue_url(previous_retry, metadata)
    error = pick_retry_error(previous_retry, metadata)
    worker_host = pick_retry_worker_host(previous_retry, metadata)
    workspace_path = pick_retry_workspace_path(previous_retry, metadata)

    if is_reference(old_timer) do
      Process.cancel_timer(old_timer)
    end

    timer_ref = Process.send_after(self(), {:retry_issue, issue_id, retry_token}, delay_ms)

    error_suffix = if is_binary(error), do: " error=#{error}", else: ""

    Logger.warning("Retrying issue_id=#{issue_id} issue_identifier=#{identifier} in #{delay_ms}ms (attempt #{next_attempt})#{error_suffix}")

    audit("retry.scheduled", "linear_issue", issue_id, %{
      outcome: "retry",
      issue_identifier: identifier,
      attempt: next_attempt,
      delay_ms: delay_ms,
      error: error
    })

    %{
      state
      | retry_attempts:
          Map.put(state.retry_attempts, issue_id, %{
            attempt: next_attempt,
            timer_ref: timer_ref,
            retry_token: retry_token,
            due_at_ms: due_at_ms,
            identifier: identifier,
            issue_url: issue_url,
            error: error,
            worker_host: worker_host,
            workspace_path: workspace_path
          })
    }
  end

  defp pop_retry_attempt_state(%State{} = state, issue_id, retry_token) when is_reference(retry_token) do
    case Map.get(state.retry_attempts, issue_id) do
      %{attempt: attempt, retry_token: ^retry_token} = retry_entry ->
        metadata = %{
          identifier: Map.get(retry_entry, :identifier),
          issue_url: Map.get(retry_entry, :issue_url),
          error: Map.get(retry_entry, :error),
          worker_host: Map.get(retry_entry, :worker_host),
          workspace_path: Map.get(retry_entry, :workspace_path)
        }

        {:ok, attempt, metadata, %{state | retry_attempts: Map.delete(state.retry_attempts, issue_id)}}

      _ ->
        :missing
    end
  end

  defp handle_retry_issue(%State{} = state, issue_id, attempt, metadata) do
    case Tracker.fetch_issue_states_by_ids([issue_id]) do
      {:ok, issues} ->
        issues
        |> find_issue_by_id(issue_id)
        |> handle_retry_issue_lookup(state, issue_id, attempt, metadata)

      {:error, reason} ->
        Logger.warning("Retry issue refresh failed for issue_id=#{issue_id} issue_identifier=#{metadata[:identifier] || issue_id}: #{inspect(reason)}")

        {:noreply,
         schedule_issue_retry(
           state,
           issue_id,
           attempt + 1,
           Map.merge(metadata, %{error: "retry issue refresh failed: #{inspect(reason)}"})
         )}
    end
  end

  defp handle_retry_issue_lookup(%Issue{} = issue, state, issue_id, attempt, metadata) do
    terminal_states = terminal_state_set()

    cond do
      terminal_issue_state?(issue.state, terminal_states) ->
        Logger.info("Issue state is terminal: issue_id=#{issue_id} issue_identifier=#{issue.identifier} state=#{issue.state}; removing associated workspace")

        cleanup_issue_workspace(issue.identifier, metadata[:worker_host])

        {:noreply,
         state
         |> release_issue_claim(issue_id)
         |> schedule_tick(0)}

      retry_candidate_issue?(issue, terminal_states) ->
        handle_active_retry(state, issue, attempt, metadata)

      true ->
        Logger.debug("Issue left active states, removing claim issue_id=#{issue_id} issue_identifier=#{issue.identifier}")

        {:noreply,
         state
         |> release_issue_claim(issue_id)
         |> schedule_tick(0)}
    end
  end

  defp handle_retry_issue_lookup(nil, state, issue_id, _attempt, metadata) do
    Logger.debug("Issue no longer visible, removing claim issue_id=#{issue_id}")

    cleanup_issue_workspace(metadata[:identifier], metadata[:worker_host])

    {:noreply,
     state
     |> release_issue_claim(issue_id)
     |> schedule_tick(0)}
  end

  defp cleanup_issue_workspace(identifier, worker_host \\ nil)

  defp cleanup_issue_workspace(identifier, worker_host) when is_binary(identifier) do
    Workspace.remove_issue_workspaces(identifier, worker_host)
  end

  defp cleanup_issue_workspace(_identifier, _worker_host), do: :ok

  defp blocked_issue_worker_host(%State{} = state, issue_id) do
    state.blocked
    |> Map.get(issue_id, %{})
    |> Map.get(:worker_host)
  end

  defp run_terminal_workspace_cleanup do
    case Tracker.fetch_issues_by_states(Config.settings!().tracker.terminal_states) do
      {:ok, issues} ->
        issues
        |> Enum.each(fn
          %Issue{identifier: identifier} when is_binary(identifier) ->
            cleanup_issue_workspace(identifier)

          _ ->
            :ok
        end)

      {:error, reason} ->
        Logger.warning("Skipping startup terminal workspace cleanup; failed to fetch terminal issues: #{inspect(reason)}")
    end
  end

  defp notify_dashboard do
    StatusDashboard.notify_update()
  end

  defp handle_active_retry(state, issue, attempt, metadata) do
    cond do
      LoopStore.review_gate_open?() ->
        {:noreply,
         schedule_issue_retry(state, issue.id, attempt, %{
           identifier: issue.identifier,
           issue_url: issue.url,
           error: "scheduled goal review gate is open",
           delay_type: :review_gate,
           worker_host: metadata[:worker_host],
           workspace_path: metadata[:workspace_path]
         })}

      retry_candidate_issue?(issue, terminal_state_set()) and
        dispatch_slots_available?(issue, state) and
          worker_slots_available?(state, metadata[:worker_host]) ->
        {:noreply, dispatch_issue(state, issue, attempt, metadata[:worker_host])}

      true ->
        Logger.debug("No available slots for retrying #{issue_context(issue)}; retrying again")

        {:noreply,
         schedule_issue_retry(
           state,
           issue.id,
           attempt + 1,
           Map.merge(metadata, %{
             identifier: issue.identifier,
             error: "no available orchestrator slots"
           })
         )}
    end
  end

  defp release_issue_claim(%State{} = state, issue_id) do
    %{
      state
      | claimed: MapSet.delete(state.claimed, issue_id),
        blocked: Map.delete(state.blocked, issue_id),
        retry_attempts: Map.delete(state.retry_attempts, issue_id)
    }
  end

  defp retry_delay(attempt, metadata) when is_integer(attempt) and attempt > 0 and is_map(metadata) do
    case metadata[:delay_type] do
      :review_gate -> Config.settings!().polling.interval_ms
      :continuation when attempt == 1 -> @continuation_retry_delay_ms
      _ -> failure_retry_delay(attempt)
    end
  end

  defp failure_retry_delay(attempt) do
    max_delay_power = min(attempt - 1, 10)
    min(@failure_retry_base_ms * (1 <<< max_delay_power), Config.settings!().agent.max_retry_backoff_ms)
  end

  defp normalize_retry_attempt(attempt) when is_integer(attempt) and attempt > 0, do: attempt
  defp normalize_retry_attempt(_attempt), do: 0

  defp next_retry_attempt_from_running(running_entry) do
    case Map.get(running_entry, :retry_attempt) do
      attempt when is_integer(attempt) and attempt > 0 -> attempt + 1
      _ -> nil
    end
  end

  defp pick_retry_identifier(issue_id, previous_retry, metadata) do
    metadata[:identifier] || Map.get(previous_retry, :identifier) || issue_id
  end

  defp pick_retry_issue_url(previous_retry, metadata) do
    metadata[:issue_url] || Map.get(previous_retry, :issue_url)
  end

  defp pick_retry_error(previous_retry, metadata) do
    metadata[:error] || Map.get(previous_retry, :error)
  end

  defp pick_retry_worker_host(previous_retry, metadata) do
    metadata[:worker_host] || Map.get(previous_retry, :worker_host)
  end

  defp pick_retry_workspace_path(previous_retry, metadata) do
    metadata[:workspace_path] || Map.get(previous_retry, :workspace_path)
  end

  defp maybe_put_runtime_value(running_entry, _key, nil), do: running_entry

  defp maybe_put_runtime_value(running_entry, key, value) when is_map(running_entry) do
    Map.put(running_entry, key, value)
  end

  defp select_worker_host(%State{} = state, preferred_worker_host) do
    case Config.settings!().worker.ssh_hosts do
      [] ->
        nil

      hosts ->
        available_hosts = Enum.filter(hosts, &worker_host_slots_available?(state, &1))

        cond do
          available_hosts == [] ->
            :no_worker_capacity

          preferred_worker_host_available?(preferred_worker_host, available_hosts) ->
            preferred_worker_host

          true ->
            least_loaded_worker_host(state, available_hosts)
        end
    end
  end

  defp preferred_worker_host_available?(preferred_worker_host, hosts)
       when is_binary(preferred_worker_host) and is_list(hosts) do
    preferred_worker_host != "" and preferred_worker_host in hosts
  end

  defp preferred_worker_host_available?(_preferred_worker_host, _hosts), do: false

  defp least_loaded_worker_host(%State{} = state, hosts) when is_list(hosts) do
    hosts
    |> Enum.with_index()
    |> Enum.min_by(fn {host, index} ->
      {running_worker_host_count(state.running, host), index}
    end)
    |> elem(0)
  end

  defp running_worker_host_count(running, worker_host) when is_map(running) and is_binary(worker_host) do
    Enum.count(running, fn
      {_issue_id, %{worker_host: ^worker_host}} -> true
      _ -> false
    end)
  end

  defp worker_slots_available?(%State{} = state) do
    select_worker_host(state, nil) != :no_worker_capacity
  end

  defp worker_slots_available?(%State{} = state, preferred_worker_host) do
    select_worker_host(state, preferred_worker_host) != :no_worker_capacity
  end

  defp worker_host_slots_available?(%State{} = state, worker_host) when is_binary(worker_host) do
    case Config.settings!().worker.max_concurrent_agents_per_host do
      limit when is_integer(limit) and limit > 0 ->
        running_worker_host_count(state.running, worker_host) < limit

      _ ->
        true
    end
  end

  defp find_issue_by_id(issues, issue_id) when is_binary(issue_id) do
    Enum.find(issues, fn
      %Issue{id: ^issue_id} ->
        true

      _ ->
        false
    end)
  end

  defp find_issue_id_for_ref(running, ref) do
    running
    |> Enum.find_value(fn {issue_id, %{ref: running_ref}} ->
      if running_ref == ref, do: issue_id
    end)
  end

  defp running_entry_session_id(%{session_id: session_id}) when is_binary(session_id),
    do: session_id

  defp running_entry_session_id(_running_entry), do: "n/a"

  defp issue_context(%Issue{id: issue_id, identifier: identifier}) do
    "issue_id=#{issue_id} issue_identifier=#{identifier}"
  end

  defp available_slots(%State{} = state) do
    max(@top_level_session_limit - map_size(state.running), 0)
  end

  @spec preempt_issue(String.t(), String.t(), GenServer.server()) :: map() | :unavailable
  def preempt_issue(issue_id, request_id, server \\ __MODULE__)
      when is_binary(issue_id) and is_binary(request_id) do
    GenServer.call(server, {:preempt_issue, issue_id, request_id})
  catch
    :exit, _reason -> :unavailable
  end

  @spec request_refresh() :: map() | :unavailable
  def request_refresh do
    request_refresh(__MODULE__)
  end

  @spec request_refresh(GenServer.server()) :: map() | :unavailable
  def request_refresh(server) do
    if Process.whereis(server) do
      GenServer.call(server, :request_refresh)
    else
      :unavailable
    end
  end

  @spec resume_issue(String.t(), GenServer.server()) :: map() | :unavailable
  def resume_issue(issue_id, server \\ __MODULE__) when is_binary(issue_id) do
    GenServer.call(server, {:resume_issue, issue_id})
  catch
    :exit, _reason -> :unavailable
  end

  @spec resume_after_review() :: map() | :unavailable
  def resume_after_review, do: resume_after_review(__MODULE__)

  @spec resume_after_review(GenServer.server()) :: map() | :unavailable
  def resume_after_review(server) do
    if Process.whereis(server) do
      GenServer.call(server, :resume_after_review)
    else
      :unavailable
    end
  end

  @spec snapshot() :: map() | :timeout | :unavailable
  def snapshot, do: snapshot(__MODULE__, 15_000)

  @spec snapshot(GenServer.server(), timeout()) :: map() | :timeout | :unavailable
  def snapshot(server, timeout) do
    if Process.whereis(server) do
      try do
        GenServer.call(server, :snapshot, timeout)
      catch
        :exit, {:timeout, _} -> :timeout
        :exit, _ -> :unavailable
      end
    else
      :unavailable
    end
  end

  @impl true
  def handle_call(:snapshot, _from, state) do
    state = refresh_runtime_config(state)
    now = DateTime.utc_now()
    now_ms = System.monotonic_time(:millisecond)

    running =
      state.running
      |> Enum.map(fn {issue_id, metadata} ->
        %{
          issue_id: issue_id,
          identifier: metadata.identifier,
          issue_url: metadata.issue.url,
          run_id: Map.get(metadata, :run_id),
          state: metadata.issue.state,
          worker_host: Map.get(metadata, :worker_host),
          workspace_path: Map.get(metadata, :workspace_path),
          model: Map.get(metadata, :model),
          session_role: Map.get(metadata, :session_role),
          source_issue_id: Map.get(metadata, :source_issue_id),
          session_id: metadata.session_id,
          codex_app_server_pid: metadata.codex_app_server_pid,
          codex_input_tokens: metadata.codex_input_tokens,
          codex_output_tokens: metadata.codex_output_tokens,
          codex_total_tokens: metadata.codex_total_tokens,
          turn_count: Map.get(metadata, :turn_count, 0),
          started_at: metadata.started_at,
          last_codex_timestamp: metadata.last_codex_timestamp,
          last_codex_message: metadata.last_codex_message,
          last_codex_event: metadata.last_codex_event,
          preemption: running_preemption_payload(metadata),
          runtime_seconds: running_seconds(metadata.started_at, now)
        }
      end)

    retrying =
      state.retry_attempts
      |> Enum.map(fn {issue_id, %{attempt: attempt, due_at_ms: due_at_ms} = retry} ->
        %{
          issue_id: issue_id,
          attempt: attempt,
          due_in_ms: max(0, due_at_ms - now_ms),
          identifier: Map.get(retry, :identifier),
          issue_url: Map.get(retry, :issue_url),
          error: Map.get(retry, :error),
          worker_host: Map.get(retry, :worker_host),
          workspace_path: Map.get(retry, :workspace_path)
        }
      end)

    blocked =
      state.blocked
      |> Enum.map(fn {issue_id, metadata} ->
        %{
          issue_id: issue_id,
          identifier: Map.get(metadata, :identifier),
          issue_url: blocked_issue_url(metadata),
          state: blocked_issue_state(metadata),
          worker_host: Map.get(metadata, :worker_host),
          workspace_path: Map.get(metadata, :workspace_path),
          session_id: Map.get(metadata, :session_id),
          error: Map.get(metadata, :error),
          blocked_at: Map.get(metadata, :blocked_at),
          last_codex_timestamp: Map.get(metadata, :last_codex_timestamp),
          last_codex_message: Map.get(metadata, :last_codex_message),
          last_codex_event: Map.get(metadata, :last_codex_event),
          block_type: Map.get(metadata, :block_type)
        }
      end)

    queued =
      Enum.map(state.queued, fn issue ->
        %{
          issue_id: issue.id,
          identifier: issue.identifier,
          issue_url: issue.url,
          state: issue.state,
          priority: issue.priority,
          created_at: issue.created_at
        }
      end)

    waiting =
      case RuntimeStore.active_waits(RuntimeStore, @snapshot_dependency_timeout_ms) do
        {:ok, entries} -> entries
        _ -> []
      end

    jobs =
      case RuntimeStore.list_jobs(%{}, RuntimeStore, @snapshot_dependency_timeout_ms) do
        {:ok, entries} -> Enum.take(entries, 50)
        _ -> []
      end

    review_gate = review_gate_payload()

    goal_policy =
      Map.put(
        state.goal_policy,
        :review,
        GoalPolicy.review_staleness(review_gate, state.goal_policy)
      )

    {:reply,
     %{
       running: running,
       queued: queued,
       retrying: retrying,
       blocked: blocked,
       waiting: waiting,
       jobs: jobs,
       loop: LoopStore.summary(),
       review_gate: review_gate,
       goal_policy: goal_policy,
       intake: state.intake,
       runtime: RuntimeStore.summary(RuntimeStore, @snapshot_dependency_timeout_ms),
       budget: budget_snapshot(state),
       memory: MemoryStore.status(MemoryStore, @snapshot_dependency_timeout_ms),
       audit: AuditLog.summary(AuditLog, @snapshot_dependency_timeout_ms),
       codex_totals: state.codex_totals,
       rate_limits: Map.get(state, :codex_rate_limits),
       polling: %{
         checking?: state.poll_check_in_progress == true,
         next_poll_in_ms: next_poll_in_ms(state.next_poll_due_at_ms, now_ms),
         poll_interval_ms: state.poll_interval_ms
       }
     }, state}
  end

  def handle_call(:request_refresh, _from, state) do
    now_ms = System.monotonic_time(:millisecond)
    already_due? = is_integer(state.next_poll_due_at_ms) and state.next_poll_due_at_ms <= now_ms
    coalesced = state.poll_check_in_progress == true or already_due?
    state = if coalesced, do: state, else: schedule_tick(state, 0)

    {:reply,
     %{
       queued: true,
       coalesced: coalesced,
       requested_at: DateTime.utc_now(),
       operations: ["poll", "reconcile"]
     }, state}
  end

  def handle_call({:preempt_issue, issue_id, request_id}, _from, state) do
    {payload, next_state} = request_operator_preempt(state, issue_id, request_id)
    notify_dashboard()
    {:reply, payload, next_state}
  end

  def handle_call({:resume_issue, issue_id}, _from, state) do
    blocked? = Map.has_key?(state.blocked, issue_id)
    state = if blocked?, do: release_issue_claim(state, issue_id), else: state
    state = schedule_tick(state, 0)

    {:reply, %{released: blocked?, issue_id: issue_id}, state}
  end

  def handle_call(:resume_after_review, _from, state) do
    state =
      state
      |> release_review_gate_blocks()
      |> wake_review_gate_retries()
      |> schedule_tick(0)

    {:reply, %{resumed: true, requested_at: DateTime.utc_now()}, state}
  end

  defp review_gate_payload do
    case LoopStore.current_review_gate() do
      {:ok, gate} -> gate
      {:error, reason} -> %{status: "unavailable", error: inspect(reason)}
    end
  end

  defp running_preemption_payload(metadata) do
    case Map.get(metadata, :preempt_request_id) do
      request_id when is_binary(request_id) ->
        %{
          status: "interrupt_requested",
          request_id: request_id,
          requested_at: Map.get(metadata, :preempt_requested_at),
          grace_timeout_ms: @preempt_grace_ms
        }

      _other ->
        nil
    end
  end

  defp release_review_gate_blocks(state) do
    review_issue_ids =
      state.blocked
      |> Enum.filter(fn {_issue_id, metadata} -> Map.get(metadata, :block_type) == :review_gate end)
      |> Enum.map(&elem(&1, 0))

    Enum.reduce(review_issue_ids, state, fn issue_id, acc -> release_issue_claim(acc, issue_id) end)
  end

  defp wake_review_gate_retries(state) do
    Enum.each(state.retry_attempts, fn
      {issue_id, %{error: "scheduled goal review gate is open", retry_token: token, timer_ref: timer_ref}} ->
        if is_reference(timer_ref), do: Process.cancel_timer(timer_ref)
        send(self(), {:retry_issue, issue_id, token})

      _ ->
        :ok
    end)

    state
  end

  defp blocked_issue_state(%{issue: %Issue{state: state}}), do: state
  defp blocked_issue_state(_metadata), do: nil

  defp blocked_issue_url(%{issue: %Issue{url: url}}), do: url
  defp blocked_issue_url(_metadata), do: nil

  defp integrate_codex_update(running_entry, %{event: event, timestamp: timestamp} = update) do
    token_delta = extract_token_delta(running_entry, update)
    codex_input_tokens = Map.get(running_entry, :codex_input_tokens, 0)
    codex_output_tokens = Map.get(running_entry, :codex_output_tokens, 0)
    codex_total_tokens = Map.get(running_entry, :codex_total_tokens, 0)
    codex_app_server_pid = Map.get(running_entry, :codex_app_server_pid)
    last_reported_input = Map.get(running_entry, :codex_last_reported_input_tokens, 0)
    last_reported_output = Map.get(running_entry, :codex_last_reported_output_tokens, 0)
    last_reported_total = Map.get(running_entry, :codex_last_reported_total_tokens, 0)
    turn_count = Map.get(running_entry, :turn_count, 0)

    {
      Map.merge(running_entry, %{
        last_codex_timestamp: timestamp,
        last_codex_message: summarize_codex_update(update),
        session_id: session_id_for_update(running_entry.session_id, update),
        last_codex_event: event,
        codex_app_server_pid: codex_app_server_pid_for_update(codex_app_server_pid, update),
        codex_input_tokens: codex_input_tokens + token_delta.input_tokens,
        codex_output_tokens: codex_output_tokens + token_delta.output_tokens,
        codex_total_tokens: codex_total_tokens + token_delta.total_tokens,
        codex_last_reported_input_tokens: max(last_reported_input, token_delta.input_reported),
        codex_last_reported_output_tokens: max(last_reported_output, token_delta.output_reported),
        codex_last_reported_total_tokens: max(last_reported_total, token_delta.total_reported),
        turn_count: turn_count_for_update(turn_count, running_entry.session_id, update)
      }),
      token_delta
    }
  end

  defp codex_app_server_pid_for_update(_existing, %{codex_app_server_pid: pid})
       when is_binary(pid),
       do: pid

  defp codex_app_server_pid_for_update(_existing, %{codex_app_server_pid: pid})
       when is_integer(pid),
       do: Integer.to_string(pid)

  defp codex_app_server_pid_for_update(_existing, %{codex_app_server_pid: pid}) when is_list(pid),
    do: to_string(pid)

  defp codex_app_server_pid_for_update(existing, _update), do: existing

  defp session_id_for_update(_existing, %{session_id: session_id}) when is_binary(session_id),
    do: session_id

  defp session_id_for_update(existing, _update), do: existing

  defp turn_count_for_update(existing_count, existing_session_id, %{
         event: :session_started,
         session_id: session_id
       })
       when is_integer(existing_count) and is_binary(session_id) do
    if session_id == existing_session_id do
      existing_count
    else
      existing_count + 1
    end
  end

  defp turn_count_for_update(existing_count, _existing_session_id, _update)
       when is_integer(existing_count),
       do: existing_count

  defp turn_count_for_update(_existing_count, _existing_session_id, _update), do: 0

  defp summarize_codex_update(update) do
    %{
      event: update[:event],
      message: update[:payload] || update[:raw],
      timestamp: update[:timestamp]
    }
  end

  defp schedule_tick(%State{} = state, delay_ms) when is_integer(delay_ms) and delay_ms >= 0 do
    if is_reference(state.tick_timer_ref) do
      Process.cancel_timer(state.tick_timer_ref)
    end

    tick_token = make_ref()
    timer_ref = Process.send_after(self(), {:tick, tick_token}, delay_ms)

    %{
      state
      | tick_timer_ref: timer_ref,
        tick_token: tick_token,
        next_poll_due_at_ms: System.monotonic_time(:millisecond) + delay_ms
    }
  end

  defp schedule_poll_cycle_start do
    :timer.send_after(@poll_transition_render_delay_ms, self(), :run_poll_cycle)
    :ok
  end

  defp next_poll_in_ms(nil, _now_ms), do: nil

  defp next_poll_in_ms(next_poll_due_at_ms, now_ms) when is_integer(next_poll_due_at_ms) do
    max(0, next_poll_due_at_ms - now_ms)
  end

  defp pop_running_entry(state, issue_id) do
    running_entry = Map.get(state.running, issue_id)
    cancel_preempt_timer(running_entry)

    {running_entry,
     %{
       state
       | running: Map.delete(state.running, issue_id),
         linear_health_heartbeats: Map.delete(state.linear_health_heartbeats, issue_id)
     }}
  end

  defp record_session_completion_totals(state, running_entry) when is_map(running_entry) do
    runtime_seconds = running_seconds(running_entry.started_at, DateTime.utc_now())

    runtime_result =
      RuntimeStore.finish_run(
        Map.get(running_entry, :run_id, running_entry_session_id(running_entry)),
        running_entry.issue.id,
        running_entry.identifier,
        runtime_seconds
      )

    if match?({:ok, %{runtime_recorded: true}}, runtime_result) do
      audit("agent.finished", "linear_issue", running_entry.issue.id, %{
        issue_identifier: running_entry.identifier,
        run_id: Map.get(running_entry, :run_id),
        session_id: running_entry_session_id(running_entry),
        runtime_seconds: runtime_seconds,
        input_tokens: Map.get(running_entry, :codex_input_tokens, 0),
        output_tokens: Map.get(running_entry, :codex_output_tokens, 0),
        total_tokens: Map.get(running_entry, :codex_total_tokens, 0)
      })
    end

    codex_totals =
      apply_token_delta(
        state.codex_totals,
        %{
          input_tokens: 0,
          output_tokens: 0,
          total_tokens: 0,
          seconds_running: runtime_seconds
        }
      )

    %{state | codex_totals: codex_totals}
  end

  defp record_session_completion_totals(state, _running_entry), do: state

  defp refresh_runtime_config(%State{} = state) do
    config = Config.settings!()

    %{
      state
      | poll_interval_ms: config.polling.interval_ms,
        max_concurrent_agents: config.agent.max_concurrent_agents,
        linear_heartbeat_interval_ms: config.observability.linear_heartbeat_interval_ms
    }
  end

  defp runtime_id do
    8
    |> :crypto.strong_rand_bytes()
    |> Base.encode16(case: :lower)
  end

  defp retry_candidate_issue?(%Issue{} = issue, terminal_states) do
    candidate_issue?(issue, active_state_set(), terminal_states) and
      !todo_issue_blocked_by_non_terminal?(issue, terminal_states)
  end

  defp dispatch_slots_available?(%Issue{} = issue, %State{} = state) do
    available_slots(state) > 0 and state_slots_available?(issue, state.running)
  end

  defp apply_codex_token_delta(
         %{codex_totals: codex_totals} = state,
         %{input_tokens: input, output_tokens: output, total_tokens: total} = token_delta
       )
       when is_integer(input) and is_integer(output) and is_integer(total) do
    %{state | codex_totals: apply_token_delta(codex_totals, token_delta)}
  end

  defp apply_codex_token_delta(state, _token_delta), do: state

  defp apply_codex_rate_limits(%State{} = state, update) when is_map(update) do
    case extract_rate_limits(update) do
      %{} = rate_limits ->
        %{state | codex_rate_limits: rate_limits}

      _ ->
        state
    end
  end

  defp apply_codex_rate_limits(state, _update), do: state

  defp apply_token_delta(codex_totals, token_delta) do
    input_tokens = Map.get(codex_totals, :input_tokens, 0) + token_delta.input_tokens
    output_tokens = Map.get(codex_totals, :output_tokens, 0) + token_delta.output_tokens
    total_tokens = Map.get(codex_totals, :total_tokens, 0) + token_delta.total_tokens

    seconds_running =
      Map.get(codex_totals, :seconds_running, 0) + Map.get(token_delta, :seconds_running, 0)

    %{
      input_tokens: max(0, input_tokens),
      output_tokens: max(0, output_tokens),
      total_tokens: max(0, total_tokens),
      seconds_running: max(0, seconds_running)
    }
  end

  defp extract_token_delta(running_entry, %{event: _, timestamp: _} = update) do
    running_entry = running_entry || %{}
    usage = extract_token_usage(update)

    {
      compute_token_delta(
        running_entry,
        :input,
        usage,
        :codex_last_reported_input_tokens
      ),
      compute_token_delta(
        running_entry,
        :output,
        usage,
        :codex_last_reported_output_tokens
      ),
      compute_token_delta(
        running_entry,
        :total,
        usage,
        :codex_last_reported_total_tokens
      )
    }
    |> Tuple.to_list()
    |> then(fn [input, output, total] ->
      %{
        input_tokens: input.delta,
        output_tokens: output.delta,
        total_tokens: total.delta,
        input_reported: input.reported,
        output_reported: output.reported,
        total_reported: total.reported
      }
    end)
  end

  defp compute_token_delta(running_entry, token_key, usage, reported_key) do
    next_total = get_token_usage(usage, token_key)
    prev_reported = Map.get(running_entry, reported_key, 0)

    delta =
      if is_integer(next_total) and next_total >= prev_reported do
        next_total - prev_reported
      else
        0
      end

    %{
      delta: max(delta, 0),
      reported: if(is_integer(next_total), do: next_total, else: prev_reported)
    }
  end

  defp extract_token_usage(update) do
    payloads = [
      update[:usage],
      Map.get(update, "usage"),
      Map.get(update, :usage),
      update[:payload],
      Map.get(update, "payload"),
      update
    ]

    Enum.find_value(payloads, &absolute_token_usage_from_payload/1) ||
      Enum.find_value(payloads, &turn_completed_usage_from_payload/1) ||
      %{}
  end

  defp extract_rate_limits(update) do
    rate_limits_from_payload(update[:rate_limits]) ||
      rate_limits_from_payload(Map.get(update, "rate_limits")) ||
      rate_limits_from_payload(Map.get(update, :rate_limits)) ||
      rate_limits_from_payload(update[:payload]) ||
      rate_limits_from_payload(Map.get(update, "payload")) ||
      rate_limits_from_payload(update)
  end

  defp absolute_token_usage_from_payload(payload) when is_map(payload) do
    absolute_paths = [
      ["params", "msg", "payload", "info", "total_token_usage"],
      [:params, :msg, :payload, :info, :total_token_usage],
      ["params", "msg", "info", "total_token_usage"],
      [:params, :msg, :info, :total_token_usage],
      ["params", "tokenUsage", "total"],
      [:params, :tokenUsage, :total],
      ["tokenUsage", "total"],
      [:tokenUsage, :total]
    ]

    explicit_map_at_paths(payload, absolute_paths)
  end

  defp absolute_token_usage_from_payload(_payload), do: nil

  defp turn_completed_usage_from_payload(payload) when is_map(payload) do
    method = Map.get(payload, "method") || Map.get(payload, :method)

    if method in ["turn/completed", :turn_completed] do
      direct =
        Map.get(payload, "usage") ||
          Map.get(payload, :usage) ||
          map_at_path(payload, ["params", "usage"]) ||
          map_at_path(payload, [:params, :usage])

      if is_map(direct) and integer_token_map?(direct), do: direct
    end
  end

  defp turn_completed_usage_from_payload(_payload), do: nil

  defp rate_limits_from_payload(payload) when is_map(payload) do
    direct = Map.get(payload, "rate_limits") || Map.get(payload, :rate_limits)

    cond do
      rate_limits_map?(direct) ->
        direct

      rate_limits_map?(payload) ->
        payload

      true ->
        rate_limit_payloads(payload)
    end
  end

  defp rate_limits_from_payload(payload) when is_list(payload) do
    rate_limit_payloads(payload)
  end

  defp rate_limits_from_payload(_payload), do: nil

  defp rate_limit_payloads(payload) when is_map(payload) do
    Map.values(payload)
    |> Enum.reduce_while(nil, fn
      value, nil ->
        case rate_limits_from_payload(value) do
          nil -> {:cont, nil}
          rate_limits -> {:halt, rate_limits}
        end

      _value, result ->
        {:halt, result}
    end)
  end

  defp rate_limit_payloads(payload) when is_list(payload) do
    payload
    |> Enum.reduce_while(nil, fn
      value, nil ->
        case rate_limits_from_payload(value) do
          nil -> {:cont, nil}
          rate_limits -> {:halt, rate_limits}
        end

      _value, result ->
        {:halt, result}
    end)
  end

  defp rate_limits_map?(payload) when is_map(payload) do
    limit_id =
      Map.get(payload, "limit_id") ||
        Map.get(payload, :limit_id) ||
        Map.get(payload, "limit_name") ||
        Map.get(payload, :limit_name)

    has_buckets =
      Enum.any?(
        ["primary", :primary, "secondary", :secondary, "credits", :credits],
        &Map.has_key?(payload, &1)
      )

    !is_nil(limit_id) and has_buckets
  end

  defp rate_limits_map?(_payload), do: false

  defp explicit_map_at_paths(payload, paths) when is_map(payload) and is_list(paths) do
    Enum.find_value(paths, fn path ->
      value = map_at_path(payload, path)

      if is_map(value) and integer_token_map?(value), do: value
    end)
  end

  defp explicit_map_at_paths(_payload, _paths), do: nil

  defp map_at_path(payload, path) when is_map(payload) and is_list(path) do
    Enum.reduce_while(path, payload, fn key, acc ->
      if is_map(acc) and Map.has_key?(acc, key) do
        {:cont, Map.get(acc, key)}
      else
        {:halt, nil}
      end
    end)
  end

  defp map_at_path(_payload, _path), do: nil

  defp integer_token_map?(payload) do
    token_fields = [
      :input_tokens,
      :output_tokens,
      :total_tokens,
      :prompt_tokens,
      :completion_tokens,
      :inputTokens,
      :outputTokens,
      :totalTokens,
      :promptTokens,
      :completionTokens,
      "input_tokens",
      "output_tokens",
      "total_tokens",
      "prompt_tokens",
      "completion_tokens",
      "inputTokens",
      "outputTokens",
      "totalTokens",
      "promptTokens",
      "completionTokens"
    ]

    token_fields
    |> Enum.any?(fn field ->
      value = payload_get(payload, field)
      !is_nil(integer_like(value))
    end)
  end

  defp get_token_usage(usage, :input),
    do:
      payload_get(usage, [
        "input_tokens",
        "prompt_tokens",
        :input_tokens,
        :prompt_tokens,
        :input,
        "promptTokens",
        :promptTokens,
        "inputTokens",
        :inputTokens
      ])

  defp get_token_usage(usage, :output),
    do:
      payload_get(usage, [
        "output_tokens",
        "completion_tokens",
        :output_tokens,
        :completion_tokens,
        :output,
        :completion,
        "outputTokens",
        :outputTokens,
        "completionTokens",
        :completionTokens
      ])

  defp get_token_usage(usage, :total),
    do:
      payload_get(usage, [
        "total_tokens",
        "total",
        :total_tokens,
        :total,
        "totalTokens",
        :totalTokens
      ])

  defp payload_get(payload, fields) when is_list(fields) do
    Enum.find_value(fields, fn field -> map_integer_value(payload, field) end)
  end

  defp payload_get(payload, field), do: map_integer_value(payload, field)

  defp map_integer_value(payload, field) do
    if is_map(payload) do
      value = Map.get(payload, field)
      integer_like(value)
    else
      nil
    end
  end

  defp running_seconds(%DateTime{} = started_at, %DateTime{} = now) do
    max(0, DateTime.diff(now, started_at, :second))
  end

  defp running_seconds(_started_at, _now), do: 0

  defp release_ready_waits(%State{} = state) do
    case RuntimeStore.active_waits() do
      {:ok, waits} ->
        Enum.reduce(waits, state, &release_ready_wait/2)

      {:error, reason} ->
        Logger.warning("Unable to inspect automated waits: #{inspect(reason)}")
        state
    end
  end

  defp release_ready_wait(wait, state) do
    case WaitCondition.ready?(wait) do
      {:ready, reason} -> release_automated_wait(wait, reason, state)
      :waiting -> state
      {:error, reason} -> log_pending_wait(wait, reason, state)
    end
  end

  defp release_automated_wait(wait, reason, state) do
    case RuntimeStore.release_wait(wait.wait_id, reason) do
      {:ok, _released} ->
        Logger.info(
          "Automated wait released for issue_id=#{wait.issue_id} " <>
            "issue_identifier=#{wait.issue_identifier} reason=#{reason}"
        )

        release_issue_claim(state, wait.issue_id)

      {:error, error} ->
        Logger.warning("Unable to release automated wait wait_id=#{wait.wait_id}: #{inspect(error)}")

        state
    end
  end

  defp log_pending_wait(wait, reason, state) do
    Logger.debug("Automated wait probe remains pending wait_id=#{wait.wait_id}: #{inspect(reason)}")

    state
  end

  defp automated_wait_active?(issue_id) when is_binary(issue_id) do
    match?({:ok, %{}}, RuntimeStore.active_wait(issue_id))
  end

  defp automated_wait_active?(_issue_id), do: false

  defp persist_issue_token_usage(state, issue_id, running_entry, token_delta)
       when is_binary(issue_id) and is_map(running_entry) and is_map(token_delta) do
    if Map.get(token_delta, :total_tokens, 0) > 0 do
      case RuntimeStore.add_token_usage(issue_id, running_entry.identifier, token_delta) do
        {:ok, _usage} ->
          state

        {:error, reason} ->
          Logger.warning("Unable to persist budget usage for issue_id=#{issue_id}: #{inspect(reason)}")
          state
      end
    else
      state
    end
  end

  defp persist_issue_token_usage(state, _issue_id, _running_entry, _token_delta), do: state

  defp enforce_running_budgets(%State{} = state) do
    if Config.settings!().budget.enabled do
      state.running
      |> Map.keys()
      |> Enum.reduce(state, &enforce_issue_budget(&2, &1))
    else
      state
    end
  end

  defp enforce_issue_budget(%State{} = state, issue_id) do
    case {Config.settings!().budget.enabled, Map.get(state.running, issue_id)} do
      {true, %{} = running_entry} ->
        case RuntimeStore.budget_usage(issue_id) do
          {:ok, usage} ->
            usage = add_current_runtime(usage, running_entry)
            evaluation = BudgetPolicy.evaluate(usage)
            apply_budget_evaluation(state, issue_id, running_entry, evaluation)

          {:error, reason} ->
            Logger.warning("Unable to evaluate budget for issue_id=#{issue_id}: #{inspect(reason)}")
            state
        end

      _ ->
        state
    end
  end

  defp add_current_runtime(usage, running_entry) do
    current_seconds = running_seconds(running_entry.started_at, DateTime.utc_now())
    update_in(usage, [:issue, :runtime_seconds], &((&1 || 0) + current_seconds))
  end

  defp apply_budget_evaluation(state, issue_id, running_entry, %{status: "warning"} = evaluation) do
    if is_nil(get_in(evaluation, [:usage, :issue, :warned_at])) do
      _ = RuntimeStore.mark_budget_state(issue_id, "warned")

      audit("budget.warning", "linear_issue", issue_id, %{
        issue_identifier: running_entry.identifier,
        maximum_percent: evaluation.maximum_percent,
        metrics: evaluation.metrics
      })
    end

    state
  end

  defp apply_budget_evaluation(
         state,
         issue_id,
         running_entry,
         %{status: "exhausted", action: "warn"} = evaluation
       ) do
    unless get_in(evaluation, [:usage, :issue, :exhausted_at]) do
      _ = RuntimeStore.mark_budget_state(issue_id, "exhausted")

      audit("budget.exhausted", "linear_issue", issue_id, %{
        outcome: "warning",
        issue_identifier: running_entry.identifier,
        reasons: evaluation.exhausted_reasons,
        metrics: evaluation.metrics
      })

      maybe_publish_budget_warning(running_entry, evaluation)
    end

    state
  end

  defp apply_budget_evaluation(
         state,
         issue_id,
         running_entry,
         %{status: "exhausted", action: "wait", exhausted_reasons: ["daily_tokens"]} = evaluation
       ) do
    unless get_in(evaluation, [:usage, :issue, :exhausted_at]) do
      _ = RuntimeStore.mark_budget_state(issue_id, "exhausted")

      audit("budget.exhausted", "linear_issue", issue_id, %{
        outcome: "waiting",
        issue_identifier: running_entry.identifier,
        reasons: evaluation.exhausted_reasons,
        metrics: evaluation.metrics
      })
    end

    wake_at = next_utc_day_iso8601()

    case RuntimeStore.register_wait(running_entry.issue, %{
           reason: "daily execution budget exhausted",
           wake_at: wake_at,
           resume_hint: "Daily token budget reset; resume from the latest durable checkpoint."
         }) do
      {:ok, _wait} ->
        cancel_preempt_timer(running_entry)
        stop_running_task(Map.get(running_entry, :pid), Map.get(running_entry, :ref))
        state

      {:error, reason} ->
        Logger.warning("Unable to register daily-budget wait for issue_id=#{issue_id}: #{inspect(reason)}")
        stop_and_block_issue(state, issue_id, running_entry, "daily execution budget exhausted", :budget)
    end
  end

  defp apply_budget_evaluation(state, issue_id, running_entry, %{status: "exhausted"} = evaluation) do
    unless get_in(evaluation, [:usage, :issue, :exhausted_at]) do
      _ = RuntimeStore.mark_budget_state(issue_id, "exhausted")

      audit("budget.exhausted", "linear_issue", issue_id, %{
        outcome: "blocked",
        issue_identifier: running_entry.identifier,
        reasons: evaluation.exhausted_reasons,
        metrics: evaluation.metrics
      })
    end

    error = "configured execution budget exhausted: #{Enum.join(evaluation.exhausted_reasons, ", ")}"
    stop_and_block_issue(state, issue_id, running_entry, error, :budget)
  end

  defp apply_budget_evaluation(state, _issue_id, _running_entry, _evaluation), do: state

  defp maybe_publish_budget_warning(running_entry, evaluation) do
    body =
      budget_warning_report(
        running_entry,
        evaluation,
        reviewer_mention(Config.settings!().review.reviewer)
      )

    case Tracker.create_comment(running_entry.issue.id, body) do
      :ok ->
        Logger.warning(
          "Published non-blocking budget warning for issue_id=#{running_entry.issue.id} " <>
            "issue_identifier=#{running_entry.identifier}"
        )

      {:error, reason} ->
        Logger.warning(
          "Unable to publish non-blocking budget warning for " <>
            "issue_identifier=#{running_entry.identifier}: #{inspect(reason)}"
        )
    end

    :ok
  end

  defp budget_warning_report(running_entry, evaluation, reviewer) do
    mention = if is_binary(reviewer), do: reviewer <> "\n\n", else: ""
    detected_at = DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601()

    """
    ## Loophony Budget Warning — 작업 계속

    <!-- loophony-budget-warning:#{running_entry.identifier} -->
    #{mention}`#{running_entry.identifier}`가 설정된 실행 예산을 초과했습니다. 현재 정책은
    `budget.on_exhausted: warn`이므로 작업을 중단하지 않고 계속합니다.

    #{budget_metric_lines(evaluation.metrics)}

    - 초과 항목: #{Enum.join(evaluation.exhausted_reasons, ", ")}
    - 감지 시각: #{detected_at}

    이 경고는 audit log와 이 이슈에 한 번만 기록됩니다. 진행 상황과 토큰 사용량을
    Codex App의 Loophony 상태에서 계속 확인할 수 있습니다.
    """
    |> String.trim()
  end

  defp budget_metric_lines(metrics) do
    [
      budget_metric_line(metrics, :issue_tokens, "이슈 토큰"),
      budget_metric_line(metrics, :daily_tokens, "일일 토큰"),
      budget_metric_line(metrics, :issue_runtime_seconds, "이슈 실행 시간(초)")
    ]
    |> Enum.reject(&is_nil/1)
    |> Enum.join("\n")
  end

  defp budget_metric_line(metrics, key, label) do
    case Map.get(metrics, key) do
      %{used: used, limit: limit, percent: percent} ->
        "- #{label}: #{used} / #{limit} (#{percent}%)"

      _ ->
        nil
    end
  end

  defp next_utc_day_iso8601 do
    Date.utc_today()
    |> Date.add(1)
    |> DateTime.new!(~T[00:00:00], "Etc/UTC")
    |> DateTime.to_iso8601()
  end

  defp budget_snapshot(state) do
    settings = Config.settings!().budget

    if settings.enabled do
      enabled_budget_snapshot(state, settings)
    else
      disabled_budget_snapshot(settings)
    end
  end

  defp enabled_budget_snapshot(state, settings) do
    daily =
      case RuntimeStore.budget_usage(
             "__summary__",
             RuntimeStore,
             @snapshot_dependency_timeout_ms
           ) do
        {:ok, usage} -> usage.daily
        _ -> %{}
      end

    issues =
      state.running
      |> Enum.map(fn {issue_id, running_entry} ->
        case RuntimeStore.budget_usage(
               issue_id,
               RuntimeStore,
               @snapshot_dependency_timeout_ms
             ) do
          {:ok, usage} ->
            usage
            |> add_current_runtime(running_entry)
            |> BudgetPolicy.evaluate()
            |> Map.put(:issue_identifier, running_entry.identifier)

          _ ->
            %{
              enabled: settings.enabled,
              status: "unavailable",
              issue_identifier: running_entry.identifier
            }
        end
      end)

    %{
      enabled: settings.enabled,
      limits: budget_limits(settings),
      daily_usage: daily,
      issues: issues
    }
  end

  defp disabled_budget_snapshot(settings) do
    %{
      enabled: false,
      limits: budget_limits(settings),
      daily_usage: %{},
      issues: []
    }
  end

  defp budget_limits(settings) do
    %{
      max_tokens_per_issue: settings.max_tokens_per_issue,
      max_tokens_per_day: settings.max_tokens_per_day,
      max_active_seconds_per_issue: settings.max_active_seconds_per_issue,
      warn_at_percent: settings.warn_at_percent,
      on_exhausted: settings.on_exhausted
    }
  end

  defp audit(action, resource_type, resource_id, metadata) do
    outcome = Map.get(metadata, :outcome, "ok")

    _ =
      AuditLog.record_async(action, %{
        outcome: outcome,
        resource_type: resource_type,
        resource_id: to_string(resource_id),
        metadata: Map.delete(metadata, :outcome)
      })

    :ok
  end

  defp integer_like(value) when is_integer(value) and value >= 0, do: value

  defp integer_like(value) when is_binary(value) do
    case Integer.parse(String.trim(value)) do
      {num, _} when num >= 0 -> num
      _ -> nil
    end
  end

  defp integer_like(_value), do: nil
end
