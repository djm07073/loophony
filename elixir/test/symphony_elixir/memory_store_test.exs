defmodule SymphonyElixir.MemoryStoreTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.Linear.Issue
  alias SymphonyElixir.MemoryStore

  test "disabled memory reports its state and rejects searches" do
    settings = %{Config.settings!().memory | enabled: false}
    name = __MODULE__.DisabledStore
    start_supervised!({MemoryStore, name: name, settings: settings})

    assert %{
             enabled: false,
             available: false,
             retrieval: "onyx-opensearch-hybrid"
           } = MemoryStore.status(name)

    assert {:error, :memory_disabled} = MemoryStore.search("왜 실패했어?", %{}, name)
    assert {:error, :invalid_query} = MemoryStore.search("  ", %{}, name)
  end

  test "checkpoint evidence keeps issue, session, decision, and provenance together" do
    checkpoint = %{
      issue_id: "issue-1",
      issue_identifier: "LOOP-1",
      checkpoint_key: "verify-v1",
      turn_number: 2,
      phase: "verify",
      goal_alignment: "aligned",
      summary: "통합 테스트가 실패했다",
      decision: "schema migration을 수정한다",
      evidence: ["mix test: 1 failure"],
      next_action: "migration 재실행",
      outcome: "continue",
      recorded_at: "2026-07-20T12:00:00Z"
    }

    document =
      MemoryStore.checkpoint_document_for_test(checkpoint, %{
        session_id: "thread-1-turn-2"
      })

    assert document.source_type == "checkpoint"
    assert document.source_key == "issue-1:verify-v1"
    assert document.issue_identifier == "LOOP-1"
    assert document.session_id == "thread-1-turn-2"
    assert document.content =~ "schema migration을 수정한다"
    assert document.content =~ "mix test: 1 failure"
    assert document.metadata.phase == "verify"
  end

  test "Linear issue snapshots keep retrieval fields and omit repeated project context" do
    issue = %Issue{
      id: "issue-1",
      identifier: "LOOP-1",
      title: "Index follow-up work",
      description: "Persist the newly created follow-up issue.",
      project_description: "This project description is large and repeated on every issue.",
      state: "In Progress",
      priority: 2,
      labels: ["memory", "follow-up"],
      blocked_by: [%{id: "blocker-1", identifier: "LOOP-0", state: "Done"}],
      url: "https://linear.app/example/issue/LOOP-1",
      created_at: ~U[2026-07-20 11:00:00Z],
      updated_at: ~U[2026-07-20 12:00:00Z]
    }

    document = MemoryStore.issue_document_for_test(issue)

    assert document.source_type == "linear_issue"
    assert document.source_key == "issue-1"
    assert document.recorded_at == "2026-07-20T12:00:00Z"
    assert document.content =~ "Persist the newly created follow-up issue."
    assert document.content =~ "LOOP-0 (Done)"
    assert document.metadata.linear_state == "In Progress"
    assert document.metadata.labels == ["memory", "follow-up"]
    refute document.content =~ issue.project_description
  end

  test "Linear project descriptions become a first-class stable memory document" do
    issue = %Issue{
      id: "issue-1",
      identifier: "LOOP-1",
      project_id: "project-1",
      project_name: "ProbEdge",
      project_slug: "probedge-123",
      project_description: "Build a causal, net-of-cost prediction-market trading system.",
      project_url: "https://linear.app/example/project/probedge-123",
      project_updated_at: ~U[2026-07-20 12:30:00Z],
      updated_at: ~U[2026-07-20 12:00:00Z]
    }

    document = MemoryStore.project_document_for_test(issue, "loophony-test")

    assert document.source_type == "linear_project"
    assert document.source_key == "project-1"
    assert document.issue_identifier == "PROJECT"
    assert document.title == "Linear project: ProbEdge"
    assert document.recorded_at == "2026-07-20T12:30:00Z"
    assert document.content =~ "Canonical project description"
    assert document.content =~ "net-of-cost prediction-market trading system"
    assert document.metadata.project_slug == "probedge-123"

    provenance = MemoryStore.provenance_url_for_test(document, "loophony-test")
    assert MemoryStore.decode_provenance_url_for_test(provenance)["source_type"] == "linear_project"
  end

  test "indexing fetched issues stores one project objective before issue snapshots" do
    test_pid = self()
    client = memory_client(test_pid)
    settings = %{Config.settings!().memory | enabled: true, project: "loophony-test"}
    name = __MODULE__.ProjectStore
    start_supervised!({MemoryStore, name: name, settings: settings, client: client})

    issues = [
      %Issue{
        id: "issue-1",
        identifier: "LOOP-1",
        title: "First issue",
        description: "First issue body",
        project_id: "project-1",
        project_name: "ProbEdge",
        project_slug: "probedge-123",
        project_description: "Canonical North Star",
        project_updated_at: ~U[2026-07-20 12:30:00Z],
        updated_at: ~U[2026-07-20 12:00:00Z]
      },
      %Issue{
        id: "issue-2",
        identifier: "LOOP-2",
        title: "Second issue",
        description: "Second issue body",
        project_id: "project-1",
        project_name: "ProbEdge",
        project_slug: "probedge-123",
        project_description: "Canonical North Star",
        project_updated_at: ~U[2026-07-20 12:30:00Z],
        updated_at: ~U[2026-07-20 12:10:00Z]
      }
    ]

    assert :ok = MemoryStore.index_issues(issues, name)

    payloads =
      for _index <- 1..3 do
        assert_receive {:ingested, payload}
        payload
      end

    assert Enum.map(payloads, & &1.document.metadata["source_type"]) == [
             "linear_project",
             "linear_issue",
             "linear_issue"
           ]

    project_payload = hd(payloads).document
    assert project_payload.semantic_identifier == "Linear project: ProbEdge"
    assert project_payload.metadata["evidence_id"] =~ "mem_"
    assert hd(project_payload.sections).text =~ "Canonical North Star"
  end

  test "long documents are split into contextual paragraph-aware sections" do
    document = %{
      source_type: "linear_issue",
      source_key: "issue-1",
      issue_id: "issue-1",
      issue_identifier: "LOOP-1",
      title: "Large issue",
      content:
        String.duplicate("first paragraph ", 450) <>
          "\n\n" <> String.duplicate("second paragraph ", 450),
      metadata: %{},
      recorded_at: "2026-07-20T12:00:00Z"
    }

    sections = MemoryStore.indexed_sections_for_test(document, "loophony-test")

    assert length(sections) > 1

    assert Enum.all?(sections, fn section ->
             section.text =~ "Loophony project: loophony-test" and
               section.text =~ "Source type: linear_issue" and
               section.text =~ "--- LOOPHONY CONTENT ---"
           end)
  end

  test "memory configuration resolves the Onyx API key" do
    previous_key = System.get_env("LOOPHONY_MEMORY_ONYX_API_KEY")
    System.put_env("LOOPHONY_MEMORY_ONYX_API_KEY", "onyx-test-key")
    on_exit(fn -> restore_env("LOOPHONY_MEMORY_ONYX_API_KEY", previous_key) end)

    write_workflow_file!(Workflow.workflow_file_path(),
      memory_enabled: true,
      memory_onyx_api_url: "http://127.0.0.1:8780",
      memory_onyx_api_key: "$LOOPHONY_MEMORY_ONYX_API_KEY",
      memory_project: "loophony-test",
      memory_search_limit: 20
    )

    memory = Config.settings!().memory
    assert memory.enabled
    assert memory.onyx_api_url == "http://127.0.0.1:8780"
    assert memory.onyx_api_key == "onyx-test-key"
    assert memory.project == "loophony-test"
    assert memory.search_limit == 20
  end

  test "Onyx provenance URL preserves exact evidence and session identifiers" do
    url =
      MemoryStore.provenance_url_for_test(
        %{
          source_type: "session_event",
          source_key: "session-1:ended",
          issue_id: "issue-1",
          issue_identifier: "LOOP-1",
          session_id: "session-1",
          title: "LOOP-1 session ended",
          content: "completed",
          metadata: %{
            session_event: "ended",
            session_status: "completed",
            thread_id: "thread-1",
            turn_id: "turn-1"
          },
          recorded_at: "2026-07-20T12:00:00Z"
        },
        "loophony-test"
      )

    provenance = MemoryStore.decode_provenance_url_for_test(url)
    assert provenance["project"] == "loophony-test"
    assert provenance["evidence_id"] =~ "mem_"
    assert provenance["issue_identifier"] == "LOOP-1"
    assert provenance["session_id"] == "session-1"
    assert provenance["session_event"] == "ended"
    assert provenance["session_status"] == "completed"
    assert provenance["thread_id"] == "thread-1"
  end

  test "Onyx search uses exact project tags and reconstructs provenance from result links" do
    test_pid = self()

    document = %{
      source_type: "checkpoint",
      source_key: "issue-1:verify-v1",
      issue_id: "issue-1",
      issue_identifier: "LOOP-1",
      session_id: "session-1",
      title: "LOOP-1 verify checkpoint",
      content: "한국어로 기록된 실패 원인",
      metadata: %{phase: "verify"},
      recorded_at: "2026-07-20T12:00:00Z"
    }

    link = MemoryStore.provenance_url_for_test(document, "loophony-test")

    client = %{
      health: fn _settings -> {:ok, %{}} end,
      current_search_settings: fn _settings ->
        {:ok, %{"model_name" => "intfloat/multilingual-e5-base", "model_dim" => 768}}
      end,
      ingest: fn payload, _settings ->
        send(test_pid, {:ingested, payload})
        {:ok, %{"document_id" => "onyx-document-1"}}
      end,
      search: fn request, _settings ->
        send(test_pid, {:searched, request})

        {:ok,
         %{
           "search_docs" => [
             %{
               "semantic_identifier" => "LOOP-1 verify checkpoint",
               "content" => "한국어로 기록된 실패 원인",
               "link" => link,
               "source_type" => "file",
               "score" => 0.82,
               "updated_at" => "2026-07-20T12:00:00Z"
             }
           ]
         }}
      end
    }

    settings = %{
      Config.settings!().memory
      | enabled: true,
        onyx_api_key: "test-key",
        project: "loophony-test"
    }

    name = __MODULE__.OnyxStore
    start_supervised!({MemoryStore, name: name, settings: settings, client: client})
    Process.sleep(20)
    assert_receive {:searched, %{search_query: "loophony health canary"}}

    assert {:ok, indexed} = MemoryStore.put_document(document, name)
    assert indexed.evidence_id =~ "mem_"
    assert_receive {:ingested, %{document: %{source: "ingestion_api", metadata: metadata}}}
    assert metadata["project"] == "loophony-test"
    assert metadata["issue_identifier"] == "LOOP-1"

    assert {:ok, %{matches: [match]}} =
             MemoryStore.search("왜 실패했어?", %{issue_identifier: "LOOP-1"}, name)

    assert_receive {:searched, request}
    assert request.search_query == "왜 실패했어?"
    assert request.run_query_expansion == false
    assert request.include_content == true
    assert request.stream == false
    assert request.hybrid_alpha == 0.5

    assert request.filters.tags == [
             %{tag_key: "issue_identifier", tag_value: "LOOP-1"}
           ]

    assert match["issue_identifier"] == "LOOP-1"
    assert match["session_id"] == "session-1"
    assert match["content"] == "한국어로 기록된 실패 원인"
    assert match["fused_score"] == 0.82

    assert {:ok, %{matches: [_match]}} =
             MemoryStore.search(
               "현재 진행상황",
               %{
                 source_types: ["linear_project", "checkpoint", "session_summary"]
               },
               name
             )

    assert_receive {:searched, source_request}

    assert source_request.filters.tags == [
             %{tag_key: "source_type", tag_value: "linear_project"},
             %{tag_key: "source_type", tag_value: "checkpoint"},
             %{tag_key: "source_type", tag_value: "session_summary"}
           ]
  end

  test "unchanged stable documents are not embedded twice in one runtime" do
    test_pid = self()
    client = memory_client(test_pid)
    settings = %{Config.settings!().memory | enabled: true, project: "loophony-test"}
    name = __MODULE__.DeduplicatingStore
    start_supervised!({MemoryStore, name: name, settings: settings, client: client})

    document = %{
      source_type: "linear_issue",
      source_key: "issue-1",
      issue_id: "issue-1",
      issue_identifier: "LOOP-1",
      title: "Stable issue",
      content: "No changes",
      metadata: %{linear_state: "Todo"},
      recorded_at: "2026-07-20T12:00:00Z"
    }

    assert {:ok, %{embedded: true}} = MemoryStore.put_document(document, name)
    assert {:ok, %{embedded: false, already_existed: true}} = MemoryStore.put_document(document, name)
    assert_receive {:ingested, _payload}
    refute_receive {:ingested, _payload}, 50
  end

  test "a completed Codex session emits a deterministic searchable summary" do
    test_pid = self()
    client = memory_client(test_pid)
    settings = %{Config.settings!().memory | enabled: true, project: "loophony-test"}
    name = __MODULE__.SessionSummaryStore
    start_supervised!({MemoryStore, name: name, settings: settings, client: client})

    issue = %Issue{
      id: "issue-1",
      identifier: "LOOP-1",
      title: "Track [SC-03] progress",
      description: "Calibrate the fair-value model for SC-03.",
      project_description: """
      **Active stage:** SC-03 — Fair-value calibration
      **Outcome:** Build a fair-value and net-of-cost trading system.
      **Why:** Capture prediction-market mispricing before settlement.
      """
    }

    MemoryStore.record_codex_event_for_test(
      issue,
      %{
        event: :session_started,
        session_id: "session-1",
        thread_id: "thread-1",
        turn_id: "turn-1",
        timestamp: ~U[2026-07-20 12:00:00Z]
      },
      name
    )

    MemoryStore.record_codex_event_for_test(
      issue,
      %{
        event: :notification,
        session_id: "session-1",
        timestamp: ~U[2026-07-20 12:01:00Z],
        payload: %{
          "method" => "item/completed",
          "params" => %{
            "item" => %{
              "id" => "message-1",
              "type" => "agentMessage",
              "text" => "Implemented the issue snapshot index and verified the tests."
            }
          }
        }
      },
      name
    )

    MemoryStore.record_codex_event_for_test(
      issue,
      %{
        event: :turn_completed,
        session_id: "session-1",
        thread_id: "thread-1",
        turn_id: "turn-1",
        timestamp: ~U[2026-07-20 12:02:00Z]
      },
      name
    )

    _status = MemoryStore.status(name)

    payloads =
      for _index <- 1..4 do
        assert_receive {:ingested, payload}
        payload
      end

    summary =
      Enum.find(payloads, fn payload ->
        payload.document.metadata["source_type"] == "session_summary"
      end)

    assert summary.document.id =~ "loophony_"
    assert summary.document.metadata["session_id"] == "session-1"
    assert summary.document.metadata["session_status"] == "completed"
    assert summary.document.metadata["schema_version"] == "2"

    summary_metadata = Jason.decode!(summary.document.metadata["loophony_metadata"])
    assert summary_metadata["mapped_success_criteria"] == ["SC-03"]
    assert summary_metadata["goal_context"] =~ "Active stage: SC-03"
    assert hd(summary.document.sections).text =~ "Goal lens:"
    assert hd(summary.document.sections).text =~ "Mapped success criteria: SC-03"
    assert hd(summary.document.sections).text =~ "Implemented the issue snapshot index"
  end

  test "operator-preempted sessions are indexed as resumable navigation evidence" do
    test_pid = self()
    client = memory_client(test_pid)
    settings = %{Config.settings!().memory | enabled: true, project: "loophony-test"}
    name = __MODULE__.PreemptedSessionStore
    start_supervised!({MemoryStore, name: name, settings: settings, client: client})

    issue = %Issue{
      id: "issue-preempted",
      identifier: "LOOP-2",
      title: "Replan SC-03 work",
      project_description: "**Active stage:** SC-03 — Fair-value calibration"
    }

    MemoryStore.record_codex_event_for_test(
      issue,
      %{
        event: :session_started,
        session_id: "session-preempted",
        thread_id: "thread-preempted",
        turn_id: "turn-preempted",
        timestamp: ~U[2026-07-20 12:00:00Z]
      },
      name
    )

    MemoryStore.record_codex_event_for_test(
      issue,
      %{
        event: :turn_preempted,
        session_id: "session-preempted",
        preempt_request_id: "request-preempted",
        timestamp: ~U[2026-07-20 12:01:00Z]
      },
      name
    )

    _status = MemoryStore.status(name)

    payloads =
      for _index <- 1..3 do
        assert_receive {:ingested, payload}
        payload
      end

    summary =
      Enum.find(payloads, fn payload ->
        payload.document.metadata["source_type"] == "session_summary"
      end)

    ended =
      Enum.find(payloads, fn payload ->
        payload.document.metadata["source_type"] == "session_event" and
          payload.document.metadata["session_status"] == "preempted"
      end)

    assert summary.document.metadata["session_status"] == "preempted"
    assert hd(summary.document.sections).text =~ "Status: preempted"

    assert Jason.decode!(ended.document.metadata["loophony_metadata"])["preempt_request_id"] ==
             "request-preempted"

    refute Enum.any?(payloads, &(&1.document.metadata["source_type"] == "error"))
  end

  test "functional search failures degrade health and open the circuit breaker" do
    test_pid = self()
    {:ok, counter} = Agent.start_link(fn -> 0 end)

    client = %{
      health: fn _settings -> {:ok, %{}} end,
      current_search_settings: fn _settings -> {:ok, %{"model_name" => "test", "model_dim" => 8}} end,
      ingest: fn _payload, _settings -> {:ok, %{}} end,
      search: fn request, _settings ->
        call_number = Agent.get_and_update(counter, fn count -> {count + 1, count + 1} end)
        send(test_pid, {:search_call, call_number, request.search_query})

        if call_number == 1 do
          {:ok, %{"search_docs" => []}}
        else
          {:error, :search_backend_down}
        end
      end
    }

    settings = %{
      Config.settings!().memory
      | enabled: true,
        failure_threshold: 2,
        circuit_breaker_ms: 60_000,
        health_probe_interval_ms: 120_000
    }

    name = __MODULE__.CircuitStore
    start_supervised!({MemoryStore, name: name, settings: settings, client: client})
    assert_receive {:search_call, 1, "loophony health canary"}, 500

    assert {:error, {:memory_search_failed, :search_backend_down}} = MemoryStore.search("first failure", %{}, name)
    assert {:error, {:memory_search_failed, :search_backend_down}} = MemoryStore.search("second failure", %{}, name)

    assert %{
             available: false,
             degraded: true,
             search_healthy: false,
             consecutive_search_failures: 2,
             circuit_open: true
           } = MemoryStore.status(name)

    assert {:error, {:memory_search_failed, :circuit_open}} = MemoryStore.search("short-circuited", %{}, name)
    assert Agent.get(counter, & &1) == 3
  end

  defp memory_client(test_pid) do
    %{
      health: fn _settings -> {:ok, %{}} end,
      current_search_settings: fn _settings ->
        {:ok, %{"model_name" => "intfloat/multilingual-e5-base", "model_dim" => 768}}
      end,
      ingest: fn payload, _settings ->
        send(test_pid, {:ingested, payload})
        {:ok, %{"document_id" => payload.document.id}}
      end,
      search: fn _request, _settings -> {:ok, %{"search_docs" => []}} end
    }
  end
end
