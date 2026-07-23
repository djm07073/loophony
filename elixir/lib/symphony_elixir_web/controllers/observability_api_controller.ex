defmodule SymphonyElixirWeb.ObservabilityApiController do
  @moduledoc """
  JSON API for Symphony observability data.
  """

  use Phoenix.Controller, formats: [:json]

  alias Plug.Conn
  alias SymphonyElixir.{AuditLog, JobSupervisor, MemoryStore, OperatorInput, ReviewDecision, RuntimeStore}
  alias SymphonyElixirWeb.{Endpoint, Presenter}

  @spec state(Conn.t(), map()) :: Conn.t()
  def state(conn, _params) do
    json(conn, Presenter.state_payload(orchestrator(), snapshot_timeout_ms()))
  end

  @spec issue(Conn.t(), map()) :: Conn.t()
  def issue(conn, %{"issue_identifier" => issue_identifier}) do
    case Presenter.issue_payload(issue_identifier, orchestrator(), snapshot_timeout_ms()) do
      {:ok, payload} ->
        json(conn, payload)

      {:error, :issue_not_found} ->
        error_response(conn, 404, "issue_not_found", "Issue not found")
    end
  end

  @spec memory_status(Conn.t(), map()) :: Conn.t()
  def memory_status(conn, _params) do
    json(conn, MemoryStore.status(memory_store()))
  end

  @spec memory_search(Conn.t(), map()) :: Conn.t()
  def memory_search(conn, params) do
    query = Map.get(params, "query")

    filters = %{
      issue_identifier: Map.get(params, "issue_identifier"),
      session_id: Map.get(params, "session_id"),
      source_types: Map.get(params, "source_types"),
      from: Map.get(params, "from"),
      to: Map.get(params, "to"),
      limit: Map.get(params, "limit")
    }

    case MemoryStore.search(query || "", filters, memory_store()) do
      {:ok, payload} -> json(conn, payload)
      {:error, reason} -> memory_error(conn, reason)
    end
  end

  @spec memory_session(Conn.t(), map()) :: Conn.t()
  def memory_session(conn, %{"session_id" => session_id}) do
    case MemoryStore.get_session(session_id, memory_store()) do
      {:ok, payload} -> json(conn, payload)
      {:error, :session_not_found} -> error_response(conn, 404, "session_not_found", "Session not found")
      {:error, reason} -> memory_error(conn, reason)
    end
  end

  @spec audit_events(Conn.t(), map()) :: Conn.t()
  def audit_events(conn, params) do
    filters = Map.take(params, ["resource_type", "resource_id", "action", "outcome"])

    case AuditLog.recent(parse_limit(Map.get(params, "limit"), 100), filters, audit_log()) do
      {:ok, events} -> json(conn, %{events: events, summary: AuditLog.summary(audit_log())})
      {:error, reason} -> error_response(conn, 503, "audit_unavailable", inspect(reason))
    end
  end

  @spec audit_verify(Conn.t(), map()) :: Conn.t()
  def audit_verify(conn, _params) do
    case AuditLog.verify(audit_log()) do
      {:ok, result} -> json(conn, result)
      {:error, reason} -> error_response(conn, 503, "audit_unavailable", inspect(reason))
    end
  end

  @spec jobs(Conn.t(), map()) :: Conn.t()
  def jobs(conn, params) do
    filters = Map.take(params, ["issue_id", "status"])

    case RuntimeStore.list_jobs(filters, runtime_store()) do
      {:ok, jobs} -> json(conn, %{jobs: jobs})
      {:error, reason} -> error_response(conn, 503, "runtime_store_unavailable", inspect(reason))
    end
  end

  @spec stop_job(Conn.t(), map()) :: Conn.t()
  def stop_job(conn, %{"job_id" => job_id}) do
    if authorized_operator_request?(conn) do
      case JobSupervisor.stop_job(job_id, server: job_supervisor()) do
        {:ok, job} -> conn |> put_status(202) |> json(job)
        {:error, :job_not_found} -> error_response(conn, 404, "job_not_found", "Job not found")
        {:error, reason} -> error_response(conn, 503, "job_stop_failed", inspect(reason))
      end
    else
      error_response(conn, 403, "operator_access_denied", "Operator access denied")
    end
  end

  @spec waits(Conn.t(), map()) :: Conn.t()
  def waits(conn, _params) do
    case RuntimeStore.active_waits(runtime_store()) do
      {:ok, waits} -> json(conn, %{waits: waits})
      {:error, reason} -> error_response(conn, 503, "runtime_store_unavailable", inspect(reason))
    end
  end

  @spec refresh(Conn.t(), map()) :: Conn.t()
  def refresh(conn, _params) do
    case Presenter.refresh_payload(orchestrator()) do
      {:ok, payload} ->
        conn
        |> put_status(202)
        |> json(payload)

      {:error, :unavailable} ->
        error_response(conn, 503, "orchestrator_unavailable", "Orchestrator is unavailable")
    end
  end

  @spec operator_input(Conn.t(), map()) :: Conn.t()
  def operator_input(conn, params) do
    if authorized_operator_request?(conn) do
      case OperatorInput.submit(params,
             orchestrator: orchestrator(),
             snapshot_timeout_ms: snapshot_timeout_ms()
           ) do
        {:ok, payload} ->
          conn
          |> put_status(202)
          |> json(payload)

        {:error, reason} ->
          operator_input_error(conn, reason)
      end
    else
      error_response(conn, 403, "operator_access_denied", "Operator access denied")
    end
  end

  @spec review_decision(Conn.t(), map()) :: Conn.t()
  def review_decision(conn, params) do
    if authorized_operator_request?(conn) do
      case ReviewDecision.submit(params, orchestrator: orchestrator()) do
        {:ok, payload} ->
          conn
          |> put_status(202)
          |> json(payload)

        {:error, reason} ->
          review_decision_error(conn, reason)
      end
    else
      error_response(conn, 403, "operator_access_denied", "Operator access denied")
    end
  end

  @spec method_not_allowed(Conn.t(), map()) :: Conn.t()
  def method_not_allowed(conn, _params) do
    error_response(conn, 405, "method_not_allowed", "Method not allowed")
  end

  @spec not_found(Conn.t(), map()) :: Conn.t()
  def not_found(conn, _params) do
    error_response(conn, 404, "not_found", "Route not found")
  end

  defp error_response(conn, status, code, message) do
    conn
    |> put_status(status)
    |> json(%{error: %{code: code, message: message}})
  end

  defp authorized_operator_request?(conn) do
    Conn.get_req_header(conn, "x-loophony-control") == ["codex-app"]
  end

  defp operator_input_error(conn, :issue_not_found),
    do: error_response(conn, 404, "issue_not_found", "Issue not found")

  defp operator_input_error(conn, :orchestrator_unavailable),
    do: error_response(conn, 503, "orchestrator_unavailable", "Orchestrator is unavailable")

  defp operator_input_error(conn, {:tracker_error, _reason}),
    do: error_response(conn, 502, "tracker_write_failed", "Tracker write failed")

  defp operator_input_error(conn, reason) do
    code =
      case reason do
        :invalid_kind -> "invalid_kind"
        :invalid_message -> "invalid_message"
        :invalid_priority -> "invalid_priority"
        :invalid_request_id -> "invalid_request_id"
        :invalid_resume_state -> "invalid_resume_state"
        :invalid_title -> "invalid_title"
        :no_target_issue -> "no_target_issue"
      end

    error_response(conn, 422, code, "Invalid operator input")
  end

  defp review_decision_error(conn, :no_open_review_gate),
    do: error_response(conn, 409, "no_open_review_gate", "No scheduled review is awaiting feedback")

  defp review_decision_error(conn, :review_issue_not_found),
    do: error_response(conn, 404, "review_issue_not_found", "Review issue not found")

  defp review_decision_error(conn, :orchestrator_unavailable),
    do: error_response(conn, 503, "orchestrator_unavailable", "Orchestrator is unavailable")

  defp review_decision_error(conn, {:tracker_error, _reason}),
    do: error_response(conn, 502, "tracker_write_failed", "Tracker write failed")

  defp review_decision_error(conn, {:store_error, _reason}),
    do: error_response(conn, 503, "review_store_failed", "Review state could not be persisted")

  defp review_decision_error(conn, reason) do
    code = if reason == :invalid_decision, do: "invalid_decision", else: "feedback_required"
    error_response(conn, 422, code, "Invalid review decision")
  end

  defp memory_error(conn, :invalid_query),
    do: error_response(conn, 422, "invalid_query", "A non-empty query is required")

  defp memory_error(conn, :invalid_session_id),
    do: error_response(conn, 422, "invalid_session_id", "A non-empty session id is required")

  defp memory_error(conn, reason) do
    error_response(conn, 503, "memory_unavailable", "Loop memory is unavailable: #{inspect(reason)}")
  end

  defp orchestrator do
    Endpoint.config(:orchestrator) || SymphonyElixir.Orchestrator
  end

  defp snapshot_timeout_ms do
    Endpoint.config(:snapshot_timeout_ms) || 15_000
  end

  defp memory_store do
    Endpoint.config(:memory_store) || MemoryStore
  end

  defp audit_log do
    Endpoint.config(:audit_log) || AuditLog
  end

  defp runtime_store do
    Endpoint.config(:runtime_store) || RuntimeStore
  end

  defp job_supervisor do
    Endpoint.config(:job_supervisor) || JobSupervisor
  end

  defp parse_limit(value, default) when is_binary(value) do
    case Integer.parse(value) do
      {limit, ""} -> limit
      _ -> default
    end
  end

  defp parse_limit(value, _default) when is_integer(value), do: value
  defp parse_limit(_value, default), do: default
end
