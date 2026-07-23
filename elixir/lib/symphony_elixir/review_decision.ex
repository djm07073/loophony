defmodule SymphonyElixir.ReviewDecision do
  @moduledoc """
  Persists a required scheduled goal-review decision and resumes orchestration.
  """

  alias SymphonyElixir.{AuditLog, Config, GoalPolicy, LoopStore, Orchestrator, Tracker}

  @decisions ~w(maintain adjust)
  @max_feedback_bytes 10_000

  @type submit_error ::
          :invalid_decision
          | :feedback_required
          | :no_open_review_gate
          | :review_issue_not_found
          | :orchestrator_unavailable
          | {:tracker_error, term()}
          | {:store_error, term()}

  @spec submit(map(), keyword()) :: {:ok, map()} | {:error, submit_error()}
  def submit(params, opts \\ []) when is_map(params) and is_list(opts) do
    tracker = Keyword.get(opts, :tracker, Tracker)
    loop_store = Keyword.get(opts, :loop_store, LoopStore)
    orchestrator = Keyword.get(opts, :orchestrator, Orchestrator)

    with {:ok, decision} <- validate_decision(param(params, "decision")),
         {:ok, feedback} <- validate_feedback(param(params, "feedback")),
         {:ok, %{status: "open"} = gate} <- current_open_gate(loop_store),
         {:ok, review_issue} <- resolve_review_issue(tracker),
         :ok <-
           persist_decision_comment(
             tracker,
             review_issue.id,
             format_comment(gate, decision, feedback)
           ),
         {:ok, resolved_gate} <- resolve_gate(loop_store, decision, feedback),
         {:ok, resume} <- resume_orchestrator(orchestrator) do
      _ =
        AuditLog.record_async("goal_review.decided", %{
          actor: "human",
          resource_type: "review_gate",
          resource_id: gate.window_key,
          metadata: %{
            decision: decision,
            review_issue_identifier: review_issue.identifier,
            goal_version: GoalPolicy.extract_goal_version(feedback)
          }
        })

      {:ok,
       %{
         accepted: true,
         decision: decision,
         feedback: feedback,
         review_issue_identifier: review_issue.identifier,
         gate: resolved_gate,
         resume: resume
       }}
    end
  end

  defp param(params, name), do: Map.get(params, name) || Map.get(params, String.to_atom(name))

  defp validate_decision(decision) when decision in @decisions, do: {:ok, decision}
  defp validate_decision(_decision), do: {:error, :invalid_decision}

  defp validate_feedback(feedback) when is_binary(feedback) do
    feedback = String.trim(feedback)

    if feedback != "" and byte_size(feedback) <= @max_feedback_bytes,
      do: {:ok, feedback},
      else: {:error, :feedback_required}
  end

  defp validate_feedback(_feedback), do: {:error, :feedback_required}

  defp current_open_gate(loop_store) do
    case loop_store.current_review_gate() do
      {:ok, %{status: "open"} = gate} -> {:ok, gate}
      {:ok, _gate} -> {:error, :no_open_review_gate}
      {:error, reason} -> {:error, {:store_error, reason}}
    end
  end

  defp resolve_review_issue(tracker) do
    identifier = Config.settings!().review.issue_identifier

    case tracker.resolve_issue(identifier) do
      {:ok, %{id: id, identifier: resolved_identifier}}
      when is_binary(id) and is_binary(resolved_identifier) ->
        {:ok, %{id: id, identifier: resolved_identifier}}

      {:error, :issue_not_found} ->
        {:error, :review_issue_not_found}

      {:error, reason} ->
        {:error, {:tracker_error, reason}}

      _ ->
        {:error, :review_issue_not_found}
    end
  end

  defp persist_decision_comment(tracker, issue_id, body) do
    case tracker.create_comment(issue_id, body) do
      :ok -> :ok
      {:error, reason} -> {:error, {:tracker_error, reason}}
      other -> {:error, {:tracker_error, other}}
    end
  end

  defp resolve_gate(loop_store, decision, feedback) do
    case loop_store.resolve_review_gate(decision, feedback) do
      {:ok, gate} -> {:ok, gate}
      {:error, reason} -> {:error, {:store_error, reason}}
    end
  end

  defp resume_orchestrator(orchestrator) do
    case Orchestrator.resume_after_review(orchestrator) do
      :unavailable -> {:error, :orchestrator_unavailable}
      %{} = payload -> {:ok, payload}
    end
  end

  defp format_comment(gate, decision, feedback) do
    submitted_at = DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601()

    """
    ## 목표 검토 결정

    <!-- symphony-goal-review-decision:#{gate.window_key} -->
    - 결정: `#{decision}`
    - 출처: Codex App
    - 제출 시각: #{submitted_at}

    #{feedback}
    """
    |> String.trim()
  end
end
