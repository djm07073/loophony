defmodule SymphonyElixir.OperatorHandoffRecovery do
  @moduledoc """
  Repairs the narrow overlap produced when an operator Work issue completes a control transition
  but also promotes its existing successor before the scheduler can claim it.

  Normal handoffs still require a fresh Todo successor. This recovery only closes the operator
  Work issue when the durable terminal checkpoint and the successor's exact handoff marker agree.
  """

  require Logger

  alias SymphonyElixir.{AuditLog, Config, Handoff, HumanIntake, LoopStore, Tracker}
  alias SymphonyElixir.Linear.Issue

  @spec reconcile([Issue.t()], keyword()) :: {:ok, [Issue.t()]} | {:error, term()}
  def reconcile(issues, opts \\ []) when is_list(issues) and is_list(opts) do
    checkpoint_fetcher = Keyword.get(opts, :checkpoint_fetcher, &LoopStore.recent/1)

    case recovery_pair(issues, checkpoint_fetcher) do
      {:ok, source, successor, checkpoint} ->
        complete_source(issues, source, successor, checkpoint, opts)

      :none ->
        {:ok, issues}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp recovery_pair(issues, checkpoint_fetcher) do
    case Enum.filter(issues, &in_progress?/1) do
      [first, second] -> find_recovery_pair([first, second], checkpoint_fetcher)
      _ -> :none
    end
  end

  defp find_recovery_pair(in_progress, checkpoint_fetcher) do
    Enum.reduce_while(in_progress, :none, fn source, _acc ->
      case recovery_pair_for_source(source, in_progress, checkpoint_fetcher) do
        :none -> {:cont, :none}
        result -> {:halt, result}
      end
    end)
  end

  defp recovery_pair_for_source(source, in_progress, checkpoint_fetcher) do
    case matching_successor(source, in_progress) do
      %Issue{} = successor ->
        with {:ok, checkpoint} <- terminal_checkpoint(source, successor, checkpoint_fetcher) do
          {:ok, source, successor, checkpoint}
        end

      nil ->
        :none
    end
  end

  defp matching_successor(%Issue{id: source_id} = source, in_progress)
       when is_binary(source_id) do
    if HumanIntake.work_issue?(source) do
      Enum.find(in_progress, fn
        %Issue{id: successor_id} = successor when successor_id != source_id ->
          Handoff.successor_of?(successor, source_id) and
            Handoff.marker_count(successor) == 1 and
            Handoff.target_model(successor) in Config.settings!().handoff.allowed_models

        _ ->
          false
      end)
    end
  end

  defp terminal_checkpoint(source, successor, checkpoint_fetcher) do
    case checkpoint_fetcher.(source.id) do
      {:ok, checkpoints} when is_list(checkpoints) ->
        case Enum.find(checkpoints, &terminal_checkpoint?(&1, successor)) do
          nil -> :none
          checkpoint -> {:ok, checkpoint}
        end

      {:error, reason} ->
        {:error, {:operator_handoff_checkpoint_unavailable, source.identifier, reason}}

      other ->
        {:error, {:operator_handoff_checkpoint_invalid, source.identifier, other}}
    end
  end

  defp terminal_checkpoint?(checkpoint, successor) when is_map(checkpoint) do
    Map.get(checkpoint, :phase) in ["learn", "handoff"] and
      Map.get(checkpoint, :outcome) in ["done", "rejected"] and
      checkpoint_names_issue?(checkpoint, successor)
  end

  defp terminal_checkpoint?(_checkpoint, _successor), do: false

  defp checkpoint_names_issue?(%{next_action: next_action}, %Issue{} = issue)
       when is_binary(next_action) do
    Enum.any?([issue.id, issue.identifier], fn
      value when is_binary(value) -> String.contains?(next_action, value)
      _ -> false
    end)
  end

  defp checkpoint_names_issue?(_checkpoint, _issue), do: false

  defp complete_source(issues, source, successor, checkpoint, opts) do
    state_updater = Keyword.get(opts, :state_updater, &Tracker.update_issue_state/2)
    completed_state = Keyword.get(opts, :completed_state, Config.settings!().intake.completed_state)

    case state_updater.(source.id, completed_state) do
      :ok ->
        Logger.info("Recovered operator handoff overlap source=#{source.identifier} successor=#{successor.identifier}")

        audit_recovery(source, successor, checkpoint, opts)

        {:ok,
         Enum.map(issues, fn
           %Issue{id: id} = issue when id == source.id -> %{issue | state: completed_state}
           issue -> issue
         end)}

      {:error, reason} ->
        {:error, {:operator_handoff_recovery_failed, source.identifier, reason}}

      other ->
        {:error, {:operator_handoff_recovery_invalid, source.identifier, other}}
    end
  end

  defp audit_recovery(source, successor, checkpoint, opts) do
    recorder = Keyword.get(opts, :audit_recorder, &AuditLog.record_async/2)

    _ =
      recorder.("operator_handoff.overlap_recovered", %{
        actor: "orchestrator",
        resource_type: "linear_issue",
        resource_id: source.id,
        metadata: %{
          source_issue_identifier: source.identifier,
          successor_issue_id: successor.id,
          successor_issue_identifier: successor.identifier,
          checkpoint_key: Map.get(checkpoint, :checkpoint_key),
          repair: "completed_terminal_operator_work_source"
        }
      })

    :ok
  end

  defp in_progress?(%Issue{state: state}) when is_binary(state) do
    state |> String.trim() |> String.downcase() == "in progress"
  end

  defp in_progress?(_issue), do: false
end
