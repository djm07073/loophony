defmodule SymphonyElixir.Linear.Adapter do
  @moduledoc """
  Linear-backed tracker adapter.
  """

  @behaviour SymphonyElixir.Tracker

  alias SymphonyElixir.Linear.{Client, Issue}

  @issue_creation_context_query """
  query SymphonyIssueCreationContext($sourceIssueId: String!, $stateName: String!) {
    issue(id: $sourceIssueId) {
      team {
        id
        states(filter: {name: {eq: $stateName}}, first: 1) {
          nodes {
            id
          }
        }
      }
      project {
        id
      }
      assignee {
        id
      }
      labels {
        nodes {
          id
        }
      }
    }
  }
  """

  @create_issue_mutation """
  mutation SymphonyCreateIssue(
    $teamId: String!
    $projectId: String
    $stateId: String!
    $assigneeId: String
    $labelIds: [String!]
    $title: String!
    $description: String!
    $priority: Int
  ) {
    issueCreate(
      input: {
        teamId: $teamId
        projectId: $projectId
        stateId: $stateId
        assigneeId: $assigneeId
        labelIds: $labelIds
        title: $title
        description: $description
        priority: $priority
      }
    ) {
      success
      issue {
        id
        identifier
        title
        description
        priority
        state {
          name
        }
        project {
          id
          name
          slugId
          description
          content
          url
          updatedAt
        }
        branchName
        url
        assignee {
          id
        }
        labels {
          nodes {
            name
          }
        }
        createdAt
        updatedAt
      }
    }
  }
  """

  @create_issue_relation_mutation """
  mutation SymphonyCreateIssueRelation(
    $issueId: String!
    $relatedIssueId: String!
    $type: IssueRelationType!
  ) {
    issueRelationCreate(
      input: {issueId: $issueId, relatedIssueId: $relatedIssueId, type: $type}
    ) {
      success
    }
  }
  """

  @create_comment_mutation """
  mutation SymphonyCreateComment($issueId: String!, $body: String!) {
    commentCreate(input: {issueId: $issueId, body: $body}) {
      success
    }
  }
  """

  @comments_query """
  query SymphonyCheckpointComments($issueId: String!) {
    issue(id: $issueId) {
      comments(first: 100) {
        nodes {
          body
        }
      }
    }
  }
  """

  @update_state_mutation """
  mutation SymphonyUpdateIssueState($issueId: String!, $stateId: String!) {
    issueUpdate(id: $issueId, input: {stateId: $stateId}) {
      success
    }
  }
  """

  @state_lookup_query """
  query SymphonyResolveStateId($issueId: String!, $stateName: String!) {
    issue(id: $issueId) {
      team {
        states(filter: {name: {eq: $stateName}}, first: 1) {
          nodes {
            id
          }
        }
      }
    }
  }
  """

  @issue_lookup_query """
  query SymphonyResolveIssue($issueIdentifier: String!) {
    issue(id: $issueIdentifier) {
      id
      identifier
      url
    }
  }
  """

  @spec fetch_candidate_issues() :: {:ok, [term()]} | {:error, term()}
  def fetch_candidate_issues, do: client_module().fetch_candidate_issues()

  @spec fetch_issues_by_states([String.t()]) :: {:ok, [term()]} | {:error, term()}
  def fetch_issues_by_states(states), do: client_module().fetch_issues_by_states(states)

  @spec fetch_issue_states_by_ids([String.t()]) :: {:ok, [term()]} | {:error, term()}
  def fetch_issue_states_by_ids(issue_ids), do: client_module().fetch_issue_states_by_ids(issue_ids)

  @spec resolve_issue(String.t()) :: {:ok, map()} | {:error, term()}
  def resolve_issue(issue_identifier) when is_binary(issue_identifier) do
    with {:ok, response} <-
           client_module().graphql(@issue_lookup_query, %{issueIdentifier: issue_identifier}),
         %{"id" => id, "identifier" => identifier} = issue <- get_in(response, ["data", "issue"]) do
      {:ok, %{id: id, identifier: identifier, url: issue["url"]}}
    else
      {:error, reason} -> {:error, reason}
      _ -> {:error, :issue_not_found}
    end
  end

  @spec create_issue(map()) :: {:ok, Issue.t()} | {:error, term()}
  def create_issue(attributes) when is_map(attributes) do
    source_issue_id = value(attributes, :source_issue_id)
    state_name = value(attributes, :state_name)

    with :ok <- validate_issue_create_attributes(source_issue_id, state_name),
         {:ok, context} <- issue_creation_context(source_issue_id, state_name),
         {:ok, response} <- client_module().graphql(@create_issue_mutation, creation_variables(attributes, context)),
         true <- get_in(response, ["data", "issueCreate", "success"]) == true,
         %{} = raw_issue <- get_in(response, ["data", "issueCreate", "issue"]),
         %Issue{} = issue <- Client.normalize_issue_for_test(raw_issue) do
      {:ok, issue}
    else
      {:error, reason} -> {:error, reason}
      _ -> {:error, :issue_create_failed}
    end
  end

  @spec create_issue_relation(String.t(), String.t(), String.t()) :: :ok | {:error, term()}
  def create_issue_relation(issue_id, related_issue_id, relation_type)
      when is_binary(issue_id) and is_binary(related_issue_id) and is_binary(relation_type) do
    variables = %{issueId: issue_id, relatedIssueId: related_issue_id, type: relation_type}

    with {:ok, response} <- client_module().graphql(@create_issue_relation_mutation, variables),
         true <- get_in(response, ["data", "issueRelationCreate", "success"]) == true do
      :ok
    else
      {:error, reason} -> {:error, reason}
      _ -> {:error, :issue_relation_create_failed}
    end
  end

  @spec create_comment(String.t(), String.t()) :: :ok | {:error, term()}
  def create_comment(issue_id, body) when is_binary(issue_id) and is_binary(body) do
    with {:ok, response} <- client_module().graphql(@create_comment_mutation, %{issueId: issue_id, body: body}),
         true <- get_in(response, ["data", "commentCreate", "success"]) == true do
      :ok
    else
      false -> {:error, :comment_create_failed}
      {:error, reason} -> {:error, reason}
      _ -> {:error, :comment_create_failed}
    end
  end

  @spec comment_bodies(String.t()) :: {:ok, [String.t()]} | {:error, term()}
  def comment_bodies(issue_id) when is_binary(issue_id) do
    case client_module().graphql(@comments_query, %{issueId: issue_id}) do
      {:ok, response} -> normalize_comment_bodies(response)
      {:error, reason} -> {:error, reason}
      other -> {:error, other}
    end
  end

  @spec update_issue_state(String.t(), String.t()) :: :ok | {:error, term()}
  def update_issue_state(issue_id, state_name)
      when is_binary(issue_id) and is_binary(state_name) do
    with {:ok, state_id} <- resolve_state_id(issue_id, state_name),
         {:ok, response} <-
           client_module().graphql(@update_state_mutation, %{issueId: issue_id, stateId: state_id}),
         true <- get_in(response, ["data", "issueUpdate", "success"]) == true do
      :ok
    else
      false -> {:error, :issue_update_failed}
      {:error, reason} -> {:error, reason}
      _ -> {:error, :issue_update_failed}
    end
  end

  defp client_module do
    Application.get_env(:symphony_elixir, :linear_client_module, Client)
  end

  defp normalize_comment_bodies(response) do
    case get_in(response, ["data", "issue", "comments", "nodes"]) do
      comments when is_list(comments) -> {:ok, Enum.flat_map(comments, &comment_body/1)}
      _ -> {:error, :invalid_comment_response}
    end
  end

  defp comment_body(%{"body" => body}) when is_binary(body), do: [body]
  defp comment_body(%{body: body}) when is_binary(body), do: [body]
  defp comment_body(_comment), do: []

  defp resolve_state_id(issue_id, state_name) do
    with {:ok, response} <-
           client_module().graphql(@state_lookup_query, %{issueId: issue_id, stateName: state_name}),
         state_id when is_binary(state_id) <-
           get_in(response, ["data", "issue", "team", "states", "nodes", Access.at(0), "id"]) do
      {:ok, state_id}
    else
      {:error, reason} -> {:error, reason}
      _ -> {:error, :state_not_found}
    end
  end

  defp issue_creation_context(source_issue_id, state_name) do
    variables = %{sourceIssueId: source_issue_id, stateName: state_name}

    with {:ok, response} <- client_module().graphql(@issue_creation_context_query, variables),
         %{} = issue <- get_in(response, ["data", "issue"]),
         team_id when is_binary(team_id) <- get_in(issue, ["team", "id"]),
         state_id when is_binary(state_id) <- get_in(issue, ["team", "states", "nodes", Access.at(0), "id"]) do
      {:ok,
       %{
         team_id: team_id,
         project_id: get_in(issue, ["project", "id"]),
         state_id: state_id,
         assignee_id: get_in(issue, ["assignee", "id"]),
         label_ids: issue |> get_in(["labels", "nodes"]) |> List.wrap() |> Enum.flat_map(&entity_id/1)
       }}
    else
      {:error, reason} -> {:error, reason}
      _ -> {:error, :issue_creation_context_not_found}
    end
  end

  defp creation_variables(attributes, context) do
    %{
      teamId: context.team_id,
      projectId: context.project_id,
      stateId: context.state_id,
      assigneeId: context.assignee_id,
      labelIds: context.label_ids,
      title: value(attributes, :title),
      description: value(attributes, :description),
      priority: normalize_priority(value(attributes, :priority))
    }
  end

  defp validate_issue_create_attributes(source_issue_id, state_name)
       when is_binary(source_issue_id) and is_binary(state_name),
       do: :ok

  defp validate_issue_create_attributes(_source_issue_id, _state_name),
    do: {:error, :invalid_issue_create_attributes}

  defp entity_id(%{"id" => id}) when is_binary(id), do: [id]
  defp entity_id(_entity), do: []

  defp normalize_priority(priority) when is_integer(priority) and priority in 0..4, do: priority
  defp normalize_priority(_priority), do: nil

  defp value(map, key), do: Map.get(map, key) || Map.get(map, Atom.to_string(key))
end
