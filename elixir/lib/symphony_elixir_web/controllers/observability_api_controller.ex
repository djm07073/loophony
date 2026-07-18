defmodule SymphonyElixirWeb.ObservabilityApiController do
  @moduledoc """
  JSON API for Symphony observability data.
  """

  use Phoenix.Controller, formats: [:json]

  alias Plug.Conn
  alias SymphonyElixir.{OperatorInput, ReviewDecision}
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
        :invalid_request_id -> "invalid_request_id"
        :invalid_resume_state -> "invalid_resume_state"
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

  defp orchestrator do
    Endpoint.config(:orchestrator) || SymphonyElixir.Orchestrator
  end

  defp snapshot_timeout_ms do
    Endpoint.config(:snapshot_timeout_ms) || 15_000
  end
end
