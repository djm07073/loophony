defmodule SymphonyElixir.OperatorInputTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.OperatorInput

  defmodule TestOrchestrator do
    use GenServer

    def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: Keyword.fetch!(opts, :name))
    def init(opts), do: {:ok, opts}

    def handle_call(:snapshot, _from, state),
      do: {:reply, Keyword.fetch!(state, :snapshot), state}

    def handle_call(:request_refresh, _from, state),
      do: {:reply, Keyword.get(state, :refresh, :unexpected), state}
  end

  defmodule TestTracker do
    def resolve_issue(identifier) do
      send(self(), {:resolve_issue, identifier})
      Process.get(:operator_resolve_result, {:error, :issue_not_found})
    end

    def create_comment(issue_id, body) do
      send(self(), {:create_comment, issue_id, body})
      Process.get(:operator_comment_result, :ok)
    end

    def update_issue_state(issue_id, state_name) do
      send(self(), {:update_issue_state, issue_id, state_name})
      Process.get(:operator_update_result, :ok)
    end
  end

  setup do
    Process.delete(:operator_resolve_result)
    Process.delete(:operator_comment_result)
    Process.delete(:operator_update_result)
    :ok
  end

  test "validates operator input before touching the daemon" do
    assert {:error, :invalid_kind} = OperatorInput.submit(%{"kind" => "unknown"})

    assert {:error, :invalid_message} =
             OperatorInput.submit(%{"kind" => "instruction", "message" => nil}, tracker: TestTracker)

    assert {:error, :invalid_message} =
             OperatorInput.submit(%{"kind" => "instruction", "message" => "  "}, tracker: TestTracker)

    assert {:error, :invalid_message} =
             OperatorInput.submit(
               %{"kind" => "instruction", "message" => String.duplicate("x", 10_001)},
               tracker: TestTracker
             )

    assert {:error, :invalid_request_id} =
             OperatorInput.submit(
               %{"kind" => "instruction", "message" => "work", "request_id" => 42},
               tracker: TestTracker
             )

    assert {:error, :invalid_request_id} =
             OperatorInput.submit(
               %{"kind" => "instruction", "message" => "work", "request_id" => "bad id"},
               tracker: TestTracker
             )

    assert {:error, :invalid_resume_state} =
             OperatorInput.submit(
               %{
                 "kind" => "unblock",
                 "message" => "resume",
                 "request_id" => "request",
                 "resume_state" => " "
               },
               tracker: TestTracker
             )

    assert {:error, :invalid_resume_state} =
             OperatorInput.submit(
               %{
                 "kind" => "unblock",
                 "message" => "resume",
                 "request_id" => "request",
                 "resume_state" => 42
               },
               tracker: TestTracker
             )
  end

  test "reports missing and unavailable implicit targets" do
    orchestrator = start_orchestrator(%{running: [], blocked: [], queued: [], retrying: []})

    assert {:error, :no_target_issue} =
             OperatorInput.submit(valid_input(), tracker: TestTracker, orchestrator: orchestrator)

    assert {:error, :no_target_issue} =
             OperatorInput.submit(Map.put(valid_input(), "issue_identifier", " "),
               tracker: TestTracker,
               orchestrator: orchestrator
             )

    assert {:error, :no_target_issue} =
             OperatorInput.submit(Map.put(valid_input(), "issue_identifier", 42),
               tracker: TestTracker,
               orchestrator: orchestrator
             )

    assert {:error, :orchestrator_unavailable} =
             OperatorInput.submit(valid_input(),
               tracker: TestTracker,
               orchestrator: __MODULE__.MissingOrchestrator
             )
  end

  test "resolves explicit tracker targets and generates request IDs" do
    Process.put(:operator_resolve_result, {:ok, %{id: "issue-9", identifier: "QNT-9"}})

    assert {:ok, payload} =
             OperatorInput.submit(
               %{
                 "kind" => "instruction",
                 "message" => "Use the new evidence.",
                 "issue_identifier" => "QNT-9"
               },
               tracker: TestTracker,
               orchestrator: __MODULE__.MissingOrchestrator
             )

    assert payload.issue_identifier == "QNT-9"
    assert payload.delivery == "next_checkpoint"
    assert payload.refresh == %{queued: false, unavailable: true}
    assert is_binary(payload.request_id)
    assert_receive {:resolve_issue, "QNT-9"}
    assert_receive {:create_comment, "issue-9", body}
    assert body =~ "symphony-human-input:#{payload.request_id}"
  end

  test "handles tracker resolution variants and malformed snapshot entries" do
    orchestrator =
      start_orchestrator(%{
        running: [%{issue_id: nil, identifier: nil}, :malformed],
        blocked: [],
        queued: [],
        retrying: []
      })

    assert {:error, :no_target_issue} =
             OperatorInput.submit(valid_input(), tracker: TestTracker, orchestrator: orchestrator)

    Process.put(:operator_resolve_result, {:error, :issue_not_found})

    assert {:error, :issue_not_found} =
             OperatorInput.submit(explicit_input("QNT-MISSING"),
               tracker: TestTracker,
               orchestrator: orchestrator
             )

    :sys.replace_state(Process.whereis(orchestrator), fn state ->
      Keyword.put(state, :snapshot, %{
        running: [:malformed],
        blocked: [],
        queued: [],
        retrying: []
      })
    end)

    assert {:error, :no_target_issue} =
             OperatorInput.submit(valid_input(), tracker: TestTracker, orchestrator: orchestrator)

    assert {:error, :issue_not_found} =
             OperatorInput.submit(explicit_input("QNT-MISSING"),
               tracker: TestTracker,
               orchestrator: orchestrator
             )

    Process.put(:operator_resolve_result, {:error, :linear_down})

    assert {:error, {:tracker_error, :linear_down}} =
             OperatorInput.submit(explicit_input("QNT-ERROR"),
               tracker: TestTracker,
               orchestrator: orchestrator
             )

    Process.put(:operator_resolve_result, :unexpected)

    assert {:error, :issue_not_found} =
             OperatorInput.submit(explicit_input("QNT-WEIRD"),
               tracker: TestTracker,
               orchestrator: orchestrator
             )
  end

  test "falls back to tracker when a matching snapshot entry is incomplete" do
    orchestrator =
      start_orchestrator(%{
        running: [%{issue_id: nil, identifier: "QNT-7"}],
        blocked: [],
        queued: [],
        retrying: []
      })

    Process.put(:operator_resolve_result, {:ok, %{id: "issue-7", identifier: "QNT-7"}})

    assert {:ok, %{issue_id: "issue-7"}} =
             OperatorInput.submit(explicit_input("qnt-7"),
               tracker: TestTracker,
               orchestrator: orchestrator
             )
  end

  test "surfaces comment and unblock state failures" do
    orchestrator = start_orchestrator(valid_snapshot())
    Process.put(:operator_comment_result, {:error, :comment_down})

    assert {:error, {:tracker_error, :comment_down}} =
             OperatorInput.submit(valid_input(), tracker: TestTracker, orchestrator: orchestrator)

    Process.put(:operator_comment_result, :unexpected)

    assert {:error, {:tracker_error, :unexpected}} =
             OperatorInput.submit(valid_input(), tracker: TestTracker, orchestrator: orchestrator)

    Process.put(:operator_comment_result, :ok)
    Process.put(:operator_update_result, {:error, :state_down})

    assert {:error, {:tracker_error, :state_down}} =
             OperatorInput.submit(unblock_input(), tracker: TestTracker, orchestrator: orchestrator)

    Process.put(:operator_update_result, :unexpected)

    assert {:error, {:tracker_error, :unexpected}} =
             OperatorInput.submit(unblock_input(), tracker: TestTracker, orchestrator: orchestrator)
  end

  test "accepts a custom unblock state" do
    orchestrator = start_orchestrator(valid_snapshot(), %{queued: false})

    assert {:ok, payload} =
             OperatorInput.submit(
               Map.put(unblock_input(), "resume_state", "In Progress"),
               tracker: TestTracker,
               orchestrator: orchestrator
             )

    assert payload.resumed_to == "In Progress"
    assert payload.refresh == %{queued: false}
    assert_receive {:update_issue_state, "issue-1", "In Progress"}
  end

  defp start_orchestrator(snapshot, refresh \\ %{queued: true}) do
    name = __MODULE__.TestOrchestratorInstance
    start_supervised!({TestOrchestrator, name: name, snapshot: snapshot, refresh: refresh})
    name
  end

  defp valid_snapshot do
    %{
      running: [%{issue_id: "issue-1", identifier: "QNT-1"}],
      blocked: [],
      queued: [],
      retrying: []
    }
  end

  defp valid_input do
    %{"kind" => "instruction", "message" => "Keep going", "request_id" => "request-1"}
  end

  defp explicit_input(identifier),
    do: Map.put(valid_input(), "issue_identifier", identifier)

  defp unblock_input do
    %{"kind" => "unblock", "message" => "Decision supplied", "request_id" => "request-2"}
  end
end
