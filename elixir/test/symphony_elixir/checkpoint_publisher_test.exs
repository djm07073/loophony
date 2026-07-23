defmodule SymphonyElixir.CheckpointPublisherTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.CheckpointPublisher

  test "appends a timestamped Linear comment for a new semantic checkpoint" do
    issue = %Issue{id: "issue-1", identifier: "HFT-113"}
    checkpoint = checkpoint()
    test_pid = self()

    Application.put_env(:symphony_elixir, :checkpoint_publisher_options,
      comment_lister: fn "issue-1" -> {:ok, []} end,
      comment_creator: fn "issue-1", body ->
        send(test_pid, {:comment_created, body})
        :ok
      end
    )

    on_exit(fn -> Application.delete_env(:symphony_elixir, :checkpoint_publisher_options) end)

    assert {:ok, %{status: "appended", fingerprint: fingerprint}} =
             CheckpointPublisher.publish(issue, checkpoint)

    assert byte_size(fingerprint) == 64
    assert_receive {:comment_created, body}
    assert body =~ "## Loophony Checkpoint"
    assert body =~ "2026-07-20T16:02:00Z UTC"
    assert body =~ "2026-07-21T01:02:00+09:00 KST"
    assert body =~ "기록 시각 (UTC)"
    assert body =~ "기록 시각 (KST)"
    assert body =~ "slot 7"
    assert body =~ "<!-- loophony-checkpoint:#{fingerprint} -->"
  end

  test "does not duplicate an identical checkpoint marker" do
    issue = %Issue{id: "issue-1", identifier: "HFT-113"}
    checkpoint = checkpoint()
    test_pid = self()

    assert {:ok, %{fingerprint: fingerprint}} =
             CheckpointPublisher.publish(issue, checkpoint,
               comment_lister: fn _issue_id -> {:ok, []} end,
               comment_creator: fn _issue_id, body ->
                 send(test_pid, {:first_comment, body})
                 :ok
               end
             )

    assert_receive {:first_comment, first_body}

    assert {:ok, %{status: "already_published", fingerprint: ^fingerprint}} =
             CheckpointPublisher.publish(issue, %{checkpoint | recorded_at: "2026-07-20T16:03:00Z"},
               comment_lister: fn _issue_id -> {:ok, [first_body]} end,
               comment_creator: fn _issue_id, _body -> flunk("duplicate comment was created") end
             )
  end

  test "appends a new revision when semantic evidence changes" do
    issue = %Issue{id: "issue-1", identifier: "HFT-113"}
    checkpoint = checkpoint()

    assert {:ok, %{fingerprint: first_fingerprint}} =
             CheckpointPublisher.publish(issue, checkpoint,
               comment_lister: fn _issue_id -> {:ok, []} end,
               comment_creator: fn _issue_id, _body -> :ok end
             )

    changed = %{checkpoint | evidence: ["terminal slots 8/12"]}

    assert {:ok, %{status: "appended", fingerprint: changed_fingerprint}} =
             CheckpointPublisher.publish(issue, changed,
               comment_lister: fn _issue_id ->
                 {:ok, ["<!-- loophony-checkpoint:#{first_fingerprint} -->"]}
               end,
               comment_creator: fn _issue_id, _body -> :ok end
             )

    refute changed_fingerprint == first_fingerprint
  end

  test "returns lookup and create failures without mutating existing comments" do
    issue = %Issue{id: "issue-1", identifier: "HFT-113"}
    checkpoint = checkpoint()

    assert {:error, {:comment_lookup_failed, :linear_down}} =
             CheckpointPublisher.publish(issue, checkpoint, comment_lister: fn _issue_id -> {:error, :linear_down} end)

    assert {:error, {:comment_lookup_failed, :unexpected}} =
             CheckpointPublisher.publish(issue, checkpoint, comment_lister: fn _issue_id -> :unexpected end)

    assert {:error, {:comment_create_failed, :rejected}} =
             CheckpointPublisher.publish(issue, checkpoint,
               comment_lister: fn _issue_id -> {:ok, []} end,
               comment_creator: fn _issue_id, _body -> {:error, :rejected} end
             )

    assert {:error, {:comment_create_failed, :unexpected}} =
             CheckpointPublisher.publish(issue, checkpoint,
               comment_lister: fn _issue_id -> {:ok, []} end,
               comment_creator: fn _issue_id, _body -> :unexpected end
             )
  end

  test "formats empty, non-string, truncated, and invalid-time evidence defensively" do
    issue = %Issue{id: "issue-1", identifier: "HFT-113"}
    test_pid = self()

    empty_checkpoint = %{
      checkpoint()
      | evidence: [],
        recorded_at: "not-a-time",
        summary: String.duplicate("가", 4_100),
        next_action: 123
    }

    assert {:ok, %{status: "appended"}} =
             CheckpointPublisher.publish(issue, empty_checkpoint,
               comment_lister: fn _issue_id -> {:ok, []} end,
               comment_creator: fn _issue_id, body ->
                 send(test_pid, {:defensive_comment, body})
                 :ok
               end
             )

    assert_receive {:defensive_comment, body}
    assert body =~ "파싱 불가 KST"
    assert body =~ "기록된 증거 없음"
    assert body =~ "가…"
    assert body =~ "123"

    non_string_evidence = %{checkpoint() | evidence: [456]}

    assert {:ok, %{status: "appended"}} =
             CheckpointPublisher.publish(issue, non_string_evidence,
               comment_lister: fn _issue_id -> {:ok, []} end,
               comment_creator: fn _issue_id, body ->
                 send(test_pid, {:numeric_evidence_comment, body})
                 :ok
               end
             )

    assert_receive {:numeric_evidence_comment, numeric_body}
    assert numeric_body =~ "- 456"
  end

  defp checkpoint do
    %{
      checkpoint_key: "hft-113-pilot-cycle",
      phase: "verify",
      goal_alignment: "aligned",
      summary: "slot 7을 검증했다.",
      decision: "slot 8까지 계속한다.",
      evidence: ["terminal slots 7/12"],
      next_action: "slot 8 capture",
      outcome: "continue",
      turn_number: 2,
      recorded_at: "2026-07-20T16:02:00Z"
    }
  end
end
