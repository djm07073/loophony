defmodule SymphonyElixir.Handoff do
  @moduledoc """
  Defines the durable Linear issue marker used to hand work from one Codex session to another.

  A handoff issue names its source issue and target model in its description. The scheduler reads
  that marker before starting Codex and selects the model for the new top-level session. Unmarked
  issues use the configured planner model.
  """

  alias SymphonyElixir.{Config, Linear.Issue, Tracker}

  @marker ~r/<!--\s*loophony-handoff:v1\s+source_issue_id=([^\s>]+)\s+target_model=([^\s>]+)\s*-->/iu

  @type role :: :default | :planner | :executor
  @type route :: %{
          role: role(),
          model: String.t() | nil,
          source_issue_id: String.t() | nil
        }

  @spec marker(String.t(), String.t()) :: String.t()
  def marker(source_issue_id, target_model)
      when is_binary(source_issue_id) and is_binary(target_model) do
    "<!-- loophony-handoff:v1 source_issue_id=#{source_issue_id} target_model=#{target_model} -->"
  end

  @spec route(Issue.t() | map(), map() | nil) :: {:ok, route()} | {:error, term()}
  def route(issue, settings \\ nil) when is_map(issue) do
    settings = settings || Config.settings!().handoff

    if settings.enabled do
      route_enabled_issue(issue, settings)
    else
      {:ok, %{role: :default, model: nil, source_issue_id: nil}}
    end
  end

  @spec verify_session_start(Issue.t() | map(), route(), keyword()) ::
          :ok | {:error, term()}
  def verify_session_start(issue, route, opts \\ [])
      when is_map(issue) and is_map(route) and is_list(opts) do
    do_verify_session_start(issue, route, opts)
  end

  defp do_verify_session_start(
         issue,
         %{role: :executor, source_issue_id: source_issue_id},
         opts
       )
       when is_map(issue) and is_binary(source_issue_id) and is_list(opts) do
    source_fetcher = Keyword.get(opts, :source_issue_fetcher, &Tracker.fetch_issue_states_by_ids/1)

    with false <- source_issue_id == value(issue, :id),
         {:ok, source_issues} <- source_fetcher.([source_issue_id]),
         %Issue{} = source_issue <- Enum.find(source_issues, &(value(&1, :id) == source_issue_id)),
         true <- terminal_source_issue?(source_issue) do
      :ok
    else
      true -> {:error, {:handoff_self_reference, source_issue_id}}
      nil -> {:error, {:handoff_source_not_found, source_issue_id}}
      false -> {:error, {:handoff_source_not_terminal, source_issue_id}}
      {:error, reason} -> {:error, {:handoff_source_lookup_failed, source_issue_id, reason}}
      other -> {:error, {:handoff_source_lookup_invalid, source_issue_id, other}}
    end
  end

  defp do_verify_session_start(_issue, _route, _opts), do: :ok

  @spec handoff_issue?(Issue.t() | map()) :: boolean()
  def handoff_issue?(issue) when is_map(issue), do: marker_count(issue) > 0

  @spec source_issue_id(Issue.t() | map()) :: String.t() | nil
  def source_issue_id(issue) when is_map(issue) do
    case parse_marker(issue) do
      {:ok, {source_issue_id, _target_model}} -> source_issue_id
      _ -> nil
    end
  end

  @spec marker_count(Issue.t() | map()) :: non_neg_integer()
  def marker_count(issue) when is_map(issue) do
    case value(issue, :description) do
      description when is_binary(description) -> length(Regex.scan(@marker, description))
      _ -> 0
    end
  end

  @spec target_model(Issue.t() | map()) :: String.t() | nil
  def target_model(issue) when is_map(issue) do
    case parse_marker(issue) do
      {:ok, {_source_issue_id, target_model}} -> target_model
      _ -> nil
    end
  end

  @spec successor_of?(Issue.t() | map(), String.t()) :: boolean()
  def successor_of?(issue, source_issue_id)
      when is_map(issue) and is_binary(source_issue_id) do
    source_issue_id in source_issue_ids(issue)
  end

  @spec prompt_context(Issue.t() | map(), route()) :: String.t()
  def prompt_context(issue, %{role: :executor, model: model, source_issue_id: source_issue_id})
      when is_map(issue) and is_binary(model) and is_binary(source_issue_id) do
    """
    ## Loophony session handoff

    - Session role: execution
    - Source issue ID: `#{source_issue_id}`
    - Selected top-level model: `#{model}`
    - This is a fresh execution session. Implement and test only the bounded contract copied into
      this issue. Do not rely on the source session's hidden context.
    - If another distinct judgment or implementation cycle remains, create a new linked Todo issue
      with a `loophony-handoff:v1` marker and finish this issue without executing the successor.
    """
    |> String.trim()
  end

  def prompt_context(issue, %{role: :planner, model: model})
      when is_map(issue) and is_binary(model) do
    settings = Config.settings!().handoff

    """
    ## Loophony session handoff

    - Session role: planning and judgment
    - Selected top-level model: `#{model}`
    - Default execution model: `#{settings.default_execution_model}`
    - Allowed successor models: #{Enum.join(settings.allowed_models, ", ")}
    - When new repository coding or test work is required, finish the judgment first and create or
      reuse exactly one linked Todo execution issue. Copy the full implementation scope,
      reproduction evidence, file boundaries, acceptance checks, validation commands, risks, and
      non-goals into that issue. Do not implement that successor inside this session.
    - Use `#{marker("<SOURCE_ISSUE_ID>", "<TARGET_MODEL>")}` once in the successor description.
      Choose `#{settings.default_execution_model}` for bounded, unambiguous implementation and
      `#{settings.planner_model}` when the next session still requires complex judgment. The source
      issue ID must be this issue's immutable Linear ID, not its human-readable identifier.
    - Transition this issue to Done only after the linked Todo successor and terminal handoff
      checkpoint are both durable. The scheduler starts the successor in a fresh session.
    """
    |> String.trim()
  end

  def prompt_context(_issue, _route), do: ""

  defp route_enabled_issue(issue, settings) do
    case parse_marker(issue) do
      {:ok, {source_issue_id, target_model}} ->
        cond do
          source_issue_id == value(issue, :id) ->
            {:error, {:handoff_self_reference, source_issue_id}}

          target_model not in settings.allowed_models ->
            {:error, {:handoff_model_not_allowed, target_model, settings.allowed_models}}

          true ->
            {:ok, %{role: :executor, model: target_model, source_issue_id: source_issue_id}}
        end

      :none ->
        {:ok, %{role: :planner, model: settings.planner_model, source_issue_id: nil}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp parse_marker(issue) do
    case marker_values(issue) do
      [] -> :none
      [[source_issue_id, target_model]] -> {:ok, {source_issue_id, target_model}}
      markers -> {:error, {:multiple_handoff_markers, length(markers)}}
    end
  end

  defp source_issue_ids(issue) do
    issue
    |> marker_values()
    |> Enum.map(&List.first/1)
    |> Enum.filter(&is_binary/1)
    |> Enum.uniq()
  end

  defp marker_values(issue) do
    case value(issue, :description) do
      description when is_binary(description) ->
        Regex.scan(@marker, description, capture: :all_but_first)

      _ ->
        []
    end
  end

  defp terminal_source_issue?(issue) do
    state = issue |> value(:state) |> normalize_state()

    Config.settings!().tracker.terminal_states
    |> Enum.map(&normalize_state/1)
    |> Enum.member?(state)
  end

  defp normalize_state(value) when is_binary(value), do: value |> String.trim() |> String.downcase()
  defp normalize_state(_value), do: ""

  defp value(map, key) when is_map(map) do
    case Map.fetch(map, key) do
      {:ok, found} -> found
      :error -> Map.get(map, Atom.to_string(key))
    end
  end
end
