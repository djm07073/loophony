defmodule SymphonyElixir.OperatorHandoffRecoveryTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.{Handoff, OperatorHandoffRecovery}

  test "completes a terminal operator Work source when its marked successor is also in progress" do
    source = operator_work_issue("source", "HFT-137")

    successor = %Issue{
      id: "successor",
      identifier: "HFT-135",
      state: "In Progress",
      description: Handoff.marker(source.id, "gpt-5.6-sol")
    }

    checkpoint = %{
      phase: "handoff",
      outcome: "done",
      checkpoint_key: "handoff-v1",
      next_action: "HFT-135에서 구현을 계속한다."
    }

    parent = self()

    assert {:ok, repaired} =
             OperatorHandoffRecovery.reconcile([source, successor],
               checkpoint_fetcher: fn "source" -> {:ok, [checkpoint]} end,
               state_updater: fn issue_id, state ->
                 send(parent, {:state_updated, issue_id, state})
                 :ok
               end,
               audit_recorder: fn action, event ->
                 send(parent, {:audited, action, event})
                 :ok
               end
             )

    assert_receive {:state_updated, "source", "Done"}

    assert_receive {:audited, "operator_handoff.overlap_recovered", %{resource_id: "source", metadata: %{successor_issue_id: "successor"}}}

    assert Enum.find(repaired, &(&1.id == "source")).state == "Done"
    assert Enum.find(repaired, &(&1.id == "successor")).state == "In Progress"
  end

  test "does not relax normal handoffs or act without exact durable proof" do
    normal_source = %Issue{id: "source", identifier: "HFT-1", state: "In Progress"}

    successor = %Issue{
      id: "successor",
      identifier: "HFT-2",
      state: "In Progress",
      description: Handoff.marker(normal_source.id, "gpt-5.6-sol")
    }

    flunk_updater = fn _issue_id, _state -> flunk("state must not be updated") end

    assert {:ok, [^normal_source, ^successor]} =
             OperatorHandoffRecovery.reconcile([normal_source, successor],
               checkpoint_fetcher: fn _issue_id -> {:ok, []} end,
               state_updater: flunk_updater
             )

    work_source = operator_work_issue("work-source", "HFT-3")
    unrelated_checkpoint = %{phase: "handoff", outcome: "done", next_action: "HFT-999"}

    work_successor = %{
      successor
      | description: Handoff.marker(work_source.id, "gpt-5.6-sol")
    }

    assert {:ok, [^work_source, ^work_successor]} =
             OperatorHandoffRecovery.reconcile([work_source, work_successor],
               checkpoint_fetcher: fn "work-source" -> {:ok, [unrelated_checkpoint]} end,
               state_updater: flunk_updater
             )

    unmarked_successor = %{work_successor | description: "no handoff marker"}

    assert {:ok, [^work_source, ^unmarked_successor]} =
             OperatorHandoffRecovery.reconcile([work_source, unmarked_successor],
               checkpoint_fetcher: fn _issue_id -> flunk("checkpoint must not be fetched") end,
               state_updater: flunk_updater
             )

    assert {:ok, [%{}]} = OperatorHandoffRecovery.reconcile([%{}])
  end

  test "surfaces checkpoint and state update failures without partial local repair" do
    source = operator_work_issue("source", "HFT-10")

    successor = %Issue{
      id: "successor",
      identifier: "HFT-11",
      state: "In Progress",
      description: Handoff.marker(source.id, "gpt-5.6-sol")
    }

    checkpoint = %{
      phase: "handoff",
      outcome: "done",
      checkpoint_key: "handoff-v2",
      next_action: "HFT-11에서 계속한다."
    }

    assert {:error, {:operator_handoff_checkpoint_unavailable, "HFT-10", :database_down}} =
             OperatorHandoffRecovery.reconcile([source, successor],
               checkpoint_fetcher: fn "source" -> {:error, :database_down} end
             )

    assert {:error, {:operator_handoff_checkpoint_invalid, "HFT-10", :unexpected}} =
             OperatorHandoffRecovery.reconcile([source, successor],
               checkpoint_fetcher: fn "source" -> :unexpected end
             )

    no_name_successor = %{successor | identifier: nil}

    assert {:ok, [^source, ^no_name_successor]} =
             OperatorHandoffRecovery.reconcile([source, no_name_successor],
               checkpoint_fetcher: fn "source" ->
                 {:ok,
                  [
                    nil,
                    %{phase: "handoff", outcome: "done"},
                    %{phase: "handoff", outcome: "done", next_action: "another issue"}
                  ]}
               end,
               state_updater: fn _issue_id, _state -> flunk("state must not be updated") end
             )

    assert {:error, {:operator_handoff_recovery_failed, "HFT-10", :write_failed}} =
             OperatorHandoffRecovery.reconcile([source, successor],
               checkpoint_fetcher: fn "source" -> {:ok, [checkpoint]} end,
               state_updater: fn "source", "Done" -> {:error, :write_failed} end
             )

    assert {:error, {:operator_handoff_recovery_invalid, "HFT-10", :unexpected}} =
             OperatorHandoffRecovery.reconcile([source, successor],
               checkpoint_fetcher: fn "source" -> {:ok, [checkpoint]} end,
               state_updater: fn "source", "Done" -> :unexpected end
             )
  end

  defp operator_work_issue(id, identifier) do
    %Issue{
      id: id,
      identifier: identifier,
      state: "In Progress",
      description: "<!-- loophony-work-item:v1 human_issue_id=human-1 -->"
    }
  end
end
