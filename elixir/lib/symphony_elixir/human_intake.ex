defmodule SymphonyElixir.HumanIntake do
  @moduledoc """
  Converts explicit operator feedback into durable Human issues and materializes prioritized Work
  issues for the normal Loophony dispatch queue.

  Machine-readable markers in the Linear descriptions make the workflow recoverable after daemon
  restarts and partially completed mutations without relying on hidden in-memory state.
  """

  alias SymphonyElixir.{AuditLog, Config, GoalPolicy, Linear.Issue, Tracker}

  @human_marker "<!-- loophony-human-request:v1 -->"
  @work_marker_prefix "<!-- loophony-work-item:v1 human_issue_id="
  @work_marker ~r/<!-- loophony-work-item:v1 human_issue_id=([^\s>]+) -->/
  @mapped_stage ~r/(?:mapped[ _-]*stage|mapped[ _-]*criterion|매핑[ _-]*단계)\s*[*_`]*\s*[:=]?\s*[*_`]*\s*(SC-\d+)/iu
  @criterion ~r/\bSC-\d+\b/iu

  @type reconciliation :: %{
          enabled: boolean(),
          candidates: non_neg_integer(),
          claimed: [map()],
          completed: [map()]
        }

  @spec create_human_issue(map(), map(), keyword()) :: {:ok, Issue.t()} | {:error, term()}
  def create_human_issue(feedback, target, opts \\ [])
      when is_map(feedback) and is_map(target) and is_list(opts) do
    tracker = Keyword.get(opts, :tracker, Tracker)
    settings = Keyword.get(opts, :settings, Config.settings!().intake)
    message = value(feedback, :message)
    request_id = value(feedback, :request_id)
    kind = value(feedback, :kind)

    attributes = %{
      source_issue_id: value(target, :id),
      state_name: settings.todo_state,
      title: human_title(value(feedback, :title), message),
      description: human_description(feedback, target),
      priority: feedback_priority(feedback)
    }

    with :ok <- validate_feedback_context(attributes, message, request_id, kind),
         {:ok, %Issue{} = issue} <- tracker.create_issue(attributes) do
      audit("human_issue.created", issue, %{
        request_id: request_id,
        kind: kind,
        source_issue_id: value(target, :id),
        source_issue_identifier: value(target, :identifier),
        priority: issue.priority
      })

      {:ok, issue}
    end
  end

  @spec reconcile(keyword()) :: {:ok, reconciliation()} | {:error, term()}
  def reconcile(opts \\ []) when is_list(opts) do
    settings = Keyword.get(opts, :settings, Config.settings!().intake)

    if settings.enabled do
      tracker = Keyword.get(opts, :tracker, Tracker)
      state_names = Keyword.get(opts, :state_names, intake_state_names(settings))

      with {:ok, issues} <- tracker.fetch_issues_by_states(state_names),
           {:ok, completed} <- sync_completed_human_issues(issues, tracker, settings),
           {:ok, claimed} <- claim_prioritized_human_issues(issues, tracker, settings) do
        {:ok,
         %{
           enabled: true,
           candidates: count_todo_human_issues(issues, settings),
           claimed: claimed,
           completed: completed
         }}
      end
    else
      {:ok, %{enabled: false, candidates: 0, claimed: [], completed: []}}
    end
  end

  @spec human_issue?(Issue.t() | map()) :: boolean()
  def human_issue?(issue) when is_map(issue) do
    description = value(issue, :description)
    contains_marker?(description, @human_marker) and not contains_work_marker?(description)
  end

  @spec work_issue?(Issue.t() | map()) :: boolean()
  def work_issue?(issue) when is_map(issue), do: is_binary(source_human_issue_id(issue))

  @spec source_human_issue_id(Issue.t() | map()) :: String.t() | nil
  def source_human_issue_id(issue) when is_map(issue) do
    case value(issue, :description) do
      description when is_binary(description) ->
        case Regex.run(@work_marker, description, capture: :all_but_first) do
          [issue_id] -> issue_id
          _ -> nil
        end

      _ ->
        nil
    end
  end

  defp sync_completed_human_issues(issues, tracker, settings) do
    human_by_id =
      issues
      |> Enum.filter(&human_issue?/1)
      |> Map.new(&{&1.id, &1})

    issues
    |> Enum.filter(&(work_issue?(&1) and terminal_issue?(&1, settings)))
    |> Enum.reduce_while({:ok, []}, fn work_issue, {:ok, completed} ->
      case sync_completed_human_issue(work_issue, human_by_id, tracker, settings) do
        {:ok, payload} -> {:cont, {:ok, [payload | completed]}}
        :skip -> {:cont, {:ok, completed}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> reverse_result()
  end

  defp sync_completed_human_issue(work_issue, human_by_id, tracker, settings) do
    case Map.get(human_by_id, source_human_issue_id(work_issue)) do
      %Issue{} = human_issue -> complete_human_issue(human_issue, work_issue, tracker, settings)
      nil -> :skip
    end
  end

  defp claim_prioritized_human_issues(issues, tracker, settings) do
    work_by_human_id =
      work_by_human_id(issues)

    issues
    |> Enum.filter(&pending_human_issue?(&1, work_by_human_id, settings))
    |> Enum.sort_by(&human_issue_sort_key/1)
    |> Enum.take(settings.max_claims_per_poll)
    |> Enum.reduce_while({:ok, []}, fn human_issue, {:ok, claimed} ->
      case claim_human_issue(human_issue, tracker, settings) do
        {:ok, payload} -> {:cont, {:ok, [payload | claimed]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> reverse_result()
  end

  defp claim_human_issue(human_issue, tracker, settings) do
    with {:ok, %Issue{} = work_issue} <- create_work_issue(human_issue, tracker, settings),
         relation <- create_relation(tracker, work_issue, human_issue) do
      payload = claim_payload(human_issue, work_issue, false, relation)
      audit("human_issue.claimed", human_issue, payload)
      audit("work_issue.created", work_issue, payload)
      {:ok, payload}
    end
  end

  defp create_work_issue(human_issue, tracker, settings) do
    tracker.create_issue(%{
      source_issue_id: human_issue.id,
      state_name: settings.todo_state,
      title: work_title(human_issue.title),
      description: work_description(human_issue),
      priority: human_issue.priority
    })
  end

  defp create_relation(tracker, work_issue, human_issue) do
    case tracker.create_issue_relation(work_issue.id, human_issue.id, "related") do
      :ok -> %{linked: true, type: "related"}
      {:error, reason} -> %{linked: false, type: "related", error: inspect(reason)}
    end
  end

  defp complete_human_issue(human_issue, work_issue, tracker, settings) do
    if same_state?(human_issue, settings.completed_state) do
      {:ok, completion_payload(human_issue, work_issue, true)}
    else
      with :ok <- tracker.update_issue_state(human_issue.id, settings.completed_state) do
        payload = completion_payload(human_issue, work_issue, false)
        audit("human_issue.completed", human_issue, payload)
        {:ok, payload}
      end
    end
  end

  defp count_todo_human_issues(issues, settings) do
    work_by_human_id = work_by_human_id(issues)
    Enum.count(issues, &pending_human_issue?(&1, work_by_human_id, settings))
  end

  defp work_by_human_id(issues) do
    issues
    |> Enum.filter(&work_issue?/1)
    |> Enum.reduce(%{}, fn work_issue, acc ->
      Map.put_new(acc, source_human_issue_id(work_issue), work_issue)
    end)
  end

  defp pending_human_issue?(issue, work_by_human_id, settings) do
    human_issue?(issue) and same_state?(issue, settings.todo_state) and
      !Map.has_key?(work_by_human_id, issue.id)
  end

  defp terminal_issue?(issue, settings) when is_map(issue) do
    terminal_states = [settings.completed_state | Config.settings!().tracker.terminal_states]
    Enum.any?(terminal_states, &same_state?(issue, &1))
  rescue
    _error -> same_state?(issue, settings.completed_state)
  end

  defp intake_state_names(settings) do
    tracker = Config.settings!().tracker

    [settings.todo_state, settings.completed_state]
    |> Kernel.++(tracker.active_states)
    |> Kernel.++(tracker.terminal_states)
    |> Enum.uniq()
  end

  defp human_issue_sort_key(issue) do
    {priority_rank(issue.priority), created_at_sort_key(issue.created_at), issue.identifier || issue.id || ""}
  end

  defp priority_rank(priority) when is_integer(priority) and priority in 1..4, do: priority
  defp priority_rank(_priority), do: 5

  defp created_at_sort_key(%DateTime{} = created_at), do: DateTime.to_unix(created_at, :microsecond)
  defp created_at_sort_key(_created_at), do: 0

  defp same_state?(issue, state_name) do
    normalize_state(value(issue, :state)) == normalize_state(state_name)
  end

  defp normalize_state(value) when is_binary(value), do: value |> String.trim() |> String.downcase()
  defp normalize_state(_value), do: ""

  defp validate_feedback_context(attributes, message, request_id, kind) do
    if is_binary(attributes.source_issue_id) and is_binary(attributes.title) and
         is_binary(attributes.description) and is_binary(message) and is_binary(request_id) and
         is_binary(kind) do
      :ok
    else
      {:error, :invalid_human_issue_attributes}
    end
  end

  defp human_title(title, _message) when is_binary(title) and title != "" do
    "[Human] " <> String.slice(String.trim(title), 0, 100)
  end

  defp human_title(_title, message) do
    summary =
      message
      |> to_string()
      |> String.split("\n", parts: 2)
      |> List.first()
      |> String.trim()
      |> String.slice(0, 100)

    "[Human] " <> if(summary == "", do: "Operator feedback", else: summary)
  end

  defp work_title(title) when is_binary(title) do
    "[Work] " <> String.replace_prefix(title, "[Human] ", "")
  end

  defp work_title(_title), do: "[Work] Human request"

  defp human_description(feedback, target) do
    """
    #{@human_marker}
    # Human request

    - Request ID: `#{value(feedback, :request_id)}`
    - Kind: `#{value(feedback, :kind)}`
    - Source issue: #{value(target, :identifier) || value(target, :id)}
    - Source URL: #{value(target, :url) || "unavailable"}
    #{mapped_stage_line(target)}

    ## 요청

    #{value(feedback, :message)}

    ## 완료 조건

    - Loophony가 이 이슈를 priority 순서로 claim한다.
    - 연결된 Work issue가 요청을 구현하고 검증 근거를 남긴다.
    - Work issue가 완료된 뒤 이 Human issue도 완료된다.
    """
    |> String.trim()
  end

  defp mapped_stage_line(target) do
    case target_mapped_stage(target) do
      stage when is_binary(stage) -> "- Mapped stage: #{stage}"
      _ -> ""
    end
  end

  defp target_mapped_stage(target) do
    explicit_mapped_stage(value(target, :description)) ||
      first_criterion(value(target, :title)) ||
      first_criterion(value(target, :description)) ||
      GoalPolicy.extract_active_stage(value(target, :project_description))
  end

  defp explicit_mapped_stage(text) when is_binary(text) do
    case Regex.run(@mapped_stage, text, capture: :all_but_first) do
      [stage] -> String.upcase(stage)
      _ -> nil
    end
  end

  defp explicit_mapped_stage(_text), do: nil

  defp first_criterion(text) when is_binary(text) do
    case Regex.run(@criterion, text) do
      [stage] -> String.upcase(stage)
      _ -> nil
    end
  end

  defp first_criterion(_text), do: nil

  defp work_description(human_issue) do
    """
    #{@work_marker_prefix}#{human_issue.id} -->
    # Loophony Work issue

    - Source Human issue: #{human_issue.identifier}
    - Source URL: #{human_issue.url || "unavailable"}
    - Inherited priority: #{human_issue.priority || 0}

    ## 요청

    #{human_issue.description}

    ## 실행 계약

    - Source Human issue의 요청과 완료 조건을 구현하고 검증한다.
    - 진행 상황과 검증 근거는 이 Work issue의 workpad에 기록한다.
    - 범위를 임의로 확장하지 않고 새 요청은 별도의 Human issue로 남긴다.
    """
    |> String.trim()
  end

  defp claim_payload(human_issue, work_issue, recovered, relation) do
    %{
      human_issue_id: human_issue.id,
      human_issue_identifier: human_issue.identifier,
      work_issue_id: work_issue.id,
      work_issue_identifier: work_issue.identifier,
      priority: human_issue.priority,
      recovered: recovered,
      relation: relation
    }
  end

  defp completion_payload(human_issue, work_issue, already_completed) do
    %{
      human_issue_id: human_issue.id,
      human_issue_identifier: human_issue.identifier,
      work_issue_id: work_issue.id,
      work_issue_identifier: work_issue.identifier,
      already_completed: already_completed
    }
  end

  defp reverse_result({:ok, entries}), do: {:ok, Enum.reverse(entries)}
  defp reverse_result({:error, _reason} = error), do: error

  defp contains_marker?(value, marker) when is_binary(value), do: String.contains?(value, marker)
  defp contains_marker?(_value, _marker), do: false

  defp contains_work_marker?(value) when is_binary(value), do: Regex.match?(@work_marker, value)
  defp contains_work_marker?(_value), do: false

  defp normalize_priority(priority) when is_integer(priority) and priority in 0..4, do: priority
  defp normalize_priority(_priority), do: nil

  defp feedback_priority(feedback) do
    case {value(feedback, :kind), normalize_priority(value(feedback, :priority))} do
      {"preempt", nil} -> 1
      {_kind, priority} -> priority
    end
  end

  defp audit(action, issue, metadata) do
    _ =
      AuditLog.record_async(action, %{
        actor: "human_intake",
        resource_type: "linear_issue",
        resource_id: issue.id,
        metadata: Map.put(metadata, :issue_identifier, issue.identifier)
      })

    :ok
  end

  defp value(map, key) when is_map(map) do
    case Map.fetch(map, key) do
      {:ok, found} -> found
      :error -> Map.get(map, Atom.to_string(key))
    end
  end
end
