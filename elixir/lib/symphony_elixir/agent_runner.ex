defmodule SymphonyElixir.AgentRunner do
  @moduledoc """
  Executes a single Linear issue in its workspace with Codex.
  """

  require Logger
  alias SymphonyElixir.Codex.{AppServer, DynamicTool}

  alias SymphonyElixir.{
    AuditLog,
    Config,
    Handoff,
    Linear.Issue,
    LoopStore,
    MemoryStore,
    PromptBuilder,
    RuntimeStore,
    Tracker,
    Workspace
  }

  @type worker_host :: String.t() | nil

  @doc false
  @spec continue_with_issue_for_test(Issue.t(), ([String.t()] -> term())) ::
          {:continue, Issue.t()} | {:done, Issue.t()} | {:error, term()}
  def continue_with_issue_for_test(%Issue{} = issue, issue_state_fetcher)
      when is_function(issue_state_fetcher, 1) do
    continue_with_issue?(issue, issue_state_fetcher)
  end

  @doc false
  @spec terminal_handoff_ready_for_test(Issue.t(), [Issue.t()], [map()]) :: boolean()
  def terminal_handoff_ready_for_test(%Issue{} = issue, candidates, checkpoints) do
    terminal_handoff_ready?(issue, candidates, checkpoints)
  end

  @doc false
  @spec repeated_blocker_for_test([map()]) :: map() | nil
  def repeated_blocker_for_test(checkpoints), do: repeated_blocker(checkpoints)

  @spec run(map(), pid() | nil, keyword()) :: :ok | no_return()
  def run(issue, codex_update_recipient \\ nil, opts \\ []) do
    # The orchestrator owns host retries so one worker lifetime never hops machines.
    worker_host = selected_worker_host(Keyword.get(opts, :worker_host), Config.settings!().worker.ssh_hosts)

    Logger.info("Starting agent run for #{issue_context(issue)} worker_host=#{worker_host_for_log(worker_host)}")

    case run_on_worker_host(issue, codex_update_recipient, opts, worker_host) do
      :ok ->
        :ok

      {:error, reason} ->
        Logger.error("Agent run failed for #{issue_context(issue)}: #{inspect(reason)}")
        raise RuntimeError, "Agent run failed for #{issue_context(issue)}: #{inspect(reason)}"
    end
  end

  defp run_on_worker_host(issue, codex_update_recipient, opts, worker_host) do
    Logger.info("Starting worker attempt for #{issue_context(issue)} worker_host=#{worker_host_for_log(worker_host)}")

    with {:ok, route} <- Handoff.route(issue),
         :ok <-
           Handoff.verify_session_start(
             issue,
             route,
             source_issue_fetcher: Keyword.get(opts, :source_issue_fetcher, &Tracker.fetch_issue_states_by_ids/1)
           ),
         {:ok, workspace} <- Workspace.create_for_issue(issue, worker_host) do
      send_worker_runtime_info(codex_update_recipient, issue, worker_host, workspace, route)
      audit_session_route(issue, route)

      try do
        with :ok <- Workspace.run_before_run_hook(workspace, issue, worker_host) do
          run_codex_turns(workspace, issue, codex_update_recipient, opts, worker_host, route)
        end
      after
        Workspace.run_after_run_hook(workspace, issue, worker_host)
      end
    end
  end

  defp codex_message_handler(recipient, issue) do
    fn message ->
      MemoryStore.record_codex_event(issue, message)
      send_codex_update(recipient, issue, message)
    end
  end

  defp send_codex_update(recipient, %Issue{id: issue_id}, message)
       when is_binary(issue_id) and is_pid(recipient) do
    send(recipient, {:codex_worker_update, issue_id, message})
    :ok
  end

  defp send_codex_update(_recipient, _issue, _message), do: :ok

  defp send_worker_runtime_info(recipient, %Issue{id: issue_id}, worker_host, workspace, route)
       when is_binary(issue_id) and is_pid(recipient) and is_binary(workspace) do
    send(
      recipient,
      {:worker_runtime_info, issue_id,
       %{
         worker_host: worker_host,
         workspace_path: workspace,
         model: route.model,
         session_role: route.role,
         source_issue_id: route.source_issue_id
       }}
    )

    :ok
  end

  defp send_worker_runtime_info(_recipient, _issue, _worker_host, _workspace, _route), do: :ok

  defp run_codex_turns(workspace, issue, codex_update_recipient, opts, worker_host, route) do
    max_turns = Keyword.get(opts, :max_turns, Config.settings!().agent.max_turns)
    issue_state_fetcher = Keyword.get(opts, :issue_state_fetcher, &Tracker.fetch_issue_states_by_ids/1)

    case maybe_report_repeated_blocker(issue, codex_update_recipient, opts) do
      :blocked ->
        :ok

      :ok ->
        with {:ok, session} <-
               AppServer.start_session(workspace, worker_host: worker_host, model: route.model) do
          context = %{
            app_session: session,
            workspace: workspace,
            codex_update_recipient: codex_update_recipient,
            opts: opts,
            issue_state_fetcher: issue_state_fetcher,
            max_turns: max_turns,
            route: route
          }

          try do
            do_run_codex_turns(context, issue, 1)
          after
            AppServer.stop_session(session)
          end
        end
    end
  end

  defp do_run_codex_turns(context, issue, turn_number) do
    app_session = context.app_session
    workspace = context.workspace
    codex_update_recipient = context.codex_update_recipient
    opts = context.opts
    max_turns = context.max_turns
    route = context.route
    prompt = build_turn_prompt(issue, opts, turn_number, max_turns, route)

    tool_executor =
      Keyword.get(opts, :tool_executor, fn tool, arguments, session_context ->
        DynamicTool.execute(
          tool,
          arguments,
          [issue: issue, turn_number: turn_number, workspace: workspace] ++ Map.to_list(session_context)
        )
      end)

    case AppServer.run_turn(
           app_session,
           prompt,
           issue,
           on_message: codex_message_handler(codex_update_recipient, issue),
           tool_executor: tool_executor
         ) do
      {:ok, turn_session} ->
        Logger.info("Completed agent run for #{issue_context(issue)} session_id=#{turn_session[:session_id]} workspace=#{workspace} turn=#{turn_number}/#{max_turns}")

        if LoopStore.review_gate_open?() do
          Logger.info("Stopping at the scheduled human goal-review gate after a safe Codex turn for #{issue_context(issue)}")
          :ok
        else
          continue_after_turn(context, issue, turn_number)
        end

      {:error, {:turn_preempted, request_id}} ->
        Logger.info("Stopping the current agent run after operator preemption for #{issue_context(issue)} request_id=#{request_id}; the orchestrator will start a fresh run in the preserved workspace")

        :ok

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp continue_after_turn(context, issue, turn_number) do
    if active_automated_wait?(issue.id) do
      Logger.info("Stopping Codex turns for #{issue_context(issue)} because a durable automated wait is active")
      :ok
    else
      continue_after_turn_without_wait(context, issue, turn_number)
    end
  end

  defp continue_after_turn_without_wait(context, issue, turn_number) do
    case continue_with_issue?(issue, context.issue_state_fetcher) do
      {:continue, refreshed_issue} when turn_number < context.max_turns ->
        Logger.info("Continuing agent run for #{issue_context(refreshed_issue)} after normal turn completion turn=#{turn_number}/#{context.max_turns}")

        do_run_codex_turns(context, refreshed_issue, turn_number + 1)

      {:continue, refreshed_issue} ->
        Logger.info("Reached agent.max_turns for #{issue_context(refreshed_issue)} with issue still active; returning control to orchestrator")

        maybe_report_repeated_blocker(issue, context.codex_update_recipient, context.opts)

        :ok

      {:done, refreshed_issue} ->
        if completion_state?(refreshed_issue.state) do
          guard_terminal_handoff(refreshed_issue, Map.merge(context, %{issue: issue, turn_number: turn_number}))
        else
          :ok
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp build_turn_prompt(issue, opts, 1, _max_turns, route) do
    prompt = PromptBuilder.build_prompt(issue, opts)

    prompt
    |> append_context(Handoff.prompt_context(issue, route))
    |> append_context(LoopStore.review_context())
    |> append_context(LoopStore.prompt_context(issue))
    |> append_context(runtime_prompt_context(issue.id))
  end

  defp build_turn_prompt(_issue, _opts, turn_number, max_turns, _route) do
    """
    Continuation guidance:

    - The previous Codex turn completed normally, but the Linear issue is still in an active state.
    - This is continuation turn ##{turn_number} of #{max_turns} for the current agent run.
    - Resume from the current workspace and workpad state instead of restarting from scratch.
    - The original task instructions and prior turn context are already present in this thread, so do not restate them before acting.
    - Write every new or updated Linear issue title, description, workpad entry, progress note, validation result, and handoff in Korean. Keep only exact technical identifiers, paths, commands, schema fields, status values, quotations, and machine-readable markers in their original language.
    - Before further work, refresh Linear comments on the current issue and root goal, then consume each new `## Human Input` comment exactly once. Replan immediately when its kind is `goal_adjustment`, `preempt`, or `unblock`.
    - Use `symphony_loop_checkpoint` after receiving meaningful feedback or verification. Keep checkpoint keys stable when correcting the same cycle.
    - Focus on the remaining ticket work and do not end the turn while the issue stays active unless you are truly blocked.
    """
  end

  defp append_context(prompt, ""), do: prompt
  defp append_context(prompt, context), do: prompt <> "\n\n" <> context

  defp runtime_prompt_context(issue_id) when is_binary(issue_id),
    do: RuntimeStore.prompt_context(issue_id)

  defp runtime_prompt_context(_issue_id), do: ""

  defp active_automated_wait?(issue_id) when is_binary(issue_id) do
    match?({:ok, %{}}, RuntimeStore.active_wait(issue_id))
  end

  defp active_automated_wait?(_issue_id), do: false

  defp continue_with_issue?(%Issue{id: issue_id} = issue, issue_state_fetcher) when is_binary(issue_id) do
    case issue_state_fetcher.([issue_id]) do
      {:ok, [%Issue{} = refreshed_issue | _]} ->
        if active_issue_state?(refreshed_issue.state) and issue_routable?(refreshed_issue) do
          {:continue, refreshed_issue}
        else
          {:done, refreshed_issue}
        end

      {:ok, []} ->
        {:done, issue}

      {:error, reason} ->
        {:error, {:issue_state_refresh_failed, reason}}
    end
  end

  defp continue_with_issue?(issue, _issue_state_fetcher), do: {:done, issue}

  defp maybe_report_repeated_blocker(%Issue{id: issue_id}, recipient, opts)
       when is_binary(issue_id) and is_pid(recipient) do
    checkpoint_fetcher = Keyword.get(opts, :checkpoint_fetcher, &LoopStore.recent/1)

    with {:ok, checkpoints} <- checkpoint_fetcher.(issue_id),
         %{decision: decision} <- repeated_blocker(checkpoints) do
      send(recipient, {:worker_blocked, issue_id, decision})
      :blocked
    else
      _ -> :ok
    end
  end

  defp maybe_report_repeated_blocker(_issue, _recipient, _opts), do: :ok

  defp repeated_blocker(checkpoints) when is_list(checkpoints) do
    recent = Enum.take(checkpoints, 3)
    blocker_keys = Enum.map(recent, &(Map.get(&1, :decision) |> blocker_key()))

    if length(recent) == 3 and Enum.all?(recent, &(Map.get(&1, :outcome) == "blocked")) and
         nil not in blocker_keys and length(Enum.uniq(blocker_keys)) == 1 do
      decision = recent |> List.first() |> Map.get(:decision, "repeated external blocker")
      %{decision: decision, count: 3}
    end
  end

  defp repeated_blocker(_checkpoints), do: nil

  defp blocker_key(decision) when is_binary(decision) do
    case Regex.run(~r/[A-Z][A-Z0-9_]{4,}/, decision) do
      [key] -> key
      _ -> nil
    end
  end

  defp blocker_key(_decision), do: nil

  defp guard_terminal_handoff(refreshed_issue, context) do
    issue = context.issue
    opts = context.opts
    candidate_fetcher = Keyword.get(opts, :candidate_fetcher, &Tracker.fetch_candidate_issues/0)
    checkpoint_fetcher = Keyword.get(opts, :checkpoint_fetcher, &LoopStore.recent/1)
    state_updater = Keyword.get(opts, :state_updater, &Tracker.update_issue_state/2)

    with {:ok, candidates} <- candidate_fetcher.(),
         {:ok, checkpoints} <- checkpoint_fetcher.(issue.id),
         true <- terminal_handoff_ready?(issue, candidates, checkpoints) do
      :ok
    else
      reason ->
        Logger.warning("Refusing terminal completion without verified successor handoff for #{issue_context(issue)}: #{inspect(reason)}")

        restore_incomplete_handoff(refreshed_issue, context, state_updater)
    end
  end

  defp restore_incomplete_handoff(refreshed_issue, context, state_updater) do
    with :ok <- state_updater.(context.issue.id, "In Progress") do
      continue_restored_issue(%{refreshed_issue | state: "In Progress"}, context)
    end
  end

  defp continue_restored_issue(restored_issue, %{turn_number: turn_number, max_turns: max_turns} = context)
       when turn_number < max_turns do
    do_run_codex_turns(context, restored_issue, turn_number + 1)
  end

  defp continue_restored_issue(_restored_issue, _context),
    do: {:error, :terminal_handoff_incomplete}

  defp terminal_handoff_ready?(%Issue{id: issue_id}, candidates, checkpoints)
       when is_list(candidates) and is_list(checkpoints) do
    latest_terminal_handoff =
      Enum.find(checkpoints, fn checkpoint ->
        Map.get(checkpoint, :phase) in ["learn", "handoff"] and
          Map.get(checkpoint, :outcome) in ["done", "rejected"]
      end)

    successor = verified_successor(issue_id, candidates)

    successor_verified? =
      not is_nil(successor) and terminal_checkpoint_names_successor?(latest_terminal_handoff, successor)

    explicit_termination =
      case latest_terminal_handoff do
        %{next_action: next_action} when is_binary(next_action) ->
          String.contains?(next_action, "termination_reason=")

        _ ->
          false
      end

    not is_nil(latest_terminal_handoff) and (successor_verified? or explicit_termination)
  end

  defp terminal_handoff_ready?(_issue, _candidates, _checkpoints), do: false

  defp verified_successor(issue_id, candidates) do
    handoff_enabled? = Config.settings!().handoff.enabled

    Enum.find(candidates, fn
      %Issue{id: candidate_id} = candidate when is_binary(candidate_id) and candidate_id != issue_id ->
        not handoff_enabled? or
          (todo_issue?(candidate) and valid_handoff_successor?(candidate, issue_id))

      _ ->
        false
    end)
  end

  defp valid_handoff_successor?(candidate, issue_id) do
    Handoff.successor_of?(candidate, issue_id) and match?({:ok, %{role: :executor}}, Handoff.route(candidate))
  end

  defp terminal_checkpoint_names_successor?(checkpoint, successor) do
    if Config.settings!().handoff.enabled do
      case {checkpoint, successor} do
        {%{next_action: next_action}, %Issue{id: issue_id, identifier: identifier}}
        when is_binary(next_action) ->
          (is_binary(issue_id) and String.contains?(next_action, issue_id)) or
            (is_binary(identifier) and String.contains?(next_action, identifier))

        _ ->
          false
      end
    else
      true
    end
  end

  defp todo_issue?(%Issue{state: state}) when is_binary(state) do
    normalize_issue_state(state) == "todo"
  end

  defp todo_issue?(_issue), do: false

  defp active_issue_state?(state_name) when is_binary(state_name) do
    normalized_state = normalize_issue_state(state_name)

    Config.settings!().tracker.active_states
    |> Enum.any?(fn active_state -> normalize_issue_state(active_state) == normalized_state end)
  end

  defp active_issue_state?(_state_name), do: false

  defp completion_state?(state_name) when is_binary(state_name) do
    normalize_issue_state(state_name) == "done"
  end

  defp completion_state?(_state_name), do: false

  defp issue_routable?(%Issue{} = issue) do
    Issue.routable?(issue, Config.settings!().tracker.required_labels)
  end

  defp selected_worker_host(nil, []), do: nil

  defp selected_worker_host(preferred_host, configured_hosts) when is_list(configured_hosts) do
    hosts =
      configured_hosts
      |> Enum.map(&String.trim/1)
      |> Enum.reject(&(&1 == ""))
      |> Enum.uniq()

    case preferred_host do
      host when is_binary(host) and host != "" -> host
      _ when hosts == [] -> nil
      _ -> List.first(hosts)
    end
  end

  defp worker_host_for_log(nil), do: "local"
  defp worker_host_for_log(worker_host), do: worker_host

  defp audit_session_route(issue, route) do
    _ =
      AuditLog.record_async("codex.session_routed", %{
        actor: "agent_runner",
        resource_type: "linear_issue",
        resource_id: issue.id,
        metadata: %{
          issue_identifier: issue.identifier,
          model: route.model,
          session_role: route.role,
          source_issue_id: route.source_issue_id
        }
      })

    :ok
  end

  defp normalize_issue_state(state_name) when is_binary(state_name) do
    state_name
    |> String.trim()
    |> String.downcase()
  end

  defp issue_context(%Issue{id: issue_id, identifier: identifier}) do
    "issue_id=#{issue_id} issue_identifier=#{identifier}"
  end
end
