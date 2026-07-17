defmodule SymphonyElixir.OperatorInput do
  @moduledoc """
  Persists human operator input to the managed Linear issue and wakes the orchestrator.

  Input is delivered asynchronously: a running Codex turn consumes it at its next safe
  continuation checkpoint. An explicit `unblock` input also returns the issue to a configurable
  active state so that Symphony can dispatch it again.
  """

  alias SymphonyElixir.{Orchestrator, Tracker}

  @allowed_kinds ~w(instruction goal_adjustment unblock)
  @default_resume_state "Ready"
  @max_message_bytes 10_000

  @type submit_error ::
          :invalid_kind
          | :invalid_message
          | :invalid_request_id
          | :invalid_resume_state
          | :issue_not_found
          | :no_target_issue
          | :orchestrator_unavailable
          | {:tracker_error, term()}

  @spec submit(map(), keyword()) :: {:ok, map()} | {:error, submit_error()}
  def submit(params, opts \\ []) when is_map(params) and is_list(opts) do
    tracker = Keyword.get(opts, :tracker, Tracker)
    orchestrator = Keyword.get(opts, :orchestrator, Orchestrator)
    snapshot_timeout_ms = Keyword.get(opts, :snapshot_timeout_ms, 15_000)

    with {:ok, kind} <- validate_kind(param(params, "kind")),
         {:ok, message} <- validate_message(param(params, "message")),
         {:ok, request_id} <- validate_request_id(param(params, "request_id")),
         {:ok, resume_state} <- validate_resume_state(kind, param(params, "resume_state")),
         {:ok, issue} <-
           resolve_target(
             param(params, "issue_identifier"),
             orchestrator,
             snapshot_timeout_ms,
             tracker
           ),
         :ok <- persist_comment(tracker, issue.id, format_comment(kind, message, request_id)),
         :ok <- maybe_resume_issue(tracker, issue.id, kind, resume_state) do
      refresh = Orchestrator.request_refresh(orchestrator)

      {:ok,
       %{
         accepted: true,
         request_id: request_id,
         kind: kind,
         issue_id: issue.id,
         issue_identifier: issue.identifier,
         delivery: "next_checkpoint",
         resumed_to: resume_state,
         refresh: refresh_payload(refresh)
       }}
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
      nil -> resolve_current_target(snapshot)
      identifier -> resolve_explicit_target(identifier, snapshot, tracker)
    end
  end

  defp resolve_current_target(%{} = snapshot) do
    snapshot
    |> ordered_snapshot_entries()
    |> List.first()
    |> normalize_target()
    |> case do
      nil -> {:error, :no_target_issue}
      issue -> {:ok, issue}
    end
  end

  defp resolve_current_target(_snapshot), do: {:error, :orchestrator_unavailable}

  defp resolve_explicit_target(identifier, %{} = snapshot, tracker) do
    case Enum.find(ordered_snapshot_entries(snapshot), &identifier_matches?(&1, identifier)) do
      nil ->
        resolve_with_tracker(tracker, identifier)

      entry ->
        case normalize_target(entry) do
          nil -> resolve_with_tracker(tracker, identifier)
          issue -> {:ok, issue}
        end
    end
  end

  defp resolve_explicit_target(identifier, _snapshot, tracker),
    do: resolve_with_tracker(tracker, identifier)

  defp ordered_snapshot_entries(snapshot) do
    [:running, :blocked, :queued, :retrying]
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
        %{id: id, identifier: identifier}

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
      {:ok, %{id: id, identifier: resolved_identifier}}
      when is_binary(id) and is_binary(resolved_identifier) ->
        {:ok, %{id: id, identifier: resolved_identifier}}

      {:error, :issue_not_found} ->
        {:error, :issue_not_found}

      {:error, reason} ->
        {:error, {:tracker_error, reason}}

      _ ->
        {:error, :issue_not_found}
    end
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

  defp format_comment(kind, message, request_id) do
    submitted_at = DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601()

    """
    ## Human Input

    <!-- symphony-human-input:#{request_id} -->
    - Kind: `#{kind}`
    - Source: Codex App
    - Submitted at: #{submitted_at}
    - Delivery: next safe checkpoint

    #{message}
    """
    |> String.trim()
  end

  defp generated_request_id do
    :crypto.strong_rand_bytes(16)
    |> Base.url_encode64(padding: false)
  end

  defp refresh_payload(:unavailable), do: %{queued: false, unavailable: true}
  defp refresh_payload(%{} = payload), do: payload
end
