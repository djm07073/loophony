defmodule SymphonyElixir.OperatorInput do
  @moduledoc """
  Persists human operator input to Linear and wakes the orchestrator.

  With Human intake enabled, feedback becomes a prioritized `[Human]` issue and is later
  materialized as a linked `[Work]` issue. Ordinary feedback does not disturb current execution.
  An explicit `preempt` input returns the source issue to Todo and cooperatively interrupts the
  current Codex turn; an explicit `unblock` input returns the named source issue to a configurable
  active state.
  """

  alias SymphonyElixir.{AuditLog, Config, HumanIntake, Orchestrator, RuntimeStore, Tracker}

  @allowed_kinds ~w(instruction goal_adjustment preempt unblock)
  @default_resume_state "Ready"
  @max_message_bytes 10_000

  @type submit_error ::
          :invalid_kind
          | :invalid_message
          | :invalid_priority
          | :invalid_request_id
          | :invalid_resume_state
          | :invalid_title
          | :issue_not_found
          | :no_target_issue
          | :orchestrator_unavailable
          | {:tracker_error, term()}

  @spec submit(map(), keyword()) :: {:ok, map()} | {:error, submit_error()}
  def submit(params, opts \\ []) when is_map(params) and is_list(opts) do
    tracker = Keyword.get(opts, :tracker, Tracker)
    orchestrator = Keyword.get(opts, :orchestrator, Orchestrator)
    snapshot_timeout_ms = Keyword.get(opts, :snapshot_timeout_ms, 15_000)
    runtime_store = Keyword.get(opts, :runtime_store, RuntimeStore)

    with {:ok, kind} <- validate_kind(param(params, "kind")),
         {:ok, message} <- validate_message(param(params, "message")),
         {:ok, title} <- validate_optional_title(param(params, "title")),
         {:ok, priority} <- validate_priority(param(params, "priority")),
         {:ok, request_id} <- validate_request_id(param(params, "request_id")),
         {:ok, resume_state} <- validate_resume_state(kind, param(params, "resume_state")),
         {:ok, issue} <-
           resolve_target(
             param(params, "issue_identifier"),
             orchestrator,
             snapshot_timeout_ms,
             tracker
           ) do
      feedback = %{
        kind: kind,
        message: message,
        title: title,
        priority: priority,
        request_id: request_id
      }

      if intake_enabled?() do
        submit_as_human_issue(
          feedback,
          issue,
          resume_state,
          tracker,
          orchestrator,
          runtime_store
        )
      else
        submit_legacy_input(
          feedback,
          issue,
          resume_state,
          tracker,
          orchestrator,
          runtime_store
        )
      end
    end
  end

  defp param(params, name), do: Map.get(params, name) || Map.get(params, String.to_atom(name))

  defp validate_kind(kind) when kind in @allowed_kinds, do: {:ok, kind}
  defp validate_kind(_kind), do: {:error, :invalid_kind}

  defp validate_message(message) when is_binary(message) do
    message = String.trim(message)

    if message != "" and byte_size(message) <= @max_message_bytes do
      {:ok, message}
    else
      {:error, :invalid_message}
    end
  end

  defp validate_message(_message), do: {:error, :invalid_message}

  defp validate_optional_title(nil), do: {:ok, nil}

  defp validate_optional_title(title) when is_binary(title) do
    case String.trim(title) do
      "" -> {:error, :invalid_title}
      normalized when byte_size(normalized) <= 200 -> {:ok, normalized}
      _ -> {:error, :invalid_title}
    end
  end

  defp validate_optional_title(_title), do: {:error, :invalid_title}

  defp validate_priority(nil), do: {:ok, nil}
  defp validate_priority(priority) when is_integer(priority) and priority in 0..4, do: {:ok, priority}
  defp validate_priority(_priority), do: {:error, :invalid_priority}

  defp validate_request_id(nil), do: {:ok, generated_request_id()}

  defp validate_request_id(request_id) when is_binary(request_id) do
    request_id = String.trim(request_id)

    if request_id != "" and byte_size(request_id) <= 128 and
         Regex.match?(~r/\A[a-zA-Z0-9._:-]+\z/, request_id) do
      {:ok, request_id}
    else
      {:error, :invalid_request_id}
    end
  end

  defp validate_request_id(_request_id), do: {:error, :invalid_request_id}

  defp validate_resume_state("unblock", nil), do: {:ok, @default_resume_state}

  defp validate_resume_state("unblock", resume_state) when is_binary(resume_state) do
    resume_state = String.trim(resume_state)

    if resume_state != "" and byte_size(resume_state) <= 120 do
      {:ok, resume_state}
    else
      {:error, :invalid_resume_state}
    end
  end

  defp validate_resume_state("unblock", _resume_state), do: {:error, :invalid_resume_state}
  defp validate_resume_state(_kind, _resume_state), do: {:ok, nil}

  defp resolve_target(issue_identifier, orchestrator, snapshot_timeout_ms, tracker) do
    snapshot = Orchestrator.snapshot(orchestrator, snapshot_timeout_ms)

    case normalize_optional_identifier(issue_identifier) do
      nil -> resolve_current_target(snapshot, tracker)
      identifier -> resolve_explicit_target(identifier, snapshot, tracker)
    end
  end

  defp resolve_current_target(%{} = snapshot, tracker) do
    snapshot
    |> ordered_snapshot_entries()
    |> List.first()
    |> normalize_target()
    |> case do
      nil -> {:error, :no_target_issue}
      issue -> enrich_target(issue, tracker)
    end
  end

  defp resolve_current_target(_snapshot, _tracker), do: {:error, :orchestrator_unavailable}

  defp resolve_explicit_target(identifier, %{} = snapshot, tracker) do
    snapshot_target =
      snapshot
      |> ordered_snapshot_entries()
      |> Enum.find(&identifier_matches?(&1, identifier))
      |> normalize_target()

    resolve_explicit_with_fallback(tracker, identifier, snapshot_target)
  end

  defp resolve_explicit_target(identifier, _snapshot, tracker),
    do: resolve_with_tracker(tracker, identifier)

  defp ordered_snapshot_entries(snapshot) do
    [:running, :blocked, :waiting, :queued, :retrying]
    |> Enum.flat_map(&Map.get(snapshot, &1, []))
  end

  defp identifier_matches?(entry, identifier) when is_map(entry) do
    case entry_identifier(entry) do
      current when is_binary(current) -> String.downcase(current) == String.downcase(identifier)
      _ -> false
    end
  end

  defp identifier_matches?(_entry, _identifier), do: false

  defp normalize_target(entry) when is_map(entry) do
    case {entry_issue_id(entry), entry_identifier(entry)} do
      {id, identifier} when is_binary(id) and is_binary(identifier) ->
        %{
          id: id,
          identifier: identifier,
          title: target_value(entry, :title),
          description: target_value(entry, :description),
          project_description: target_value(entry, :project_description),
          url: target_value(entry, :url)
        }

      _ ->
        nil
    end
  end

  defp normalize_target(_entry), do: nil

  defp entry_issue_id(entry), do: Map.get(entry, :issue_id) || Map.get(entry, "issue_id") || Map.get(entry, :id)

  defp entry_identifier(entry) do
    Map.get(entry, :identifier) || Map.get(entry, "identifier") ||
      Map.get(entry, :issue_identifier) || Map.get(entry, "issue_identifier")
  end

  defp target_value(entry, key), do: Map.get(entry, key) || Map.get(entry, Atom.to_string(key))

  defp normalize_optional_identifier(nil), do: nil

  defp normalize_optional_identifier(identifier) when is_binary(identifier) do
    case String.trim(identifier) do
      "" -> nil
      normalized -> normalized
    end
  end

  defp normalize_optional_identifier(_identifier), do: nil

  defp resolve_with_tracker(tracker, identifier) do
    case tracker.resolve_issue(identifier) do
      {:ok, issue} when is_map(issue) ->
        case normalize_target(issue) do
          nil -> {:error, :issue_not_found}
          target -> {:ok, target}
        end

      {:error, :issue_not_found} ->
        {:error, :issue_not_found}

      {:error, reason} ->
        {:error, {:tracker_error, reason}}

      _ ->
        {:error, :issue_not_found}
    end
  end

  defp enrich_target(target, tracker) do
    case resolve_with_tracker(tracker, target.identifier) do
      {:ok, resolved} -> {:ok, merge_targets(target, resolved)}
      _error -> {:ok, target}
    end
  end

  defp resolve_explicit_with_fallback(tracker, identifier, snapshot_target) do
    case resolve_with_tracker(tracker, identifier) do
      {:ok, resolved} -> {:ok, merge_targets(snapshot_target, resolved)}
      {:error, _reason} = error when is_nil(snapshot_target) -> error
      {:error, _reason} -> {:ok, snapshot_target}
    end
  end

  defp merge_targets(nil, resolved), do: resolved

  defp merge_targets(snapshot_target, resolved) do
    Map.merge(snapshot_target, resolved, fn _key, snapshot_value, resolved_value ->
      resolved_value || snapshot_value
    end)
  end

  defp persist_comment(tracker, issue_id, body) do
    case tracker.create_comment(issue_id, body) do
      :ok -> :ok
      {:error, reason} -> {:error, {:tracker_error, reason}}
      other -> {:error, {:tracker_error, other}}
    end
  end

  defp maybe_resume_issue(_tracker, _issue_id, kind, _resume_state) when kind != "unblock", do: :ok

  defp maybe_resume_issue(tracker, issue_id, "unblock", resume_state) do
    case tracker.update_issue_state(issue_id, resume_state) do
      :ok -> :ok
      {:error, reason} -> {:error, {:tracker_error, reason}}
      other -> {:error, {:tracker_error, other}}
    end
  end

  defp maybe_release_runtime_block(_orchestrator, _issue_id, kind) when kind != "unblock", do: nil

  defp maybe_release_runtime_block(orchestrator, issue_id, "unblock") do
    Orchestrator.resume_issue(issue_id, orchestrator)
  end

  defp maybe_preempt_issue(_orchestrator, _issue_id, kind, _request_id) when kind != "preempt",
    do: nil

  defp maybe_preempt_issue(orchestrator, issue_id, "preempt", request_id) do
    Orchestrator.preempt_issue(issue_id, request_id, orchestrator)
  end

  defp maybe_release_automated_wait(_runtime_store, _issue_id, kind)
       when kind not in ["goal_adjustment", "preempt", "unblock"],
       do: nil

  defp maybe_release_automated_wait(runtime_store, issue_id, _kind) do
    case RuntimeStore.active_wait(issue_id, runtime_store) do
      {:ok, %{wait_id: wait_id}} ->
        case RuntimeStore.release_wait(wait_id, "operator_input", runtime_store) do
          {:ok, _wait} -> %{released: true, wait_id: wait_id}
          {:error, reason} -> %{released: false, error: inspect(reason)}
        end

      {:ok, nil} ->
        %{released: false}

      {:error, reason} ->
        %{released: false, error: inspect(reason)}
    end
  end

  defp submit_as_human_issue(
         feedback,
         source_issue,
         resume_state,
         tracker,
         orchestrator,
         runtime_store
       ) do
    with {:ok, human_issue} <-
           create_human_feedback_issue(feedback, source_issue, tracker),
         :ok <- maybe_resume_issue(tracker, source_issue.id, feedback.kind, resume_state),
         {:ok, paused_to} <- maybe_pause_issue(tracker, source_issue.id, feedback.kind) do
      controls = apply_runtime_controls(feedback, source_issue, orchestrator, runtime_store)
      refresh = Orchestrator.request_refresh(orchestrator)

      _ =
        AuditLog.record_async("operator.input_accepted", %{
          actor: "human",
          resource_type: "linear_issue",
          resource_id: human_issue.id,
          metadata: %{
            issue_identifier: human_issue.identifier,
            source_issue_id: source_issue.id,
            source_issue_identifier: source_issue.identifier,
            request_id: feedback.request_id,
            kind: feedback.kind,
            priority: human_issue.priority,
            resumed_to: resume_state,
            paused_to: paused_to,
            automated_wait_released: controls.automated_wait
          }
        })

      {:ok,
       %{
         accepted: true,
         request_id: feedback.request_id,
         kind: feedback.kind,
         issue_id: source_issue.id,
         issue_identifier: source_issue.identifier,
         human_issue: human_issue_payload(human_issue),
         delivery: intake_delivery(feedback.kind, controls.preemption),
         resumed_to: resume_state,
         paused_to: paused_to,
         runtime_block: controls.resume,
         automated_wait: controls.automated_wait,
         preemption: controls.preemption,
         refresh: refresh_payload(refresh)
       }}
    end
  end

  defp submit_legacy_input(
         feedback,
         issue,
         resume_state,
         tracker,
         orchestrator,
         runtime_store
       ) do
    with :ok <-
           persist_comment(
             tracker,
             issue.id,
             format_comment(feedback.kind, feedback.message, feedback.request_id)
           ),
         :ok <- maybe_resume_issue(tracker, issue.id, feedback.kind, resume_state) do
      controls = apply_runtime_controls(feedback, issue, orchestrator, runtime_store)
      refresh = Orchestrator.request_refresh(orchestrator)

      _ =
        AuditLog.record_async("operator.input_accepted", %{
          actor: "human",
          resource_type: "linear_issue",
          resource_id: issue.id,
          metadata: %{
            issue_identifier: issue.identifier,
            request_id: feedback.request_id,
            kind: feedback.kind,
            resumed_to: resume_state,
            automated_wait_released: controls.automated_wait
          }
        })

      {:ok,
       %{
         accepted: true,
         request_id: feedback.request_id,
         kind: feedback.kind,
         issue_id: issue.id,
         issue_identifier: issue.identifier,
         delivery: input_delivery(feedback.kind, controls.preemption),
         resumed_to: resume_state,
         runtime_block: controls.resume,
         automated_wait: controls.automated_wait,
         preemption: controls.preemption,
         refresh: refresh_payload(refresh)
       }}
    end
  end

  defp apply_runtime_controls(feedback, issue, orchestrator, runtime_store) do
    %{
      resume: maybe_release_runtime_block(orchestrator, issue.id, feedback.kind),
      automated_wait: maybe_release_automated_wait(runtime_store, issue.id, feedback.kind),
      preemption: maybe_preempt_issue(orchestrator, issue.id, feedback.kind, feedback.request_id)
    }
  end

  defp human_issue_payload(issue) do
    %{
      id: issue.id,
      identifier: issue.identifier,
      title: issue.title,
      state: issue.state,
      priority: issue.priority,
      url: issue.url
    }
  end

  defp intake_delivery("preempt", preemption), do: input_delivery("preempt", preemption)
  defp intake_delivery(_kind, _preemption), do: "priority_queue"

  defp intake_enabled? do
    Config.settings!().intake.enabled
  rescue
    _error -> false
  end

  defp create_human_feedback_issue(feedback, source_issue, tracker) do
    case HumanIntake.create_human_issue(feedback, source_issue, tracker: tracker) do
      {:ok, issue} -> {:ok, issue}
      {:error, reason} -> {:error, {:tracker_error, reason}}
    end
  end

  defp maybe_pause_issue(_tracker, _issue_id, kind) when kind != "preempt", do: {:ok, nil}

  defp maybe_pause_issue(tracker, issue_id, "preempt") do
    paused_state = Config.settings!().intake.todo_state

    case tracker.update_issue_state(issue_id, paused_state) do
      :ok -> {:ok, paused_state}
      {:error, reason} -> {:error, {:tracker_error, reason}}
      other -> {:error, {:tracker_error, other}}
    end
  end

  defp input_delivery("preempt", %{delivery: delivery}) when is_binary(delivery), do: delivery
  defp input_delivery("preempt", _preemption), do: "turn_interrupt"
  defp input_delivery(_kind, _preemption), do: "next_checkpoint"

  defp format_comment(kind, message, request_id) do
    submitted_at = DateTime.utc_now() |> DateTime.truncate(:second)
    submitted_at_utc = DateTime.to_iso8601(submitted_at)

    submitted_at_kst =
      submitted_at
      |> DateTime.add(9, :hour)
      |> Calendar.strftime("%Y-%m-%dT%H:%M:%S+09:00")

    """
    ## Human Input

    <!-- symphony-human-input:#{request_id} -->
    - 유형: `#{kind}`
    - 출처: Codex App
    - 제출 시각 (UTC): #{submitted_at_utc}
    - 제출 시각 (KST): #{submitted_at_kst}
    - 전달 시점: #{comment_delivery(kind)}

    #{message}
    """
    |> String.trim()
  end

  defp comment_delivery("preempt"), do: "현재 Codex turn 중단 후 보존된 workspace에서 새 실행"
  defp comment_delivery(_kind), do: "다음 안전 checkpoint"

  defp generated_request_id do
    :crypto.strong_rand_bytes(16)
    |> Base.url_encode64(padding: false)
  end

  defp refresh_payload(:unavailable), do: %{queued: false, unavailable: true}
  defp refresh_payload(%{} = payload), do: payload
end
