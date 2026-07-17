defmodule SymphonyElixir.ReviewDecisionTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.ReviewDecision

  defmodule TestStore do
    def current_review_gate do
      Process.get(:review_gate_result, {:ok, nil})
    end

    def resolve_review_gate(decision, feedback) do
      send(self(), {:resolve_review_gate, decision, feedback})
      Process.get(:review_resolve_result, {:error, :unexpected})
    end
  end

  defmodule TestTracker do
    def resolve_issue(identifier) do
      send(self(), {:resolve_review_issue, identifier})
      Process.get(:review_issue_result, {:error, :issue_not_found})
    end

    def create_comment(issue_id, body) do
      send(self(), {:review_comment, issue_id, body})
      Process.get(:review_comment_result, :ok)
    end
  end

  defmodule TestOrchestrator do
    use GenServer

    def start_link(name), do: GenServer.start_link(__MODULE__, :ok, name: name)
    def init(:ok), do: {:ok, :ok}

    def handle_call(:resume_after_review, _from, state) do
      {:reply, %{resumed: true, requested_at: DateTime.utc_now()}, state}
    end
  end

  setup do
    write_workflow_file!(Workflow.workflow_file_path(),
      review_enabled: true,
      review_issue_identifier: "QNT-REVIEW",
      review_reviewer: "@owner"
    )

    Process.delete(:review_gate_result)
    Process.delete(:review_resolve_result)
    Process.delete(:review_issue_result)
    Process.delete(:review_comment_result)
    :ok
  end

  test "requires an explicit decision and non-empty feedback" do
    assert {:error, :invalid_decision} =
             ReviewDecision.submit(%{"decision" => "wait", "feedback" => "later"})

    assert {:error, :feedback_required} =
             ReviewDecision.submit(%{"decision" => "maintain", "feedback" => " "})

    assert {:error, :feedback_required} =
             ReviewDecision.submit(%{"decision" => "maintain", "feedback" => 42})
  end

  test "persists the decision to Linear, resolves the gate, and resumes orchestration" do
    gate = %{
      window_key: "2026-07-18T10:00:00+09:00",
      status: "open"
    }

    Process.put(:review_gate_result, {:ok, gate})
    Process.put(:review_issue_result, {:ok, %{id: "review-1", identifier: "QNT-REVIEW"}})

    Process.put(
      :review_resolve_result,
      {:ok, Map.merge(gate, %{status: "resolved", decision: "adjust"})}
    )

    orchestrator = Module.concat(__MODULE__, :Orchestrator)
    start_supervised!({TestOrchestrator, orchestrator})

    assert {:ok, payload} =
             ReviewDecision.submit(
               %{
                 "decision" => "adjust",
                 "feedback" => "Narrow the goal to liquid US equities."
               },
               tracker: TestTracker,
               loop_store: TestStore,
               orchestrator: orchestrator
             )

    assert payload.accepted == true
    assert payload.decision == "adjust"
    assert payload.review_issue_identifier == "QNT-REVIEW"
    assert payload.resume.resumed == true
    assert_receive {:resolve_review_issue, "QNT-REVIEW"}
    assert_receive {:review_comment, "review-1", body}
    assert body =~ "Goal Review Decision"
    assert body =~ "Narrow the goal"
    assert_receive {:resolve_review_gate, "adjust", "Narrow the goal to liquid US equities."}
  end

  test "keeps the gate closed on missing state or tracker failure" do
    assert {:error, :no_open_review_gate} =
             ReviewDecision.submit(
               %{"decision" => "maintain", "feedback" => "keep going"},
               tracker: TestTracker,
               loop_store: TestStore
             )

    Process.put(:review_gate_result, {:error, :db_down})

    assert {:error, {:store_error, :db_down}} =
             ReviewDecision.submit(
               %{"decision" => "maintain", "feedback" => "keep going"},
               tracker: TestTracker,
               loop_store: TestStore
             )

    Process.put(:review_gate_result, {:ok, %{status: "open", window_key: "window"}})
    Process.put(:review_issue_result, {:error, :issue_not_found})

    assert {:error, :review_issue_not_found} =
             ReviewDecision.submit(
               %{"decision" => "maintain", "feedback" => "keep going"},
               tracker: TestTracker,
               loop_store: TestStore
             )

    Process.put(:review_issue_result, {:error, :linear_down})

    assert {:error, {:tracker_error, :linear_down}} =
             ReviewDecision.submit(
               %{"decision" => "maintain", "feedback" => "keep going"},
               tracker: TestTracker,
               loop_store: TestStore
             )

    Process.put(:review_issue_result, :malformed)

    assert {:error, :review_issue_not_found} =
             ReviewDecision.submit(
               %{"decision" => "maintain", "feedback" => "keep going"},
               tracker: TestTracker,
               loop_store: TestStore
             )
  end

  test "does not resume when tracker, store, or orchestrator completion fails" do
    gate = %{status: "open", window_key: "window"}
    resolved = Map.merge(gate, %{status: "resolved", decision: "maintain"})
    params = %{"decision" => "maintain", "feedback" => "Keep the goal."}

    Process.put(:review_gate_result, {:ok, gate})
    Process.put(:review_issue_result, {:ok, %{id: "review-1", identifier: "QNT-REVIEW"}})

    Process.put(:review_comment_result, {:error, :comment_down})

    assert {:error, {:tracker_error, :comment_down}} =
             ReviewDecision.submit(params, tracker: TestTracker, loop_store: TestStore)

    Process.put(:review_comment_result, :malformed)

    assert {:error, {:tracker_error, :malformed}} =
             ReviewDecision.submit(params, tracker: TestTracker, loop_store: TestStore)

    Process.put(:review_comment_result, :ok)
    Process.put(:review_resolve_result, {:error, :db_down})

    assert {:error, {:store_error, :db_down}} =
             ReviewDecision.submit(params, tracker: TestTracker, loop_store: TestStore)

    Process.put(:review_resolve_result, {:ok, resolved})

    assert {:error, :orchestrator_unavailable} =
             ReviewDecision.submit(params,
               tracker: TestTracker,
               loop_store: TestStore,
               orchestrator: __MODULE__.MissingOrchestrator
             )
  end
end
