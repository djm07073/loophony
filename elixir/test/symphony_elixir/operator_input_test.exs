defmodule SymphonyElixir.OperatorInputTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.{Linear.Issue, OperatorInput}

  defmodule TestOrchestrator do
    use GenServer

    def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: Keyword.fetch!(opts, :name))
    def init(opts), do: {:ok, opts}

    def handle_call(:snapshot, _from, state),
      do: {:reply, Keyword.fetch!(state, :snapshot), state}

    def handle_call(:request_refresh, _from, state),
      do: {:reply, Keyword.get(state, :refresh, :unexpected), state}

    def handle_call({:resume_issue, issue_id}, _from, state) do
      send(Keyword.fetch!(state, :test_pid), {:resume_issue, issue_id})
      {:reply, %{released: true, issue_id: issue_id}, state}
    end

    def handle_call({:preempt_issue, issue_id, request_id}, _from, state) do
      send(Keyword.fetch!(state, :test_pid), {:preempt_issue, issue_id, request_id})

      {:reply,
       Keyword.get(state, :preemption, %{
         requested: true,
         status: "interrupt_requested",
         delivery: "turn_interrupt",
         issue_id: issue_id,
         request_id: request_id
       }), state}
    end
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

    def create_issue(attributes) do
      send(self(), {:create_issue, attributes})
      Process.get(:operator_create_issue_result, {:error, :issue_create_unconfigured})
    end

    def create_issue_relation(_issue_id, _related_issue_id, _relation_type), do: :ok

    def update_issue_state(issue_id, state_name) do
      send(self(), {:update_issue_state, issue_id, state_name})
      Process.get(:operator_update_result, :ok)
    end
  end

  defmodule TestRuntimeStore do
    use GenServer

    def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: Keyword.fetch!(opts, :name))
    def init(opts), do: {:ok, Map.new(opts)}

    def handle_call({:active_wait, _issue_id}, _from, state) do
      {:reply, Map.fetch!(state, :active_wait), state}
    end

    def handle_call({:release_wait, _wait_id, _reason}, _from, state) do
      {:reply, Map.fetch!(state, :release_wait), state}
    end
  end

  setup do
    Process.delete(:operator_resolve_result)
    Process.delete(:operator_comment_result)
    Process.delete(:operator_update_result)
    Process.delete(:operator_create_issue_result)
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

    assert {:error, :invalid_priority} =
             OperatorInput.submit(
               %{"kind" => "instruction", "message" => "work", "priority" => 5},
               tracker: TestTracker
             )

    assert {:error, :invalid_title} =
             OperatorInput.submit(
               %{"kind" => "instruction", "message" => "work", "title" => " "},
               tracker: TestTracker
             )

    assert {:error, :invalid_title} =
             OperatorInput.submit(
               %{"kind" => "instruction", "message" => "work", "title" => String.duplicate("x", 201)},
               tracker: TestTracker
             )

    assert {:error, :invalid_title} =
             OperatorInput.submit(
               %{"kind" => "instruction", "message" => "work", "title" => 42},
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

    Process.put(:operator_resolve_result, {:ok, %{id: nil, identifier: "QNT-MALFORMED"}})

    assert {:error, :issue_not_found} =
             OperatorInput.submit(explicit_input("QNT-MALFORMED"),
               tracker: TestTracker,
               orchestrator: __MODULE__.MissingOrchestrator
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
    assert payload.runtime_block == %{released: true, issue_id: "issue-1"}
    assert payload.refresh == %{queued: false}
    assert_receive {:update_issue_state, "issue-1", "In Progress"}
    assert_receive {:resume_issue, "issue-1"}
  end

  test "preempt persists the human input and requests a fresh turn" do
    orchestrator = start_orchestrator(valid_snapshot())

    assert {:ok, payload} =
             OperatorInput.submit(
               %{
                 "kind" => "preempt",
                 "message" => "지금 작업을 중단하고 새 가설로 다시 계획해.",
                 "request_id" => "request-preempt-1"
               },
               tracker: TestTracker,
               orchestrator: orchestrator
             )

    assert payload.delivery == "turn_interrupt"
    assert payload.preemption.status == "interrupt_requested"
    assert payload.preemption.request_id == "request-preempt-1"
    assert payload.resumed_to == nil
    assert_receive {:create_comment, "issue-1", comment}
    assert comment =~ "유형: `preempt`"
    assert comment =~ "현재 Codex turn 중단 후 보존된 workspace에서 새 실행"
    assert_receive {:preempt_issue, "issue-1", "request-preempt-1"}
  end

  test "preempt remains durably accepted when the runtime interrupt endpoint is unavailable" do
    Process.put(:operator_resolve_result, {:ok, %{id: "issue-9", identifier: "QNT-9"}})

    assert {:ok, payload} =
             OperatorInput.submit(
               %{
                 "kind" => "preempt",
                 "message" => "다음 실행에서 이 지시로 다시 계획해.",
                 "issue_identifier" => "QNT-9",
                 "request_id" => "request-preempt-offline"
               },
               tracker: TestTracker,
               orchestrator: __MODULE__.MissingOrchestrator
             )

    assert payload.delivery == "turn_interrupt"
    assert payload.preemption == :unavailable
    assert payload.refresh == %{queued: false, unavailable: true}
    assert_receive {:create_comment, "issue-9", comment}
    assert comment =~ "symphony-human-input:request-preempt-offline"
  end

  test "operator control releases automated waits and reports store failures" do
    orchestrator = start_orchestrator(valid_snapshot())
    runtime_store = __MODULE__.TestRuntimeStoreInstance
    active_wait = {:ok, %{wait_id: "wait-1"}}
    released_wait = {:ok, %{wait_id: "wait-1", status: "released"}}

    start_supervised!({TestRuntimeStore, name: runtime_store, active_wait: active_wait, release_wait: released_wait})

    assert {:ok, success} =
             OperatorInput.submit(
               %{
                 "kind" => "goal_adjustment",
                 "message" => "새 목표로 전환",
                 "request_id" => "request-wait-success"
               },
               tracker: TestTracker,
               orchestrator: orchestrator,
               runtime_store: runtime_store
             )

    assert success.automated_wait == %{released: true, wait_id: "wait-1"}

    :sys.replace_state(runtime_store, &Map.put(&1, :release_wait, {:error, :write_failed}))

    assert {:ok, release_failure} =
             OperatorInput.submit(
               %{
                 "kind" => "goal_adjustment",
                 "message" => "다시 시도",
                 "request_id" => "request-wait-release-error"
               },
               tracker: TestTracker,
               orchestrator: orchestrator,
               runtime_store: runtime_store
             )

    refute release_failure.automated_wait.released
    assert release_failure.automated_wait.error =~ "write_failed"

    :sys.replace_state(runtime_store, &Map.put(&1, :active_wait, {:error, :read_failed}))

    assert {:ok, read_failure} =
             OperatorInput.submit(
               %{
                 "kind" => "unblock",
                 "message" => "대기 해제",
                 "request_id" => "request-wait-read-error"
               },
               tracker: TestTracker,
               orchestrator: orchestrator,
               runtime_store: runtime_store
             )

    refute read_failure.automated_wait.released
    assert read_failure.automated_wait.error =~ "read_failed"
  end

  test "enabled intake creates a prioritized Human issue without interrupting ordinary work" do
    write_workflow_file!(Workflow.workflow_file_path(), intake_enabled: true)
    orchestrator = start_orchestrator(valid_snapshot())

    Process.put(:operator_resolve_result, {
      :ok,
      %Issue{
        id: "issue-1",
        identifier: "QNT-1",
        title: "SC-03 source",
        description: "Mapped stage: SC-03",
        project_description: "Goal version: v1\nActive stage: SC-03",
        url: "https://example.org/QNT-1"
      }
    })

    human_issue = %Issue{
      id: "human-1",
      identifier: "QNT-100",
      title: "[Human] 캐시 수정",
      description: "<!-- loophony-human-request:v1 -->",
      priority: 1,
      state: "Todo",
      url: "https://example.org/QNT-100",
      labels: []
    }

    Process.put(:operator_create_issue_result, {:ok, human_issue})

    assert {:ok, payload} =
             OperatorInput.submit(
               %{
                 "kind" => "instruction",
                 "message" => "캐시 무효화 경로를 수정해줘",
                 "title" => "캐시 수정",
                 "priority" => 1,
                 "request_id" => "human-request-1"
               },
               tracker: TestTracker,
               orchestrator: orchestrator
             )

    assert payload.delivery == "priority_queue"
    assert payload.human_issue.identifier == "QNT-100"
    assert payload.human_issue.priority == 1
    assert payload.preemption == nil

    assert_receive {:create_issue, attributes}
    assert attributes.source_issue_id == "issue-1"
    assert attributes.priority == 1
    assert attributes.description =~ "Mapped stage: SC-03"
    assert_receive {:resolve_issue, "QNT-1"}
    refute_received {:create_comment, _issue_id, _body}
    refute_received {:preempt_issue, _issue_id, _request_id}
  end

  test "enabled intake preemption creates a Human issue and explicitly interrupts current work" do
    write_workflow_file!(Workflow.workflow_file_path(), intake_enabled: true)
    orchestrator = start_orchestrator(valid_snapshot())

    Process.put(:operator_create_issue_result, {
      :ok,
      %Issue{
        id: "human-preempt",
        identifier: "QNT-101",
        title: "[Human] 즉시 수정",
        description: "<!-- loophony-human-request:v1 -->",
        priority: 1,
        state: "Todo",
        labels: []
      }
    })

    assert {:ok, payload} =
             OperatorInput.submit(
               %{
                 "kind" => "preempt",
                 "message" => "현재 작업을 멈추고 이 수정 티켓을 우선 처리해줘",
                 "request_id" => "human-preempt-1"
               },
               tracker: TestTracker,
               orchestrator: orchestrator
             )

    assert payload.delivery == "turn_interrupt"
    assert payload.human_issue.identifier == "QNT-101"
    assert payload.human_issue.priority == 1
    assert payload.paused_to == "Todo"
    assert_receive {:create_issue, %{priority: 1}}
    assert_receive {:update_issue_state, "issue-1", "Todo"}
    assert_receive {:preempt_issue, "issue-1", "human-preempt-1"}
  end

  test "enabled intake surfaces Human issue creation failures" do
    write_workflow_file!(Workflow.workflow_file_path(), intake_enabled: true)
    orchestrator = start_orchestrator(valid_snapshot())
    Process.put(:operator_create_issue_result, {:error, :linear_down})

    assert {:error, {:tracker_error, :linear_down}} =
             OperatorInput.submit(valid_input(), tracker: TestTracker, orchestrator: orchestrator)
  end

  test "enabled intake surfaces preempt source-state failures" do
    write_workflow_file!(Workflow.workflow_file_path(), intake_enabled: true)
    orchestrator = start_orchestrator(valid_snapshot())

    Process.put(:operator_create_issue_result, {
      :ok,
      %Issue{
        id: "human-preempt-failure",
        identifier: "QNT-102",
        title: "[Human] preempt failure",
        description: "<!-- loophony-human-request:v1 -->",
        priority: 1,
        state: "Todo",
        labels: []
      }
    })

    Process.put(:operator_update_result, {:error, :state_down})

    assert {:error, {:tracker_error, :state_down}} =
             OperatorInput.submit(
               %{
                 "kind" => "preempt",
                 "message" => "현재 작업을 중단",
                 "request_id" => "human-preempt-state-error"
               },
               tracker: TestTracker,
               orchestrator: orchestrator
             )

    Process.put(:operator_update_result, :unexpected)

    assert {:error, {:tracker_error, :unexpected}} =
             OperatorInput.submit(
               %{
                 "kind" => "preempt",
                 "message" => "현재 작업을 다시 중단",
                 "request_id" => "human-preempt-state-unexpected"
               },
               tracker: TestTracker,
               orchestrator: orchestrator
             )
  end

  test "invalid intake config safely preserves the legacy operator path" do
    write_workflow_file!(Workflow.workflow_file_path(), intake_enabled: "invalid")
    orchestrator = start_orchestrator(valid_snapshot())

    assert {:ok, %{delivery: "next_checkpoint"}} =
             OperatorInput.submit(valid_input(), tracker: TestTracker, orchestrator: orchestrator)

    assert_receive {:create_comment, "issue-1", _comment}
  end

  defp start_orchestrator(snapshot, refresh \\ %{queued: true}) do
    name = __MODULE__.TestOrchestratorInstance
    start_supervised!({TestOrchestrator, name: name, snapshot: snapshot, refresh: refresh, test_pid: self()})
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
