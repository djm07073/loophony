defmodule SymphonyElixir.HandoffTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.Config.Schema.Handoff, as: HandoffSettings
  alias SymphonyElixir.{Handoff, Linear.Issue}

  test "unmarked issues route to the Sol planner session" do
    issue = %Issue{id: "plan-1", description: "bounded decision"}

    assert {:ok, %{role: :planner, model: "gpt-5.6-sol", source_issue_id: nil}} =
             Handoff.route(issue, handoff_settings())
  end

  test "disabled handoff uses the configured Codex command defaults" do
    assert {:ok, %{role: :default, model: nil, source_issue_id: nil}} =
             Handoff.route(%Issue{id: "legacy"}, %{handoff_settings() | enabled: false})

    assert :ok =
             Handoff.verify_session_start(%Issue{id: "legacy"}, %{
               role: :default,
               model: nil,
               source_issue_id: nil
             })
  end

  test "handoff markers route fresh executor sessions to Spark or Sol" do
    for model <- ["gpt-5.3-codex-spark", "gpt-5.6-sol"] do
      issue = %Issue{
        id: "execute-#{model}",
        description: "#{Handoff.marker("plan-1", model)}\n실행 계약"
      }

      assert {:ok, %{role: :executor, model: ^model, source_issue_id: "plan-1"}} =
               Handoff.route(issue, handoff_settings())

      assert Handoff.handoff_issue?(issue)
      assert Handoff.successor_of?(issue, "plan-1")
      assert Handoff.source_issue_id(issue) == "plan-1"
      assert Handoff.target_model(issue) == model
    end
  end

  test "marker accessors support string keys and fail closed for missing or duplicate markers" do
    marked = %{"description" => Handoff.marker("plan-1", "gpt-5.6-sol")}
    assert Handoff.source_issue_id(marked) == "plan-1"
    assert Handoff.target_model(marked) == "gpt-5.6-sol"
    assert Handoff.marker_count(marked) == 1

    unmarked = %{description: nil}
    assert Handoff.source_issue_id(unmarked) == nil
    assert Handoff.target_model(unmarked) == nil
    assert Handoff.marker_count(unmarked) == 0
    refute Handoff.handoff_issue?(unmarked)

    duplicate = %{
      description:
        Handoff.marker("plan-1", "gpt-5.6-sol") <>
          Handoff.marker("plan-2", "gpt-5.3-codex-spark")
    }

    assert Handoff.source_issue_id(duplicate) == nil
    assert Handoff.target_model(duplicate) == nil
    assert Handoff.successor_of?(duplicate, "plan-2")
  end

  test "handoff routing fails closed for a model outside the configured allowlist" do
    issue = %Issue{
      id: "execute-invalid",
      description: Handoff.marker("plan-1", "unknown-model")
    }

    assert {:error, {:handoff_model_not_allowed, "unknown-model", ["gpt-5.6-sol", "gpt-5.3-codex-spark"]}} =
             Handoff.route(issue, handoff_settings())
  end

  test "handoff routing rejects self references and duplicate markers" do
    self_referencing = %Issue{
      id: "execute-self",
      description: Handoff.marker("execute-self", "gpt-5.6-sol")
    }

    assert {:error, {:handoff_self_reference, "execute-self"}} =
             Handoff.route(self_referencing, handoff_settings())

    duplicate = %Issue{
      id: "execute-duplicate",
      description:
        Handoff.marker("plan-1", "gpt-5.6-sol") <>
          "\n" <> Handoff.marker("plan-1", "gpt-5.3-codex-spark")
    }

    assert {:error, {:multiple_handoff_markers, 2}} =
             Handoff.route(duplicate, handoff_settings())
  end

  test "execution sessions start only after their source issue is terminal" do
    issue = %Issue{
      id: "execute-1",
      description: Handoff.marker("plan-1", "gpt-5.3-codex-spark")
    }

    assert {:ok, route} = Handoff.route(issue, handoff_settings())

    assert :ok =
             Handoff.verify_session_start(
               issue,
               route,
               source_issue_fetcher: fn ["plan-1"] ->
                 {:ok, [%Issue{id: "plan-1", state: "Done"}]}
               end
             )

    assert {:error, {:handoff_source_not_terminal, "plan-1"}} =
             Handoff.verify_session_start(
               issue,
               route,
               source_issue_fetcher: fn ["plan-1"] ->
                 {:ok, [%Issue{id: "plan-1", state: "In Progress"}]}
               end
             )

    assert {:error, {:handoff_source_not_found, "plan-1"}} =
             Handoff.verify_session_start(
               issue,
               route,
               source_issue_fetcher: fn ["plan-1"] -> {:ok, []} end
             )

    assert {:error, {:handoff_self_reference, "execute-1"}} =
             Handoff.verify_session_start(
               issue,
               %{route | source_issue_id: "execute-1"},
               source_issue_fetcher: fn _ids -> flunk("self-reference must fail before lookup") end
             )

    assert {:error, {:handoff_source_lookup_failed, "plan-1", :offline}} =
             Handoff.verify_session_start(
               issue,
               route,
               source_issue_fetcher: fn ["plan-1"] -> {:error, :offline} end
             )

    assert {:error, {:handoff_source_lookup_invalid, "plan-1", :unexpected}} =
             Handoff.verify_session_start(
               issue,
               route,
               source_issue_fetcher: fn ["plan-1"] -> :unexpected end
             )

    assert {:error, {:handoff_source_not_terminal, "plan-1"}} =
             Handoff.verify_session_start(
               issue,
               route,
               source_issue_fetcher: fn ["plan-1"] ->
                 {:ok, [%Issue{id: "plan-1", state: nil}]}
               end
             )
  end

  test "session prompt context makes planner and executor contracts explicit" do
    write_workflow_file!(Workflow.workflow_file_path(), handoff_enabled: true)

    planner =
      Handoff.prompt_context(%Issue{id: "plan-1"}, %{
        role: :planner,
        model: "gpt-5.6-sol",
        source_issue_id: nil
      })

    assert planner =~ "planning and judgment"
    assert planner =~ "gpt-5.3-codex-spark"
    assert planner =~ "loophony-handoff:v1"

    executor =
      Handoff.prompt_context(%Issue{id: "execute-1"}, %{
        role: :executor,
        model: "gpt-5.3-codex-spark",
        source_issue_id: "plan-1"
      })

    assert executor =~ "execution"
    assert executor =~ "plan-1"
    assert executor =~ "gpt-5.3-codex-spark"

    assert Handoff.prompt_context(%Issue{}, %{role: :default, model: nil, source_issue_id: nil}) == ""
  end

  defp handoff_settings do
    %HandoffSettings{
      enabled: true,
      planner_model: "gpt-5.6-sol",
      default_execution_model: "gpt-5.3-codex-spark",
      allowed_models: ["gpt-5.6-sol", "gpt-5.3-codex-spark"]
    }
  end
end
