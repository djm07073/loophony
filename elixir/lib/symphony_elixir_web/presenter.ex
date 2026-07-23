defmodule SymphonyElixirWeb.Presenter do
  @moduledoc """
  Shared projections for the observability API and dashboard.
  """

  alias SymphonyElixir.{Config, Orchestrator, StatusDashboard}

  @spec state_payload(GenServer.name(), timeout()) :: map()
  def state_payload(orchestrator, snapshot_timeout_ms) do
    generated_at = DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601()

    case Orchestrator.snapshot(orchestrator, snapshot_timeout_ms) do
      %{} = snapshot ->
        %{
          generated_at: generated_at,
          counts: %{
            running: length(snapshot.running),
            queued: length(Map.get(snapshot, :queued, [])),
            retrying: length(snapshot.retrying),
            blocked: length(Map.get(snapshot, :blocked, [])),
            waiting: length(Map.get(snapshot, :waiting, []))
          },
          running: Enum.map(snapshot.running, &running_entry_payload/1),
          queued: Enum.map(Map.get(snapshot, :queued, []), &queued_entry_payload/1),
          retrying: Enum.map(snapshot.retrying, &retry_entry_payload/1),
          blocked: Enum.map(Map.get(snapshot, :blocked, []), &blocked_entry_payload/1),
          waiting: Map.get(snapshot, :waiting, []),
          jobs: Map.get(snapshot, :jobs, []),
          loop: Map.get(snapshot, :loop),
          review_gate: Map.get(snapshot, :review_gate),
          goal_policy: Map.get(snapshot, :goal_policy),
          intake: Map.get(snapshot, :intake),
          runtime: Map.get(snapshot, :runtime),
          budget: Map.get(snapshot, :budget),
          memory: Map.get(snapshot, :memory),
          audit: Map.get(snapshot, :audit),
          codex_totals: snapshot.codex_totals,
          rate_limits: snapshot.rate_limits,
          polling: polling_payload(Map.get(snapshot, :polling))
        }

      :timeout ->
        %{generated_at: generated_at, error: %{code: "snapshot_timeout", message: "Snapshot timed out"}}

      :unavailable ->
        %{generated_at: generated_at, error: %{code: "snapshot_unavailable", message: "Snapshot unavailable"}}
    end
  end

  @spec issue_payload(String.t(), GenServer.name(), timeout()) :: {:ok, map()} | {:error, :issue_not_found}
  def issue_payload(issue_identifier, orchestrator, snapshot_timeout_ms) when is_binary(issue_identifier) do
    case Orchestrator.snapshot(orchestrator, snapshot_timeout_ms) do
      %{} = snapshot ->
        entries = issue_entries(snapshot, issue_identifier)

        if Enum.all?(Map.values(entries), &is_nil/1) do
          {:error, :issue_not_found}
        else
          {:ok, issue_payload_body(issue_identifier, entries, snapshot)}
        end

      _ ->
        {:error, :issue_not_found}
    end
  end

  @spec refresh_payload(GenServer.name()) :: {:ok, map()} | {:error, :unavailable}
  def refresh_payload(orchestrator) do
    case Orchestrator.request_refresh(orchestrator) do
      :unavailable ->
        {:error, :unavailable}

      payload ->
        {:ok, Map.update!(payload, :requested_at, &DateTime.to_iso8601/1)}
    end
  end

  defp issue_payload_body(issue_identifier, entries, snapshot) do
    %{running: running, queued: queued, retry: retry, blocked: blocked, waiting: waiting} = entries

    %{
      issue_identifier: issue_identifier,
      issue_id: issue_id_from_entries(entries),
      status: issue_status(running, queued, retry, blocked, waiting),
      workspace: %{
        path: workspace_path(issue_identifier, running, retry, blocked),
        host: workspace_host(running, retry, blocked)
      },
      attempts: %{
        restart_count: restart_count(retry),
        current_retry_attempt: retry_attempt(retry)
      },
      running: running && running_issue_payload(running),
      queue: queued && queued_issue_payload(queued),
      retry: retry && retry_issue_payload(retry),
      blocked: blocked && blocked_issue_payload(blocked),
      waiting: waiting,
      loop: issue_loop_payload(Map.get(snapshot, :loop), issue_identifier),
      review_gate: Map.get(snapshot, :review_gate),
      goal_policy: Map.get(snapshot, :goal_policy),
      intake: Map.get(snapshot, :intake),
      budget: issue_budget_payload(Map.get(snapshot, :budget), issue_identifier),
      logs: %{
        codex_session_logs: []
      },
      recent_events: recent_events_payload(running || blocked),
      last_error: (blocked && blocked.error) || (retry && retry.error),
      tracked: %{}
    }
  end

  defp issue_entries(snapshot, issue_identifier) do
    %{
      running: Enum.find(snapshot.running, &(&1.identifier == issue_identifier)),
      queued: Enum.find(Map.get(snapshot, :queued, []), &(&1.identifier == issue_identifier)),
      retry: Enum.find(snapshot.retrying, &(&1.identifier == issue_identifier)),
      blocked: Enum.find(Map.get(snapshot, :blocked, []), &(&1.identifier == issue_identifier)),
      waiting: Enum.find(Map.get(snapshot, :waiting, []), &(&1.issue_identifier == issue_identifier))
    }
  end

  defp issue_id_from_entries(entries) do
    [entries.running, entries.queued, entries.retry, entries.blocked, entries.waiting]
    |> Enum.find_value(&(&1 && &1.issue_id))
  end

  defp restart_count(retry), do: max(retry_attempt(retry) - 1, 0)
  defp retry_attempt(nil), do: 0
  defp retry_attempt(retry), do: retry.attempt || 0

  defp issue_status(running, _queued, _retry, _blocked, _waiting) when not is_nil(running), do: "running"
  defp issue_status(nil, queued, _retry, _blocked, _waiting) when not is_nil(queued), do: "queued"
  defp issue_status(nil, nil, retry, _blocked, _waiting) when not is_nil(retry), do: "retrying"
  defp issue_status(nil, nil, nil, blocked, _waiting) when not is_nil(blocked), do: "blocked"
  defp issue_status(nil, nil, nil, nil, _waiting), do: "waiting"

  defp running_entry_payload(entry) do
    %{
      issue_id: entry.issue_id,
      issue_identifier: entry.identifier,
      issue_url: Map.get(entry, :issue_url),
      run_id: Map.get(entry, :run_id),
      state: entry.state,
      worker_host: Map.get(entry, :worker_host),
      workspace_path: Map.get(entry, :workspace_path),
      session_id: entry.session_id,
      turn_count: Map.get(entry, :turn_count, 0),
      last_event: entry.last_codex_event,
      last_message: summarize_message(entry.last_codex_message),
      started_at: iso8601(entry.started_at),
      last_event_at: iso8601(entry.last_codex_timestamp),
      tokens: %{
        input_tokens: entry.codex_input_tokens,
        output_tokens: entry.codex_output_tokens,
        total_tokens: entry.codex_total_tokens
      }
    }
    |> maybe_put_preemption(Map.get(entry, :preemption))
  end

  defp retry_entry_payload(entry) do
    %{
      issue_id: entry.issue_id,
      issue_identifier: entry.identifier,
      issue_url: Map.get(entry, :issue_url),
      attempt: entry.attempt,
      due_at: due_at_iso8601(entry.due_in_ms),
      error: entry.error,
      worker_host: Map.get(entry, :worker_host),
      workspace_path: Map.get(entry, :workspace_path)
    }
  end

  defp queued_entry_payload(entry) do
    %{
      issue_id: entry.issue_id,
      issue_identifier: entry.identifier,
      issue_url: Map.get(entry, :issue_url),
      state: entry.state,
      priority: Map.get(entry, :priority),
      created_at: iso8601(Map.get(entry, :created_at))
    }
  end

  defp blocked_entry_payload(entry) do
    %{
      issue_id: entry.issue_id,
      issue_identifier: entry.identifier,
      issue_url: Map.get(entry, :issue_url),
      state: entry.state,
      error: entry.error,
      worker_host: Map.get(entry, :worker_host),
      workspace_path: Map.get(entry, :workspace_path),
      session_id: entry.session_id,
      blocked_at: iso8601(entry.blocked_at),
      last_event: entry.last_codex_event,
      last_message: summarize_message(entry.last_codex_message),
      last_event_at: iso8601(entry.last_codex_timestamp),
      block_type: Map.get(entry, :block_type)
    }
  end

  defp running_issue_payload(running) do
    %{
      worker_host: Map.get(running, :worker_host),
      workspace_path: Map.get(running, :workspace_path),
      session_id: running.session_id,
      turn_count: Map.get(running, :turn_count, 0),
      state: running.state,
      started_at: iso8601(running.started_at),
      last_event: running.last_codex_event,
      last_message: summarize_message(running.last_codex_message),
      last_event_at: iso8601(running.last_codex_timestamp),
      tokens: %{
        input_tokens: running.codex_input_tokens,
        output_tokens: running.codex_output_tokens,
        total_tokens: running.codex_total_tokens
      }
    }
    |> maybe_put_preemption(Map.get(running, :preemption))
  end

  defp retry_issue_payload(retry) do
    %{
      attempt: retry.attempt,
      due_at: due_at_iso8601(retry.due_in_ms),
      error: retry.error,
      worker_host: Map.get(retry, :worker_host),
      workspace_path: Map.get(retry, :workspace_path)
    }
  end

  defp queued_issue_payload(queued) do
    %{
      state: queued.state,
      priority: Map.get(queued, :priority),
      created_at: iso8601(Map.get(queued, :created_at))
    }
  end

  defp blocked_issue_payload(blocked) do
    %{
      worker_host: Map.get(blocked, :worker_host),
      workspace_path: Map.get(blocked, :workspace_path),
      session_id: blocked.session_id,
      state: blocked.state,
      error: blocked.error,
      blocked_at: iso8601(blocked.blocked_at),
      last_event: blocked.last_codex_event,
      last_message: summarize_message(blocked.last_codex_message),
      last_event_at: iso8601(blocked.last_codex_timestamp),
      block_type: Map.get(blocked, :block_type)
    }
  end

  defp issue_budget_payload(%{issues: issues}, issue_identifier) when is_list(issues) do
    Enum.find(issues, &(Map.get(&1, :issue_identifier) == issue_identifier))
  end

  defp issue_budget_payload(_budget, _issue_identifier), do: nil

  defp workspace_path(issue_identifier, running, retry, blocked) do
    (running && Map.get(running, :workspace_path)) ||
      (retry && Map.get(retry, :workspace_path)) ||
      (blocked && Map.get(blocked, :workspace_path)) ||
      Path.join(Config.settings!().workspace.root, issue_identifier)
  end

  defp workspace_host(running, retry, blocked) do
    (running && Map.get(running, :worker_host)) ||
      (retry && Map.get(retry, :worker_host)) ||
      (blocked && Map.get(blocked, :worker_host))
  end

  defp recent_events_payload(nil), do: []

  defp recent_events_payload(entry) do
    [
      %{
        at: iso8601(entry.last_codex_timestamp),
        event: entry.last_codex_event,
        message: summarize_message(entry.last_codex_message)
      }
    ]
    |> Enum.reject(&is_nil(&1.at))
  end

  defp preemption_payload(nil), do: nil

  defp preemption_payload(preemption) when is_map(preemption) do
    Map.update(preemption, :requested_at, nil, &iso8601/1)
  end

  defp maybe_put_preemption(payload, nil), do: payload

  defp maybe_put_preemption(payload, preemption) do
    Map.put(payload, :preemption, preemption_payload(preemption))
  end

  defp summarize_message(nil), do: nil
  defp summarize_message(message), do: StatusDashboard.humanize_codex_message(message)

  defp due_at_iso8601(due_in_ms) when is_integer(due_in_ms) do
    DateTime.utc_now()
    |> DateTime.add(div(due_in_ms, 1_000), :second)
    |> DateTime.truncate(:second)
    |> DateTime.to_iso8601()
  end

  defp due_at_iso8601(_due_in_ms), do: nil

  defp polling_payload(nil), do: nil

  defp polling_payload(polling) when is_map(polling) do
    %{
      checking: Map.get(polling, :checking?, false),
      next_poll_in_ms: Map.get(polling, :next_poll_in_ms),
      poll_interval_ms: Map.get(polling, :poll_interval_ms)
    }
  end

  defp issue_loop_payload(%{recent: recent}, issue_identifier) when is_list(recent) do
    %{
      recent:
        Enum.filter(recent, fn checkpoint ->
          (Map.get(checkpoint, :issue_identifier) || Map.get(checkpoint, "issue_identifier")) ==
            issue_identifier
        end)
    }
  end

  defp issue_loop_payload(_loop, _issue_identifier), do: %{recent: []}

  defp iso8601(%DateTime{} = datetime) do
    datetime
    |> DateTime.truncate(:second)
    |> DateTime.to_iso8601()
  end

  defp iso8601(_datetime), do: nil
end
