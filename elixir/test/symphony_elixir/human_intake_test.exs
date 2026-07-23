defmodule SymphonyElixir.HumanIntakeTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.Config.Schema.Intake
  alias SymphonyElixir.{HumanIntake, Linear.Issue}

  defmodule TestTracker do
    def fetch_issues_by_states(states) do
      send(self(), {:fetch_intake_states, states})
      Process.get(:intake_issues_result, {:ok, []})
    end

    def create_issue(attributes) do
      send(self(), {:create_intake_issue, attributes})

      case Process.get(:intake_create_result) do
        nil -> {:ok, issue_from_attributes(attributes)}
        result -> result
      end
    end

    def create_issue_relation(issue_id, related_issue_id, relation_type) do
      send(self(), {:create_intake_relation, issue_id, related_issue_id, relation_type})
      Process.get(:intake_relation_result, :ok)
    end

    def update_issue_state(issue_id, state_name) do
      send(self(), {:update_intake_state, issue_id, state_name})
      Process.get(:intake_state_result, :ok)
    end

    defp issue_from_attributes(attributes) do
      %Issue{
        id: "created-issue",
        identifier: "LOOP-100",
        title: attributes.title,
        description: attributes.description,
        priority: attributes.priority,
        state: attributes.state_name,
        url: "https://example.org/LOOP-100",
        labels: []
      }
    end
  end

  setup do
    for key <- [
          :intake_issues_result,
          :intake_create_result,
          :intake_relation_result,
          :intake_state_result
        ] do
      Process.delete(key)
    end

    :ok
  end

  test "operator feedback creates a durable Human issue" do
    target = %{
      id: "source-1",
      identifier: "LOOP-1",
      title: "SC-03 evidence collection",
      description: "* Mapped stage: **SC-03 — Evidence**",
      url: "https://example.org/LOOP-1"
    }

    assert {:ok, issue} =
             HumanIntake.create_human_issue(
               %{
                 kind: "instruction",
                 message: "캐시 무효화 경로를 수정해줘",
                 title: "캐시 무효화 수정",
                 priority: 1,
                 request_id: "request-1"
               },
               target,
               tracker: TestTracker,
               settings: intake_settings()
             )

    assert issue.title == "[Human] 캐시 무효화 수정"
    assert issue.priority == 1
    assert HumanIntake.human_issue?(issue)

    assert_receive {:create_intake_issue, attributes}
    assert attributes.source_issue_id == "source-1"
    assert attributes.state_name == "Todo"
    assert attributes.description =~ "loophony-human-request:v1"
    assert attributes.description =~ "request-1"
    assert attributes.description =~ "Mapped stage: SC-03"
  end

  test "operator feedback inherits the active stage when the source has no explicit mapping" do
    target = %{
      id: "source-2",
      identifier: "LOOP-2",
      project_description: "Goal version: v4\nActive stage: SC-04"
    }

    assert {:ok, _issue} =
             HumanIntake.create_human_issue(
               %{
                 kind: "instruction",
                 message: "계속 진행",
                 priority: 2,
                 request_id: "request-stage-fallback"
               },
               target,
               tracker: TestTracker,
               settings: intake_settings()
             )

    assert_receive {:create_intake_issue, attributes}
    assert attributes.description =~ "Mapped stage: SC-04"
  end

  test "preemption defaults to urgent priority when none is supplied" do
    target = %{id: "source-3", identifier: "LOOP-3"}

    assert {:ok, issue} =
             HumanIntake.create_human_issue(
               %{
                 kind: "preempt",
                 message: "현재 작업을 멈추고 이 요청을 먼저 처리",
                 request_id: "request-preempt-default-priority"
               },
               target,
               tracker: TestTracker,
               settings: intake_settings()
             )

    assert issue.priority == 1
    assert_receive {:create_intake_issue, %{priority: 1}}
  end

  test "reconciliation selects the highest priority oldest Human issue and creates linked Work" do
    older = DateTime.utc_now() |> DateTime.add(-100, :second)
    newer = DateTime.utc_now()

    low = human_issue("human-low", "LOOP-2", 3, older)
    urgent_newer = human_issue("human-urgent-new", "LOOP-3", 1, newer)
    urgent_older = human_issue("human-urgent-old", "LOOP-4", 1, older)
    Process.put(:intake_issues_result, {:ok, [low, urgent_newer, urgent_older]})

    assert {:ok, summary} =
             HumanIntake.reconcile(
               tracker: TestTracker,
               settings: intake_settings(),
               state_names: ["Todo", "In Progress", "Done"]
             )

    assert summary.candidates == 3

    assert [%{human_issue_id: "human-urgent-old", work_issue_id: "created-issue"}] =
             summary.claimed

    assert_receive {:create_intake_issue, work_attributes}
    assert work_attributes.source_issue_id == "human-urgent-old"
    assert work_attributes.priority == 1
    assert work_attributes.title == "[Work] LOOP-4 feedback"
    assert work_attributes.description =~ "human_issue_id=human-urgent-old"

    assert_receive {:create_intake_relation, "created-issue", "human-urgent-old", "related"}
    refute_received {:update_intake_state, _human_issue_id, "In Progress"}
  end

  test "reconciliation keeps a materialized Human issue in Todo without creating a duplicate" do
    human = human_issue("human-1", "LOOP-10", 2, DateTime.utc_now())
    work = work_issue("work-1", "LOOP-11", human.id, "Todo")

    assert HumanIntake.work_issue?(work)
    refute HumanIntake.human_issue?(work)

    Process.put(:intake_issues_result, {:ok, [human, work]})

    assert {:ok, %{candidates: 0, claimed: []}} =
             HumanIntake.reconcile(
               tracker: TestTracker,
               settings: intake_settings(),
               state_names: ["Todo", "In Progress", "Done"]
             )

    refute_received {:create_intake_issue, _attributes}
    refute_received {:update_intake_state, "human-1", _state}
  end

  test "terminal Work completion closes its source Human issue" do
    human = human_issue("human-1", "LOOP-10", 2, DateTime.utc_now())
    work = work_issue("work-1", "LOOP-11", human.id, "Done")
    Process.put(:intake_issues_result, {:ok, [human, work]})

    assert {:ok, %{completed: [%{human_issue_id: "human-1", work_issue_id: "work-1"}]}} =
             HumanIntake.reconcile(
               tracker: TestTracker,
               settings: intake_settings(),
               state_names: ["Todo", "In Progress", "Done"]
             )

    assert_receive {:update_intake_state, "human-1", "Done"}
    refute_received {:create_intake_issue, _attributes}
  end

  test "terminal Work completion is idempotent for an already completed Human issue" do
    human = %{human_issue("human-1", "LOOP-10", 2, DateTime.utc_now()) | state: "Done"}
    work = work_issue("work-1", "LOOP-11", human.id, "Done")
    Process.put(:intake_issues_result, {:ok, [human, work]})

    assert {:ok, %{claimed: [], completed: [%{human_issue_id: "human-1"}]}} =
             HumanIntake.reconcile(
               tracker: TestTracker,
               settings: intake_settings(),
               state_names: ["Todo", "In Progress", "Done"]
             )

    refute_received {:update_intake_state, "human-1", "Done"}
    refute_received {:create_intake_issue, _attributes}
  end

  defp human_issue(id, identifier, priority, created_at) do
    %Issue{
      id: id,
      identifier: identifier,
      title: "[Human] #{identifier} feedback",
      description: "<!-- loophony-human-request:v1 -->\n요청",
      priority: priority,
      state: "Todo",
      url: "https://example.org/#{identifier}",
      created_at: created_at,
      labels: []
    }
  end

  defp work_issue(id, identifier, human_issue_id, state) do
    %Issue{
      id: id,
      identifier: identifier,
      title: "[Work] linked request",
      description: "<!-- loophony-work-item:v1 human_issue_id=#{human_issue_id} -->\n<!-- loophony-human-request:v1 -->\n요청",
      state: state,
      url: "https://example.org/#{identifier}",
      labels: []
    }
  end

  defp intake_settings do
    %Intake{
      enabled: true,
      todo_state: "Todo",
      completed_state: "Done",
      max_claims_per_poll: 1
    }
  end
end
