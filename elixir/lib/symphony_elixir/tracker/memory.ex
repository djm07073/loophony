defmodule SymphonyElixir.Tracker.Memory do
  @moduledoc """
  In-memory tracker adapter used for tests and local development.
  """

  @behaviour SymphonyElixir.Tracker

  alias SymphonyElixir.Linear.Issue

  @spec fetch_candidate_issues() :: {:ok, [Issue.t()]} | {:error, term()}
  def fetch_candidate_issues do
    {:ok, issue_entries()}
  end

  @spec fetch_issues_by_states([String.t()]) :: {:ok, [Issue.t()]} | {:error, term()}
  def fetch_issues_by_states(state_names) do
    normalized_states =
      state_names
      |> Enum.map(&normalize_state/1)
      |> MapSet.new()

    {:ok,
     Enum.filter(issue_entries(), fn %Issue{state: state} ->
       MapSet.member?(normalized_states, normalize_state(state))
     end)}
  end

  @spec fetch_issue_states_by_ids([String.t()]) :: {:ok, [Issue.t()]} | {:error, term()}
  def fetch_issue_states_by_ids(issue_ids) do
    wanted_ids = MapSet.new(issue_ids)

    {:ok,
     Enum.filter(issue_entries(), fn %Issue{id: id} ->
       MapSet.member?(wanted_ids, id)
     end)}
  end

  @spec resolve_issue(String.t()) :: {:ok, map()} | {:error, term()}
  def resolve_issue(issue_identifier) when is_binary(issue_identifier) do
    issue =
      Enum.find(issue_entries(), fn %Issue{identifier: identifier} ->
        is_binary(identifier) and String.downcase(identifier) == String.downcase(issue_identifier)
      end)

    case issue do
      %Issue{id: id, identifier: identifier, url: url} ->
        {:ok, %{id: id, identifier: identifier, url: url}}

      nil ->
        {:error, :issue_not_found}
    end
  end

  @spec create_issue(map()) :: {:ok, Issue.t()} | {:error, term()}
  def create_issue(attributes) when is_map(attributes) do
    source_issue_id = value(attributes, :source_issue_id)
    source = Enum.find(issue_entries(), &(&1.id == source_issue_id))

    if match?(%Issue{}, source) do
      issue = build_issue(source, attributes)
      Application.put_env(:symphony_elixir, :memory_tracker_issues, issue_entries() ++ [issue])
      send_event({:memory_tracker_issue_created, issue})
      {:ok, issue}
    else
      {:error, :issue_creation_context_not_found}
    end
  end

  @spec create_issue_relation(String.t(), String.t(), String.t()) :: :ok | {:error, term()}
  def create_issue_relation(issue_id, related_issue_id, relation_type) do
    send_event({:memory_tracker_issue_relation, issue_id, related_issue_id, relation_type})
    :ok
  end

  @spec create_comment(String.t(), String.t()) :: :ok | {:error, term()}
  def create_comment(issue_id, body) do
    send_event({:memory_tracker_comment, issue_id, body})
    :ok
  end

  @spec update_issue_state(String.t(), String.t()) :: :ok | {:error, term()}
  def update_issue_state(issue_id, state_name) do
    updated =
      Enum.map(issue_entries(), fn
        %Issue{id: ^issue_id} = issue -> %{issue | state: state_name}
        issue -> issue
      end)

    Application.put_env(:symphony_elixir, :memory_tracker_issues, updated)
    send_event({:memory_tracker_state_update, issue_id, state_name})
    :ok
  end

  defp build_issue(source, attributes) do
    suffix = System.unique_integer([:positive, :monotonic])

    %Issue{
      id: "memory-issue-#{suffix}",
      identifier: "MEM-#{suffix}",
      title: value(attributes, :title),
      description: value(attributes, :description),
      project_id: source.project_id,
      project_name: source.project_name,
      project_slug: source.project_slug,
      project_description: source.project_description,
      project_url: source.project_url,
      project_updated_at: source.project_updated_at,
      priority: value(attributes, :priority),
      state: value(attributes, :state_name),
      assignee_id: source.assignee_id,
      labels: source.labels,
      created_at: DateTime.utc_now(),
      updated_at: DateTime.utc_now()
    }
  end

  defp configured_issues do
    Application.get_env(:symphony_elixir, :memory_tracker_issues, [])
  end

  defp issue_entries do
    Enum.filter(configured_issues(), &match?(%Issue{}, &1))
  end

  defp send_event(message) do
    case Application.get_env(:symphony_elixir, :memory_tracker_recipient) do
      pid when is_pid(pid) -> send(pid, message)
      _ -> :ok
    end
  end

  defp normalize_state(state) when is_binary(state) do
    state
    |> String.trim()
    |> String.downcase()
  end

  defp normalize_state(_state), do: ""

  defp value(map, key), do: Map.get(map, key) || Map.get(map, Atom.to_string(key))
end
