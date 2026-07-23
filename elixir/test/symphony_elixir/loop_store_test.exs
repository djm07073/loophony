defmodule SymphonyElixir.LoopStoreTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.LoopStore

  setup do
    root = Path.join(System.tmp_dir!(), "symphony-loop-store-#{System.unique_integer([:positive])}")
    path = Path.join(root, "state/loop.sqlite3")
    name = __MODULE__.Store
    start_supervised!({LoopStore, name: name, path: path})
    on_exit(fn -> File.rm_rf(root) end)
    %{name: name, path: path}
  end

  test "persists idempotent checkpoints and exposes recent loop context", %{name: name, path: path} do
    issue = %Issue{id: "issue-1", identifier: "QNT-1"}

    first_attributes =
      checkpoint()
      |> Map.put(:session_id, "thread-1-turn-1")
      |> Map.put(:thread_id, "thread-1")
      |> Map.put(:turn_id, "turn-1")

    assert {:ok, first} = LoopStore.record_checkpoint(issue, first_attributes, 1, name)
    assert first.issue_identifier == "QNT-1"
    assert first.evidence == ["test:pass"]
    assert first.session_id == "thread-1-turn-1"
    assert first.thread_id == "thread-1"
    assert first.turn_id == "turn-1"
    assert File.exists?(path)

    updated =
      checkpoint()
      |> Map.put(:summary, "Updated observation")
      |> Map.put(:outcome, "done")

    assert {:ok, second} = LoopStore.record_checkpoint(issue, updated, 2, name)
    assert second.id == first.id
    assert second.summary == "Updated observation"
    assert second.turn_number == 2

    assert {:ok, [recent]} = LoopStore.recent("issue-1", 5, name)
    assert recent.outcome == "done"
    assert {:ok, [all_checkpoint]} = LoopStore.all_checkpoints(name)
    assert all_checkpoint.id == recent.id

    summary = LoopStore.summary(name)
    assert summary.available == true
    assert summary.total_checkpoints == 1
    assert summary.outcomes == %{"done" => 1}

    context = LoopStore.prompt_context(issue, name)
    assert context =~ "Durable loop memory"
    assert context =~ "Updated observation"
    assert LoopStore.prompt_context(%Issue{id: "issue-missing"}, name) == ""

    prior_issue = %Issue{id: "issue-0", identifier: "QNT-0"}

    assert {:ok, _handoff} =
             LoopStore.record_checkpoint(
               prior_issue,
               checkpoint()
               |> Map.put(:checkpoint_key, "handoff-v1")
               |> Map.put(:phase, "handoff")
               |> Map.put(:summary, "Prior issue falsified the low-liquidity branch")
               |> Map.put(:decision, "Exclude the branch in the next Candidate"),
               1,
               name
             )

    refute LoopStore.prompt_context(issue, name) =~ "Prior issue falsified the low-liquidity branch"
    assert LoopStore.prompt_context(%Issue{id: "issue-2", identifier: "QNT-2"}, name) == ""
  end

  test "keeps terminal outcomes evidence gated", %{name: name} do
    issue = %Issue{id: "issue-1", identifier: "QNT-1"}

    assert {:error, :terminal_evidence_required} =
             LoopStore.record_checkpoint(
               issue,
               checkpoint() |> Map.put(:outcome, "rejected") |> Map.put(:evidence, []),
               1,
               name
             )

    assert {:error, {:invalid_checkpoint_field, "phase"}} =
             LoopStore.record_checkpoint(issue, Map.put(checkpoint(), :phase, "guess"), 1, name)

    assert {:error, {:invalid_checkpoint_field, "goal_alignment"}} =
             LoopStore.record_checkpoint(issue, Map.put(checkpoint(), :goal_alignment, "drifting"), 1, name)

    assert {:error, {:invalid_checkpoint_field, "evidence"}} =
             LoopStore.record_checkpoint(issue, Map.put(checkpoint(), :evidence, [42]), 1, name)

    assert {:error, :invalid_issue_context} =
             LoopStore.record_checkpoint(%Issue{}, checkpoint(), 0, name)
  end

  test "validates query limits and reports an unavailable store", %{name: name} do
    assert {:error, :invalid_limit} = LoopStore.recent("issue-1", 0, name)

    assert {:error, {:loop_store_unavailable, _reason}} =
             LoopStore.recent("issue-1", 5, __MODULE__.MissingStore)

    assert %{available: false, recent: []} = LoopStore.summary(__MODULE__.MissingStore)
  end

  test "opens one durable KST review gate per scheduled window and requires feedback", %{name: name} do
    write_workflow_file!(Workflow.workflow_file_path(),
      review_enabled: true,
      review_issue_identifier: "QNT-REVIEW",
      review_reviewer: "@owner"
    )

    morning = ~U[2026-07-18 01:05:00Z]
    assert {:ok, morning_gate} = LoopStore.ensure_review_gate(morning, name)
    assert morning_gate.window_key == "2026-07-18T10:00:00+09:00"
    assert morning_gate.status == "open"
    assert morning_gate.reported_at == nil
    assert {:ok, ^morning_gate} = LoopStore.ensure_review_gate(morning, name)

    assert {:ok, reported} = LoopStore.mark_review_reported(morning_gate.window_key, name)
    assert is_binary(reported.reported_at)
    assert {:error, :feedback_required} = LoopStore.resolve_review_gate("maintain", " ", name)

    assert {:ok, resolved} =
             LoopStore.resolve_review_gate(
               "maintain",
               "Keep the goal and prioritize liquidity validation.",
               name
             )

    assert resolved.status == "resolved"
    assert resolved.decision == "maintain"
    assert LoopStore.review_context(name) =~ "prioritize liquidity validation"
    assert {:error, :no_open_review_gate} = LoopStore.resolve_review_gate("adjust", "new", name)

    evening = ~U[2026-07-18 13:05:00Z]
    assert {:ok, evening_gate} = LoopStore.ensure_review_gate(evening, name)
    assert evening_gate.window_key == "2026-07-18T22:00:00+09:00"
    assert evening_gate.status == "open"
    assert {:ok, ^evening_gate} = LoopStore.current_review_gate(name)
  end

  defp checkpoint do
    %{
      checkpoint_key: "verify-v1",
      phase: "verify",
      goal_alignment: "aligned",
      summary: "Observed deterministic feedback",
      decision: "Advance the bounded hypothesis",
      evidence: ["test:pass"],
      next_action: "Run the next falsification test",
      outcome: "continue"
    }
  end
end
