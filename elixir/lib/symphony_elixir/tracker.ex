defmodule SymphonyElixir.Tracker do
  @moduledoc """
  Adapter boundary for issue tracker reads and writes.
  """

  alias SymphonyElixir.{Config, MemoryStore}

  @callback fetch_candidate_issues() :: {:ok, [term()]} | {:error, term()}
  @callback fetch_issues_by_states([String.t()]) :: {:ok, [term()]} | {:error, term()}
  @callback fetch_issue_states_by_ids([String.t()]) :: {:ok, [term()]} | {:error, term()}
  @callback resolve_issue(String.t()) :: {:ok, map()} | {:error, term()}
  @callback create_issue(map()) :: {:ok, term()} | {:error, term()}
  @callback create_issue_relation(String.t(), String.t(), String.t()) :: :ok | {:error, term()}
  @callback create_comment(String.t(), String.t()) :: :ok | {:error, term()}
  @callback update_issue_state(String.t(), String.t()) :: :ok | {:error, term()}

  @spec fetch_candidate_issues() :: {:ok, [term()]} | {:error, term()}
  def fetch_candidate_issues do
    adapter().fetch_candidate_issues() |> index_fetched_issues()
  end

  @spec fetch_issues_by_states([String.t()]) :: {:ok, [term()]} | {:error, term()}
  def fetch_issues_by_states(states) do
    adapter().fetch_issues_by_states(states) |> index_fetched_issues()
  end

  @spec fetch_issue_states_by_ids([String.t()]) :: {:ok, [term()]} | {:error, term()}
  def fetch_issue_states_by_ids(issue_ids) do
    adapter().fetch_issue_states_by_ids(issue_ids) |> index_fetched_issues()
  end

  @spec resolve_issue(String.t()) :: {:ok, map()} | {:error, term()}
  def resolve_issue(issue_identifier) do
    adapter().resolve_issue(issue_identifier)
  end

  @spec create_issue(map()) :: {:ok, term()} | {:error, term()}
  def create_issue(attributes) when is_map(attributes) do
    adapter().create_issue(attributes)
  end

  @spec create_issue_relation(String.t(), String.t(), String.t()) :: :ok | {:error, term()}
  def create_issue_relation(issue_id, related_issue_id, relation_type)
      when is_binary(issue_id) and is_binary(related_issue_id) and is_binary(relation_type) do
    adapter().create_issue_relation(issue_id, related_issue_id, relation_type)
  end

  @spec create_comment(String.t(), String.t()) :: :ok | {:error, term()}
  def create_comment(issue_id, body) do
    adapter().create_comment(issue_id, body)
  end

  @spec update_issue_state(String.t(), String.t()) :: :ok | {:error, term()}
  def update_issue_state(issue_id, state_name) do
    adapter().update_issue_state(issue_id, state_name)
  end

  @spec adapter() :: module()
  def adapter do
    case Config.settings!().tracker.kind do
      "memory" -> SymphonyElixir.Tracker.Memory
      _ -> SymphonyElixir.Linear.Adapter
    end
  end

  defp index_fetched_issues({:ok, issues} = result) when is_list(issues) do
    MemoryStore.index_issues(issues)
    result
  end

  defp index_fetched_issues(result), do: result
end
