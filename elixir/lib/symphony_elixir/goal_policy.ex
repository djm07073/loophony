defmodule SymphonyElixir.GoalPolicy do
  @moduledoc """
  Parses the durable goal contract into a typed dispatch policy.

  The parser intentionally recognizes a small machine-readable vocabulary (`Goal version`,
  `Active stage`, and `Mapped stage`) while preserving the original Linear text as the source of
  truth.
  """

  alias SymphonyElixir.{Config, Linear.Issue}

  @markdown_delimiter ~S"[*_`]*"
  @goal_version Regex.compile!(
                  "(?:goal[ _-]*version|목표[ _-]*버전)\\s*#{@markdown_delimiter}\\s*[:=]?\\s*#{@markdown_delimiter}\\s*v?(\\d+)",
                  "iu"
                )
  @active_stage Regex.compile!(
                  "(?:active[ _-]*stage|활성[ _-]*단계)\\s*#{@markdown_delimiter}\\s*[:=]?\\s*#{@markdown_delimiter}\\s*(SC-\\d+)",
                  "iu"
                )
  @mapped_stage Regex.compile!(
                  "(?:mapped[ _-]*stage|mapped[ _-]*criterion|매핑[ _-]*단계)\\s*#{@markdown_delimiter}\\s*[:=]?\\s*#{@markdown_delimiter}\\s*(SC-\\d+)",
                  "iu"
                )
  @criterion ~r/\bSC-\d+\b/iu

  @spec evaluate([Issue.t()], keyword()) :: map()
  def evaluate(issues, opts \\ []) when is_list(issues) and is_list(opts) do
    settings = Keyword.get(opts, :settings, Config.settings!().goal_policy)

    if settings.enabled do
      project_description = first_project_description(issues)
      goal_version = extract_goal_version(project_description)
      active_stage = extract_active_stage(project_description)
      issue_reports = Enum.map(issues, &evaluate_issue(&1, active_stage))
      in_progress_issue_ids = issue_ids_in_state(issues, "In Progress")
      in_progress_count = length(in_progress_issue_ids)

      global_violations =
        []
        |> maybe_add(settings.require_goal_version and is_nil(goal_version), "missing_goal_version")
        |> maybe_add(settings.require_active_stage and is_nil(active_stage), "missing_active_stage")
        |> maybe_add(
          settings.enforce_single_in_progress and in_progress_count > 1,
          "multiple_in_progress"
        )

      issue_violations = Enum.flat_map(issue_reports, & &1.violations)
      violations = Enum.uniq(global_violations ++ issue_violations)
      eligible_issue_ids = eligible_issue_ids(issue_reports, in_progress_issue_ids)

      payload = %{
        enabled: true,
        valid: violations == [],
        goal_version: goal_version,
        active_stage: active_stage,
        candidate_count: length(issues),
        todo_count: count_issues_in_state(issues, "Todo"),
        in_progress_count: in_progress_count,
        eligible_issue_ids: eligible_issue_ids,
        violations: violations,
        issues: issue_reports
      }

      Map.put(payload, :fingerprint, fingerprint(payload))
    else
      %{enabled: false, valid: true, violations: [], eligible_issue_ids: Enum.map(issues, & &1.id)}
    end
  end

  @spec eligible?(map(), Issue.t()) :: boolean()
  def eligible?(%{enabled: false}, %Issue{}), do: true

  def eligible?(policy, %Issue{id: issue_id}) when is_map(policy) and is_binary(issue_id) do
    policy.valid and issue_id in Map.get(policy, :eligible_issue_ids, [])
  end

  @spec review_staleness(map() | nil, map()) :: map()
  def review_staleness(nil, _policy), do: %{stale: false, review_goal_version: nil}

  def review_staleness(review_gate, policy) when is_map(review_gate) and is_map(policy) do
    review_goal_version = extract_goal_version(Map.get(review_gate, :feedback) || Map.get(review_gate, "feedback"))
    current_goal_version = Map.get(policy, :goal_version)

    %{
      stale:
        is_integer(review_goal_version) and is_integer(current_goal_version) and
          review_goal_version != current_goal_version,
      review_goal_version: review_goal_version,
      current_goal_version: current_goal_version
    }
  end

  @spec extract_goal_version(String.t() | nil) :: non_neg_integer() | nil
  def extract_goal_version(text) when is_binary(text) do
    case Regex.run(@goal_version, text, capture: :all_but_first) do
      [version] -> parse_integer(version)
      _ -> nil
    end
  end

  def extract_goal_version(_text), do: nil

  @spec extract_active_stage(String.t() | nil) :: String.t() | nil
  def extract_active_stage(text) when is_binary(text) do
    case Regex.run(@active_stage, text, capture: :all_but_first) do
      [stage] -> String.upcase(stage)
      _ -> nil
    end
  end

  def extract_active_stage(_text), do: nil

  defp evaluate_issue(%Issue{} = issue, active_stage) do
    mapped_stage = extract_mapped_stage(issue)

    violations =
      []
      |> maybe_add(is_nil(mapped_stage), "#{issue.identifier}:missing_mapped_stage")
      |> maybe_add(
        is_binary(active_stage) and is_binary(mapped_stage) and mapped_stage != active_stage,
        "#{issue.identifier}:mapped_stage_mismatch"
      )

    %{
      issue_id: issue.id,
      issue_identifier: issue.identifier,
      mapped_stage: mapped_stage,
      valid: violations == [],
      violations: violations
    }
  end

  defp extract_mapped_stage(%Issue{description: description, title: title}) do
    explicit =
      if is_binary(description) do
        case Regex.run(@mapped_stage, description, capture: :all_but_first) do
          [stage] -> String.upcase(stage)
          _ -> nil
        end
      end

    explicit || first_criterion(title) || first_criterion(description)
  end

  defp first_criterion(text) when is_binary(text) do
    case Regex.run(@criterion, text) do
      [stage] -> String.upcase(stage)
      _ -> nil
    end
  end

  defp first_criterion(_text), do: nil

  defp first_project_description(issues) do
    Enum.find_value(issues, fn
      %Issue{project_description: description} when is_binary(description) and description != "" -> description
      _ -> nil
    end)
  end

  defp eligible_issue_ids(issue_reports, []) do
    issue_reports |> Enum.filter(& &1.valid) |> Enum.map(& &1.issue_id)
  end

  defp eligible_issue_ids(issue_reports, [in_progress_issue_id]) do
    issue_reports
    |> Enum.filter(&(&1.valid and &1.issue_id == in_progress_issue_id))
    |> Enum.map(& &1.issue_id)
  end

  defp eligible_issue_ids(_issue_reports, _multiple_in_progress_issue_ids), do: []

  defp count_issues_in_state(issues, state_name) do
    issues |> issue_ids_in_state(state_name) |> length()
  end

  defp issue_ids_in_state(issues, state_name) do
    normalized_state = normalize_state(state_name)

    Enum.flat_map(issues, fn
      %Issue{id: issue_id, state: state} when is_binary(issue_id) and is_binary(state) ->
        if normalize_state(state) == normalized_state, do: [issue_id], else: []

      _issue ->
        []
    end)
  end

  defp normalize_state(state) when is_binary(state), do: state |> String.trim() |> String.downcase()

  defp maybe_add(violations, true, violation), do: violations ++ [violation]
  defp maybe_add(violations, false, _violation), do: violations

  defp parse_integer(value) do
    case Integer.parse(value) do
      {integer, ""} -> integer
      _ -> nil
    end
  end

  defp fingerprint(payload) do
    payload
    |> Map.drop([:fingerprint])
    |> Jason.encode!()
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end
end
