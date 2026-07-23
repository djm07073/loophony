defmodule SymphonyElixir.MemoryStore do
  @moduledoc """
  Durable cross-session loop memory indexed by Onyx and OpenSearch.

  Loophony normalizes contextual sections and preserves provenance. Onyx owns embeddings and
  OpenSearch keyword/vector retrieval; Codex answers from the returned evidence. SQLite remains
  the issue-local checkpoint ledger used to backfill the external index.
  """

  use GenServer

  require Logger

  alias SymphonyElixir.{AuditLog, Config}
  alias SymphonyElixir.Linear.Issue
  alias SymphonyElixir.LoopStore
  alias SymphonyElixir.Memory.OnyxClient

  @retry_ms 5_000
  @max_content_chars 40_000
  # Keep supplied sections comfortably below the embedding model's 512-token ceiling for typical
  # English/code text. Onyx still performs the authoritative tokenizer-aware split for multilingual
  # or unusually dense content.
  @max_section_chars 1_200
  @max_summary_items 12
  @max_session_messages 8
  @max_goal_context_chars 520
  @document_schema_version "2"
  @source_types ~w(linear_project linear_issue session_summary checkpoint agent_final error session_event)
  @filterable_metadata ~w(schema_version linear_state phase outcome session_status)
  @content_marker "--- LOOPHONY CONTENT ---"

  defmodule State do
    @moduledoc false
    defstruct [
      :client,
      :last_error,
      :search_settings,
      :settings,
      :probe_timer_ref,
      :circuit_open_until_ms,
      :last_search_success_at,
      :last_ingestion_success_at,
      enabled: false,
      available: false,
      connection_healthy: false,
      search_healthy: false,
      ingestion_healthy: nil,
      consecutive_search_failures: 0,
      connected_once: false,
      backfill_running: false,
      indexed_versions: %{},
      sessions: %{}
    ]
  end

  @type search_filters :: %{
          optional(:issue_identifier) => String.t(),
          optional(:session_id) => String.t(),
          optional(:source_types) => [String.t()],
          optional(:from) => String.t(),
          optional(:to) => String.t(),
          optional(:limit) => pos_integer()
        }

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @spec index_checkpoint(map(), map()) :: :ok
  def index_checkpoint(checkpoint, context \\ %{}) when is_map(checkpoint) and is_map(context) do
    GenServer.cast(__MODULE__, {:index_document, checkpoint_document(checkpoint, context)})
  end

  @spec index_issue(Issue.t()) :: :ok
  def index_issue(%Issue{} = issue), do: index_issue(issue, __MODULE__)

  @spec index_issue(Issue.t(), GenServer.server()) :: :ok
  def index_issue(%Issue{} = issue, server), do: GenServer.cast(server, {:index_issue, issue})

  @spec index_issues([Issue.t()]) :: :ok
  def index_issues(issues) when is_list(issues), do: index_issues(issues, __MODULE__)

  @spec index_issues([Issue.t()], GenServer.server()) :: :ok
  def index_issues(issues, server) when is_list(issues) do
    GenServer.cast(server, {:index_issues, Enum.filter(issues, &match?(%Issue{}, &1))})
  end

  @spec record_codex_event(Issue.t(), map()) :: :ok
  def record_codex_event(%Issue{} = issue, message) when is_map(message) do
    GenServer.cast(__MODULE__, {:codex_event, issue, message})
  end

  @doc false
  @spec record_codex_event_for_test(Issue.t(), map(), GenServer.server()) :: :ok
  def record_codex_event_for_test(%Issue{} = issue, message, server) when is_map(message) do
    GenServer.cast(server, {:codex_event, issue, message})
  end

  @spec put_document(map()) :: {:ok, map()} | {:error, term()}
  def put_document(document), do: put_document(document, __MODULE__)

  @spec put_document(map(), GenServer.server()) :: {:ok, map()} | {:error, term()}
  def put_document(document, server) when is_map(document) do
    call(server, {:put_document, document}, 180_000)
  end

  @spec search(String.t(), search_filters()) :: {:ok, map()} | {:error, term()}
  def search(query, filters \\ %{}), do: search(query, filters, __MODULE__)

  @spec search(String.t(), search_filters(), GenServer.server()) :: {:ok, map()} | {:error, term()}
  def search(query, filters, server) when is_binary(query) and is_map(filters) do
    case String.trim(query) do
      "" -> {:error, :invalid_query}
      normalized -> call(server, {:search, normalized, filters}, 90_000)
    end
  end

  @spec get_session(String.t()) :: {:ok, map()} | {:error, term()}
  def get_session(session_id), do: get_session(session_id, __MODULE__)

  @spec get_session(String.t(), GenServer.server()) :: {:ok, map()} | {:error, term()}
  def get_session(session_id, server) when is_binary(session_id) do
    case String.trim(session_id) do
      "" -> {:error, :invalid_session_id}
      normalized -> call(server, {:get_session, normalized}, 90_000)
    end
  end

  @spec status() :: map()
  def status, do: status(__MODULE__)

  @spec status(GenServer.server()) :: map()
  def status(server), do: status(server, 30_000)

  @spec status(GenServer.server(), timeout()) :: map()
  def status(server, timeout) do
    case call(server, :status, timeout) do
      %{} = payload -> payload
      {:error, reason} -> %{enabled: false, available: false, error: inspect(reason)}
    end
  end

  @doc false
  @spec checkpoint_document_for_test(map(), map()) :: map()
  def checkpoint_document_for_test(checkpoint, context), do: checkpoint_document(checkpoint, context)

  @doc false
  @spec issue_document_for_test(Issue.t()) :: map()
  def issue_document_for_test(%Issue{} = issue), do: issue_document(issue)

  @doc false
  @spec project_document_for_test(Issue.t(), String.t()) :: map() | nil
  def project_document_for_test(%Issue{} = issue, fallback_project) do
    project_document(issue, fallback_project)
  end

  @doc false
  @spec indexed_sections_for_test(map(), String.t()) :: [map()]
  def indexed_sections_for_test(document, project) do
    document |> normalize_document() |> indexed_sections(project)
  end

  @doc false
  @spec provenance_url_for_test(map(), String.t()) :: String.t()
  def provenance_url_for_test(document, project) do
    document |> normalize_document() |> provenance_url(project)
  end

  @doc false
  @spec decode_provenance_url_for_test(String.t()) :: map()
  def decode_provenance_url_for_test(url), do: decode_provenance_url(url)

  @impl true
  def init(opts) do
    settings = Keyword.get(opts, :settings, Config.settings!().memory)
    client = Keyword.get(opts, :client, default_client())
    state = %State{enabled: settings.enabled, settings: settings, client: client}

    if settings.enabled, do: send(self(), :connect)
    {:ok, state}
  end

  @impl true
  def handle_call(:status, _from, state), do: {:reply, status_payload(state), state}

  def handle_call({:put_document, _document}, _from, %State{enabled: false} = state),
    do: {:reply, {:error, :memory_disabled}, state}

  def handle_call({:put_document, document}, _from, state) do
    {reply, next_state} = persist_document(document, state)
    {:reply, reply, next_state}
  end

  def handle_call({:search, _query, _filters}, _from, %State{enabled: false} = state),
    do: {:reply, {:error, :memory_disabled}, state}

  def handle_call({:search, query, filters}, _from, state) do
    {reply, next_state} = run_search(query, filters, state)
    {:reply, reply, next_state}
  end

  def handle_call({:get_session, _session_id}, _from, %State{enabled: false} = state),
    do: {:reply, {:error, :memory_disabled}, state}

  def handle_call({:get_session, session_id}, _from, state) do
    {reply, next_state} = fetch_session(session_id, state)
    {:reply, reply, next_state}
  end

  @impl true
  def handle_cast({:index_document, _document}, %State{enabled: false} = state), do: {:noreply, state}

  def handle_cast({:index_document, document}, state) do
    {_reply, next_state} = persist_document(document, state)
    {:noreply, next_state}
  end

  def handle_cast({:index_issue, issue}, state) do
    next_state = persist_project_description([issue], state)
    {_reply, next_state} = persist_document(issue_document(issue), next_state)
    {:noreply, next_state}
  end

  def handle_cast({:index_issues, issues}, state) do
    next_state =
      issues
      |> persist_project_description(state)
      |> then(fn state ->
        Enum.reduce(issues, state, fn issue, acc ->
          {_reply, updated} = persist_document(issue_document(issue), acc)
          updated
        end)
      end)

    {:noreply, next_state}
  end

  def handle_cast({:codex_event, _issue, _message}, %State{enabled: false} = state),
    do: {:noreply, state}

  def handle_cast({:codex_event, issue, message}, state) do
    {:noreply, persist_codex_event(issue, message, state)}
  end

  @impl true
  def handle_info(:connect, %State{enabled: false} = state), do: {:noreply, state}

  def handle_info(:connect, state) do
    {result, next_state} = functional_health_probe(state)

    case result do
      :ok ->
        unless state.connected_once, do: send(self(), :backfill)
        Logger.info("Loophony memory connected onyx=#{onyx_label(state.settings.onyx_api_url)}")
        {:noreply, schedule_health_probe(%{next_state | connected_once: true})}

      {:error, reason} ->
        Logger.warning("Loophony Onyx memory unavailable: #{inspect(reason)}")
        Process.send_after(self(), :connect, @retry_ms)
        {:noreply, schedule_health_probe(next_state)}
    end
  end

  def handle_info(:health_probe, %State{enabled: false} = state), do: {:noreply, state}

  def handle_info(:health_probe, state) do
    {_result, next_state} = functional_health_probe(%{state | probe_timer_ref: nil})
    {:noreply, schedule_health_probe(next_state)}
  end

  def handle_info(:backfill, %State{backfill_running: true} = state), do: {:noreply, state}

  def handle_info(:backfill, state) do
    server = self()

    Task.start(fn ->
      result = backfill_checkpoints(server)
      send(server, {:backfill_complete, result})
    end)

    {:noreply, %{state | backfill_running: true}}
  end

  def handle_info({:backfill_complete, {:ok, count}}, state) do
    Logger.info("Loophony Onyx checkpoint backfill complete count=#{count}")
    {:noreply, %{state | backfill_running: false}}
  end

  def handle_info({:backfill_complete, {:error, reason}}, state) do
    Logger.warning("Loophony Onyx checkpoint backfill failed: #{inspect(reason)}")
    {:noreply, %{state | backfill_running: false, last_error: reason}}
  end

  def handle_info(_message, state), do: {:noreply, state}

  defp status_payload(state) do
    search_settings = state.search_settings || %{}

    %{
      enabled: state.enabled,
      available: state.available,
      degraded: state.enabled and (!state.search_healthy or state.ingestion_healthy == false),
      connection_healthy: state.connection_healthy,
      search_healthy: state.search_healthy,
      ingestion_healthy: state.ingestion_healthy,
      consecutive_search_failures: state.consecutive_search_failures,
      circuit_open: circuit_open?(state),
      circuit_open_for_ms: circuit_open_for_ms(state),
      last_search_success_at: state.last_search_success_at,
      last_ingestion_success_at: state.last_ingestion_success_at,
      backend: "onyx",
      search_backend: "OpenSearch 3.6",
      onyx: onyx_label(state.settings.onyx_api_url),
      project: state.settings.project,
      backfill_running: state.backfill_running,
      embedding_provider: "onyx-model-server",
      embedding_model: map_value(search_settings, "model_name"),
      embedding_dimensions: map_value(search_settings, "model_dim"),
      retrieval: "onyx-opensearch-hybrid",
      answer_generator: "codex",
      retrieval_llm: false,
      document_schema_version: @document_schema_version,
      document_types: @source_types,
      contextual_sections: true,
      error: state.last_error && inspect(state.last_error)
    }
  end

  defp backfill_checkpoints(server) do
    case LoopStore.all_checkpoints() do
      {:ok, checkpoints} ->
        Enum.reduce_while(
          checkpoints,
          {:ok, 0},
          &backfill_checkpoint(&1, &2, server)
        )

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp backfill_checkpoint(checkpoint, {:ok, count}, server) do
    context = Map.take(checkpoint, [:session_id, :thread_id, :turn_id])

    case put_document(checkpoint_document(checkpoint, context), server) do
      {:ok, _payload} -> {:cont, {:ok, count + 1}}
      {:error, reason} -> {:halt, {:error, reason}}
    end
  end

  defp persist_document(document, state) do
    normalized = normalize_document(document)
    version = document_version(normalized)
    version_key = {normalized.source_type, normalized.source_key}

    if Map.get(state.indexed_versions, version_key) == version do
      reply =
        {:ok,
         %{
           evidence_id: normalized.evidence_id,
           document_id: onyx_document_id(normalized, state.settings.project),
           source_type: normalized.source_type,
           issue_identifier: normalized.issue_identifier,
           session_id: normalized.session_id,
           embedded: false,
           already_existed: true,
           warning: nil
         }}

      reply_with_ingestion_state(reply, state)
    else
      payload = ingestion_payload(normalized, state.settings.project)

      result =
        case state.client.ingest.(payload, state.settings) do
          {:ok, response} ->
            {:ok,
             %{
               evidence_id: normalized.evidence_id,
               document_id: map_value(response, "document_id"),
               source_type: normalized.source_type,
               issue_identifier: normalized.issue_identifier,
               session_id: normalized.session_id,
               embedded: true,
               already_existed: map_value(response, "already_existed", false),
               warning: nil
             }}

          {:error, reason} ->
            {:error, {:memory_ingestion_failed, reason}}
        end

      {reply, next_state} = reply_with_ingestion_state(result, state)

      case reply do
        {:ok, _payload} ->
          {reply, %{next_state | indexed_versions: Map.put(next_state.indexed_versions, version_key, version)}}

        {:error, _reason} ->
          {reply, next_state}
      end
    end
  end

  defp ingestion_payload(document, project) do
    metadata = onyx_metadata(document, project)

    %{
      document: %{
        id: onyx_document_id(document, project),
        semantic_identifier: document.title,
        title: document.title,
        source: "ingestion_api",
        sections: indexed_sections(document, project),
        metadata: metadata,
        doc_updated_at: document.recorded_at
      }
    }
  end

  defp onyx_metadata(document, project) do
    filterable = Map.take(document.metadata, @filterable_metadata)

    %{
      "project" => project,
      "evidence_id" => document.evidence_id,
      "source_type" => document.source_type,
      "source_key" => document.source_key,
      "issue_id" => document.issue_id,
      "issue_identifier" => document.issue_identifier,
      "session_id" => document.session_id,
      "recorded_at" => document.recorded_at,
      "content_hash" => digest(document.content),
      "schema_version" => @document_schema_version,
      "loophony_metadata" => Jason.encode!(document.metadata)
    }
    |> Map.merge(filterable)
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
    |> Map.new()
  end

  defp indexed_sections(document, project) do
    prefix = contextual_prefix(document, project)
    link = provenance_url(document, project)

    document.content
    |> content_chunks()
    |> Enum.map(fn chunk ->
      %{
        text: Enum.join([prefix, @content_marker, chunk], "\n"),
        link: link
      }
    end)
  end

  defp contextual_prefix(document, project) do
    goal_context = map_value(document.metadata, "goal_context")

    [
      "Loophony project: #{project}",
      "Evidence ID: #{document.evidence_id}",
      "Source type: #{document.source_type}",
      "Issue: #{document.issue_identifier}",
      "Session: #{document.session_id || "none"}",
      "Recorded at: #{document.recorded_at}",
      "Title: #{document.title}",
      if(is_binary(goal_context) and goal_context != "", do: "Goal lens: #{goal_context}")
    ]
    |> Enum.reject(&is_nil/1)
    |> Enum.join("\n")
  end

  defp provenance_url(document, project) do
    query =
      %{
        "project" => project,
        "evidence_id" => document.evidence_id,
        "source_type" => document.source_type,
        "issue_id" => document.issue_id,
        "issue_identifier" => document.issue_identifier,
        "session_id" => document.session_id,
        "recorded_at" => document.recorded_at,
        "session_event" => map_value(document.metadata, "session_event"),
        "session_status" => map_value(document.metadata, "session_status"),
        "linear_state" => map_value(document.metadata, "linear_state"),
        "phase" => map_value(document.metadata, "phase"),
        "outcome" => map_value(document.metadata, "outcome"),
        "thread_id" => map_value(document.metadata, "thread_id"),
        "turn_id" => map_value(document.metadata, "turn_id")
      }
      |> Enum.reject(fn {_key, value} -> is_nil(value) end)
      |> Map.new()
      |> URI.encode_query()

    "loophony://memory/#{URI.encode(document.evidence_id)}?#{query}"
  end

  defp run_search(query, filters, state) do
    if circuit_open?(state) do
      {{:error, {:memory_search_failed, :circuit_open}}, state}
    else
      normalized = normalize_search_filters(filters, state.settings.search_limit)
      request = search_request(query, normalized, state.settings.project)

      result =
        case state.client.search.(request, state.settings) do
          {:ok, %{"error" => error}} when is_binary(error) and error != "" ->
            {:error, {:memory_search_failed, {:onyx_search, error}}}

          {:ok, payload} ->
            matches =
              payload
              |> result_entries()
              |> Enum.map(&search_match/1)
              |> Enum.filter(&valid_search_match?(&1, state.settings.project, normalized))
              |> Enum.uniq_by(&map_value(&1, "evidence_id"))
              |> Enum.take(normalized.limit)

            {:ok,
             %{
               query: query,
               retrieval: "onyx-opensearch-hybrid",
               matches: matches,
               warning: nil,
               search_modes_used: ["opensearch-keyword", "opensearch-vector"]
             }}

          {:error, reason} ->
            {:error, {:memory_search_failed, reason}}
        end

      reply_with_search_state(result, state)
    end
  end

  defp search_request(query, filters, project) do
    tags = search_scope_tags(filters, project)

    onyx_filters =
      %{
        source_type: ["file"],
        tags: tags,
        time_cutoff: filters.from
      }
      |> Enum.reject(fn {_key, value} -> is_nil(value) end)
      |> Map.new()

    %{
      search_query: String.slice(query, 0, 2_048),
      filters: onyx_filters,
      run_query_expansion: false,
      num_hits: filters.limit |> Kernel.*(3) |> max(30) |> min(100),
      hybrid_alpha: 0.5,
      include_content: true,
      stream: false
    }
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
    |> Map.new()
  end

  # Onyx combines values inside the `tags` filter with OR semantics. Send only the narrowest
  # server-side scope, then enforce every requested filter again from Loophony provenance.
  defp search_scope_tags(%{session_id: session_id}, _project) when is_binary(session_id),
    do: [%{tag_key: "session_id", tag_value: session_id}]

  defp search_scope_tags(%{issue_identifier: issue_identifier}, _project)
       when is_binary(issue_identifier),
       do: [%{tag_key: "issue_identifier", tag_value: issue_identifier}]

  defp search_scope_tags(%{source_types: source_types}, _project) when is_list(source_types) do
    Enum.map(source_types, &%{tag_key: "source_type", tag_value: &1})
  end

  defp search_scope_tags(_filters, project),
    do: [%{tag_key: "project", tag_value: project}]

  defp search_match(result) do
    link = map_value(result, "link", map_value(result, "url", ""))
    provenance = decode_provenance_url(link)

    %{
      "evidence_id" => map_value(provenance, "evidence_id"),
      "source_type" => map_value(provenance, "source_type"),
      "issue_id" => map_value(provenance, "issue_id"),
      "issue_identifier" => map_value(provenance, "issue_identifier"),
      "session_id" => map_value(provenance, "session_id"),
      "title" => map_value(result, "semantic_identifier", map_value(result, "title")),
      "content" =>
        result
        |> map_value("content", map_value(result, "blurb", ""))
        |> strip_index_header(),
      "metadata" =>
        Map.take(provenance, [
          "session_event",
          "session_status",
          "linear_state",
          "phase",
          "outcome",
          "thread_id",
          "turn_id"
        ]),
      "recorded_at" => map_value(provenance, "recorded_at", map_value(result, "updated_at")),
      "url" => link,
      "onyx_source_type" => map_value(result, "source_type"),
      "fused_score" => map_value(result, "score"),
      "semantic_distance" => nil,
      "semantic_rank" => nil,
      "keyword_rank" => nil,
      "rerank_score" => nil,
      "project" => map_value(provenance, "project")
    }
  end

  defp decode_provenance_url(url) when is_binary(url) do
    uri = URI.parse(url)

    if uri.scheme == "loophony" and uri.host == "memory" do
      query = if is_binary(uri.query), do: URI.decode_query(uri.query), else: %{}
      evidence_id = uri.path && String.trim_leading(uri.path, "/")
      Map.put_new(query, "evidence_id", evidence_id)
    else
      %{}
    end
  rescue
    _error -> %{}
  end

  defp decode_provenance_url(_url), do: %{}

  defp strip_index_header(content) do
    case String.split(content, @content_marker, parts: 2) do
      [_header, body] -> String.trim(body)
      _other -> content
    end
  end

  defp valid_project_match?(match, project), do: map_value(match, "project") == project

  defp valid_search_match?(match, project, filters) do
    valid_project_match?(match, project) and matches_filters?(match, filters)
  end

  defp matches_filters?(match, filters) do
    optional_equal?(map_value(match, "issue_identifier"), filters.issue_identifier) and
      optional_equal?(map_value(match, "session_id"), filters.session_id) and
      optional_member?(map_value(match, "source_type"), filters.source_types) and
      within_range?(map_value(match, "recorded_at"), filters.from, filters.to)
  end

  defp optional_equal?(_actual, nil), do: true
  defp optional_equal?(actual, expected), do: actual == expected

  defp optional_member?(_actual, nil), do: true
  defp optional_member?(actual, expected), do: actual in expected

  defp within_range?(nil, nil, nil), do: true
  defp within_range?(nil, _from, _to), do: false

  defp within_range?(recorded_at, from, to) do
    (is_nil(from) or recorded_at >= from) and (is_nil(to) or recorded_at <= to)
  end

  defp fetch_session(session_id, state) do
    filters = %{session_id: session_id, limit: 100}
    query = "Complete Loophony timeline for exact session #{session_id}: decisions, evidence, errors, and final responses"
    {search_result, next_state} = run_search(query, filters, state)

    reply =
      case search_result do
        {:ok, %{matches: []}} -> {:error, :session_not_found}
        {:ok, %{matches: matches}} -> {:ok, session_payload(session_id, matches)}
        {:error, reason} -> {:error, {:memory_read_failed, reason}}
      end

    {reply, next_state}
  end

  defp session_payload(session_id, matches) do
    sorted = Enum.sort_by(matches, &map_value(&1, "recorded_at", ""))
    events = Enum.filter(sorted, &(map_value(&1, "source_type") == "session_event"))
    summary = Enum.find(Enum.reverse(sorted), &(map_value(&1, "source_type") == "session_summary"))
    started = Enum.find(events, &(get_in(&1, ["metadata", "session_event"]) == "started"))
    ended = Enum.find(Enum.reverse(events), &(get_in(&1, ["metadata", "session_event"]) == "ended"))
    latest = List.last(sorted) || %{}
    latest_metadata = map_value(summary || ended || latest, "metadata", %{})

    evidence =
      Enum.reject(sorted, &(map_value(&1, "source_type") in ["session_event", "session_summary"]))

    %{
      session: %{
        "session_id" => session_id,
        "thread_id" => map_value(latest_metadata, "thread_id"),
        "turn_id" => map_value(latest_metadata, "turn_id"),
        "issue_id" => map_value(latest, "issue_id"),
        "issue_identifier" => map_value(latest, "issue_identifier"),
        "started_at" => started && map_value(started, "recorded_at"),
        "ended_at" => ended && map_value(ended, "recorded_at"),
        "status" => map_value(latest_metadata, "session_status", if(ended, do: "completed", else: "running")),
        "metadata" => %{}
      },
      summary: summary,
      evidence: evidence
    }
  end

  defp persist_codex_event(issue, %{event: :session_started} = message, state) do
    {_reply, next_state} =
      persist_document(session_event_document(issue, message, "started", "running"), state)

    remember_session_start(next_state, issue, message)
  end

  defp persist_codex_event(issue, %{event: event} = message, state)
       when event in [
              :turn_completed,
              :turn_ended_with_error,
              :turn_failed,
              :turn_cancelled,
              :turn_preempted
            ] do
    status = session_status(event)
    {_reply, state} = persist_document(session_event_document(issue, message, "ended", status), state)

    state =
      if status == "failed" do
        {_reply, next_state} =
          persist_document(error_document(issue, message, event_session_id(message)), state)

        next_state
      else
        state
      end

    state = persist_session_summary(issue, message, status, state)

    if event in [:turn_completed, :turn_ended_with_error, :turn_preempted],
      do: forget_session(state, event_session_id(message)),
      else: state
  end

  defp persist_codex_event(issue, %{event: :notification} = message, state) do
    case agent_message_document(issue, message) do
      nil ->
        state

      document ->
        {_reply, next_state} = persist_document(document, state)
        remember_agent_message(next_state, document)
    end
  end

  defp persist_codex_event(_issue, _message, state), do: state

  defp session_status(:turn_completed), do: "completed"
  defp session_status(:turn_preempted), do: "preempted"
  defp session_status(_event), do: "failed"

  defp session_event_document(issue, message, session_event, session_status) do
    session_id = event_session_id(message) || "#{issue.id}:unknown-session"

    %{
      source_type: "session_event",
      source_key: "#{session_id}:#{session_event}",
      issue_id: issue.id,
      issue_identifier: issue.identifier,
      session_id: session_id,
      title: "#{issue.identifier} session #{session_event}",
      content: "Session #{session_event} for #{issue.identifier} with status #{session_status}.",
      metadata:
        event_metadata(message)
        |> Map.merge(%{
          session_event: session_event,
          session_status: session_status,
          thread_id: map_value(message, :thread_id),
          turn_id: map_value(message, :turn_id)
        }),
      recorded_at: timestamp(message)
    }
  end

  defp issue_document(%Issue{} = issue) do
    blockers = Enum.map(List.wrap(issue.blocked_by), &blocker_summary/1)
    created_at = optional_timestamp(issue.created_at)
    updated_at = optional_timestamp(issue.updated_at)

    %{
      source_type: "linear_issue",
      source_key: issue.id,
      issue_id: issue.id,
      issue_identifier: issue.identifier,
      session_id: nil,
      title: "#{issue.identifier}: #{issue.title}",
      content: issue_content(issue, blockers, created_at, updated_at),
      metadata: %{
        schema_version: @document_schema_version,
        linear_state: issue.state,
        goal_context: goal_context(issue.project_description),
        mapped_success_criteria: mapped_success_criteria(issue),
        priority: issue.priority,
        labels: List.wrap(issue.labels),
        blocked_by: blockers,
        created_at: created_at,
        updated_at: updated_at,
        url: issue.url
      },
      recorded_at: issue_recorded_at(updated_at, created_at)
    }
  end

  defp persist_project_description(issues, state) when is_list(issues) do
    case project_source_issue(issues) do
      nil ->
        state

      issue ->
        case project_document(issue, state.settings.project) do
          nil ->
            state

          document ->
            {_reply, next_state} = persist_document(document, state)
            next_state
        end
    end
  end

  defp project_source_issue(issues) do
    issues
    |> Enum.filter(fn
      %Issue{project_description: description} when is_binary(description) ->
        String.trim(description) != ""

      _other ->
        false
    end)
    |> Enum.max_by(&project_recorded_at/1, fn -> nil end)
  end

  defp project_document(%Issue{project_description: description} = issue, fallback_project)
       when is_binary(description) do
    description = String.trim(description)

    if description == "" do
      nil
    else
      project_key =
        first_present([issue.project_id, issue.project_slug, fallback_project, "linear-project"])

      project_name = first_present([issue.project_name, issue.project_slug, fallback_project, "Linear project"])
      project_slug = first_present([issue.project_slug, fallback_project])
      recorded_at = project_recorded_at(issue)

      %{
        source_type: "linear_project",
        source_key: project_key,
        issue_id: "project:#{project_key}",
        issue_identifier: "PROJECT",
        session_id: nil,
        title: "Linear project: #{project_name}",
        content:
          [
            "Linear project: #{project_name}",
            "Project slug: #{display_value(project_slug, "unknown")}",
            "URL: #{display_value(issue.project_url, "unknown")}",
            "Updated at: #{recorded_at}",
            "",
            "Canonical project description:",
            description
          ]
          |> Enum.join("\n"),
        metadata: %{
          schema_version: @document_schema_version,
          project_id: issue.project_id,
          project_name: issue.project_name,
          project_slug: project_slug,
          project_url: issue.project_url,
          updated_at: optional_timestamp(issue.project_updated_at)
        },
        recorded_at: recorded_at
      }
    end
  end

  defp project_document(_issue, _fallback_project), do: nil

  defp project_recorded_at(%Issue{} = issue) do
    issue.project_updated_at
    |> optional_timestamp()
    |> then(&issue_recorded_at(&1, optional_timestamp(issue.updated_at)))
  end

  defp first_present(values) do
    Enum.find(values, fn value -> is_binary(value) and String.trim(value) != "" end)
  end

  defp issue_content(issue, blockers, created_at, updated_at) do
    [
      "Issue: #{issue.identifier} — #{issue.title}",
      "State: #{display_value(issue.state, "unknown")}",
      "Priority: #{display_value(issue.priority, "unset")}",
      "Labels: #{list_text(issue.labels)}",
      "Blocked by: #{list_text(blockers)}",
      "Created at: #{display_value(created_at, "unknown")}",
      "Updated at: #{display_value(updated_at, "unknown")}",
      "URL: #{display_value(issue.url, "unknown")}",
      "",
      "Linear description:",
      issue.description |> display_value("(empty)") |> to_string() |> String.trim()
    ]
    |> Enum.join("\n")
  end

  defp issue_recorded_at(updated_at, created_at) do
    Enum.find([updated_at, created_at], "1970-01-01T00:00:00Z", &is_binary/1)
  end

  defp display_value(nil, fallback), do: fallback
  defp display_value(value, _fallback), do: value

  defp blocker_summary(blocker) when is_map(blocker) do
    identifier = map_value(blocker, :identifier, map_value(blocker, :id, "unknown"))
    state = map_value(blocker, :state)
    if is_binary(state), do: "#{identifier} (#{state})", else: to_string(identifier)
  end

  defp blocker_summary(blocker), do: inspect(blocker)

  defp list_text(values) do
    case values |> List.wrap() |> Enum.reject(&is_nil/1) do
      [] -> "none"
      entries -> Enum.join(entries, ", ")
    end
  end

  defp checkpoint_document(checkpoint, context) do
    evidence = Map.get(checkpoint, :evidence) || Map.get(checkpoint, "evidence") || []
    issue_identifier = Map.get(checkpoint, :issue_identifier) || Map.get(checkpoint, "issue_identifier")
    checkpoint_key = Map.get(checkpoint, :checkpoint_key) || Map.get(checkpoint, "checkpoint_key")

    content =
      [
        "Summary: #{field(checkpoint, :summary)}",
        "Decision: #{field(checkpoint, :decision)}",
        "Evidence: #{Enum.join(evidence, "; ")}",
        "Next action: #{field(checkpoint, :next_action)}",
        "Outcome: #{field(checkpoint, :outcome)}",
        "Goal alignment: #{field(checkpoint, :goal_alignment)}"
      ]
      |> Enum.join("\n")

    %{
      source_type: "checkpoint",
      source_key: "#{field(checkpoint, :issue_id)}:#{checkpoint_key}",
      issue_id: field(checkpoint, :issue_id),
      issue_identifier: issue_identifier,
      session_id: Map.get(context, :session_id) || Map.get(context, "session_id"),
      title: "#{issue_identifier} #{field(checkpoint, :phase)} checkpoint",
      content: content,
      metadata: %{
        checkpoint_key: checkpoint_key,
        phase: field(checkpoint, :phase),
        goal_alignment: field(checkpoint, :goal_alignment),
        goal_context: goal_context(Map.get(context, :project_description) || Map.get(context, "project_description")),
        mapped_success_criteria:
          context
          |> Map.get(:issue_description, Map.get(context, "issue_description"))
          |> success_criteria_from_text(),
        turn_number: field(checkpoint, :turn_number),
        outcome: field(checkpoint, :outcome),
        thread_id: Map.get(context, :thread_id) || Map.get(context, "thread_id"),
        turn_id: Map.get(context, :turn_id) || Map.get(context, "turn_id")
      },
      recorded_at: field(checkpoint, :recorded_at)
    }
  end

  defp agent_message_document(issue, message) do
    case completed_agent_item(message) do
      {:ok, item, method} -> build_agent_message_document(issue, message, item, method)
      :error -> nil
    end
  end

  defp completed_agent_item(message) do
    payload = map_value(message, :payload, %{})
    method = map_value(payload, :method)
    params = map_value(payload, :params, %{})
    item = map_value(params, :item, %{})
    item_type = map_value(item, :type)

    if method == "item/completed" and agent_message_type?(item_type) do
      {:ok, item, method}
    else
      :error
    end
  end

  defp build_agent_message_document(issue, message, item, method) do
    text = extract_item_text(item)

    if text == "" do
      nil
    else
      session_id = event_session_id(message)
      item_id = map_value(item, :id, digest(text))

      %{
        source_type: "agent_final",
        source_key: "#{session_id || issue.id}:#{item_id}",
        issue_id: issue.id,
        issue_identifier: issue.identifier,
        session_id: session_id,
        title: "#{issue.identifier} agent response",
        content: text,
        metadata: %{item_id: item_id, method: method},
        recorded_at: timestamp(message)
      }
    end
  end

  defp agent_message_type?(type) when is_binary(type) do
    type
    |> String.replace(~r/[^a-z]/i, "")
    |> String.downcase()
    |> then(&(&1 in ["agentmessage", "assistantmessage"]))
  end

  defp agent_message_type?(_type), do: false

  defp extract_item_text(item) do
    direct = Map.get(item, "text") || Map.get(item, :text)
    content = Map.get(item, "content") || Map.get(item, :content)

    [direct | content_texts(content)]
    |> Enum.filter(&is_binary/1)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.join("\n")
  end

  defp content_texts(values) when is_list(values), do: Enum.flat_map(values, &content_texts/1)
  defp content_texts(%{"text" => text}) when is_binary(text), do: [text]
  defp content_texts(%{text: text}) when is_binary(text), do: [text]
  defp content_texts(_value), do: []

  defp error_document(issue, message, session_id) do
    reason = Map.get(message, :reason) || Map.get(message, :payload) || Map.get(message, :raw)

    %{
      source_type: "error",
      source_key: "#{session_id || issue.id}:#{digest(inspect(reason))}",
      issue_id: issue.id,
      issue_identifier: issue.identifier,
      session_id: session_id,
      title: "#{issue.identifier} session error",
      content: inspect(reason, pretty: true, printable_limit: @max_content_chars),
      metadata: %{event: Map.get(message, :event), session_status: "failed"},
      recorded_at: timestamp(message)
    }
  end

  defp remember_session_start(state, issue, message) do
    session_id = event_session_id(message)

    if is_binary(session_id) do
      session = %{
        issue: issue,
        started_at: timestamp(message),
        thread_id: map_value(message, :thread_id),
        turn_id: map_value(message, :turn_id),
        messages: []
      }

      %{state | sessions: Map.put(state.sessions, session_id, session)}
    else
      state
    end
  end

  defp remember_agent_message(state, %{session_id: session_id} = document)
       when is_binary(session_id) do
    sessions =
      Map.update(state.sessions, session_id, %{messages: [document]}, fn session ->
        messages = (Map.get(session, :messages, []) ++ [document]) |> Enum.take(-@max_session_messages)
        Map.put(session, :messages, messages)
      end)

    %{state | sessions: sessions}
  end

  defp remember_agent_message(state, _document), do: state

  defp forget_session(state, session_id) when is_binary(session_id),
    do: %{state | sessions: Map.delete(state.sessions, session_id)}

  defp forget_session(state, _session_id), do: state

  defp persist_session_summary(issue, message, status, state) do
    session_id = event_session_id(message) || "#{issue.id}:unknown-session"
    session = Map.get(state.sessions, session_id, %{})
    checkpoints = session_checkpoints(issue.id, session_id)
    document = session_summary_document(issue, message, session_id, status, session, checkpoints)
    {_reply, next_state} = persist_document(document, state)
    next_state
  end

  defp session_checkpoints(issue_id, session_id) do
    case LoopStore.recent(issue_id, 100) do
      {:ok, checkpoints} ->
        checkpoints
        |> Enum.filter(&(field(&1, :session_id) == session_id))
        |> Enum.sort_by(&field(&1, :recorded_at))

      {:error, _reason} ->
        []
    end
  end

  defp session_summary_document(issue, message, session_id, status, session, checkpoints) do
    messages = Map.get(session, :messages, [])
    started_at = Map.get(session, :started_at)
    ended_at = timestamp(message)
    latest_checkpoint = List.last(checkpoints)
    goal_context = goal_context(issue.project_description)
    mapped_success_criteria = mapped_success_criteria(issue)

    content =
      [
        "Session summary for #{issue.identifier}",
        "Status: #{status}",
        "Issue title: #{issue.title}",
        goal_lens_section(goal_context, mapped_success_criteria, checkpoints),
        "Started at: #{started_at || "unknown"}",
        "Ended at: #{ended_at}",
        summary_section("Checkpoint timeline", checkpoints, &checkpoint_summary/1),
        summary_section("Decisions", checkpoints, &field(&1, :decision)),
        summary_section("Evidence", checkpoints, &field(&1, :evidence)),
        summary_section("Agent responses", messages, &Map.get(&1, :content)),
        "Latest next action: #{field(latest_checkpoint || %{}, :next_action) || "not recorded"}"
      ]
      |> Enum.reject(&(&1 == ""))
      |> Enum.join("\n\n")

    %{
      source_type: "session_summary",
      source_key: session_id,
      issue_id: issue.id,
      issue_identifier: issue.identifier,
      session_id: session_id,
      title: "#{issue.identifier} session summary",
      content: content,
      metadata: %{
        schema_version: @document_schema_version,
        session_status: status,
        goal_context: goal_context,
        goal_alignment: field(latest_checkpoint || %{}, :goal_alignment),
        mapped_success_criteria: mapped_success_criteria,
        started_at: started_at,
        ended_at: ended_at,
        checkpoint_count: length(checkpoints),
        agent_message_count: length(messages),
        outcome: field(latest_checkpoint || %{}, :outcome),
        thread_id: Map.get(session, :thread_id) || map_value(message, :thread_id),
        turn_id: Map.get(session, :turn_id) || map_value(message, :turn_id)
      },
      recorded_at: ended_at
    }
  end

  defp checkpoint_summary(checkpoint) do
    phase = field(checkpoint, :phase) || "unknown"
    recorded_at = field(checkpoint, :recorded_at) || "unknown"
    "#{recorded_at} [#{phase}] #{field(checkpoint, :summary)}"
  end

  defp goal_lens_section("", [], _checkpoints), do: ""

  defp goal_lens_section(goal_context, mapped_success_criteria, checkpoints) do
    alignments =
      checkpoints
      |> Enum.map(&field(&1, :goal_alignment))
      |> Enum.filter(&is_binary/1)
      |> Enum.uniq()

    [
      "Goal lens:",
      if(goal_context != "", do: "- Project objective: #{goal_context}"),
      if(mapped_success_criteria != [],
        do: "- Mapped success criteria: #{Enum.join(mapped_success_criteria, ", ")}"
      ),
      if(alignments != [], do: "- Recorded alignment: #{Enum.join(alignments, ", ")}")
    ]
    |> Enum.reject(&is_nil/1)
    |> Enum.join("\n")
  end

  defp mapped_success_criteria(%Issue{} = issue) do
    [issue.title, issue.description]
    |> Enum.filter(&is_binary/1)
    |> Enum.join("\n")
    |> success_criteria_from_text()
  end

  defp success_criteria_from_text(text) when is_binary(text) do
    ~r/\bSC-\d{2}\b/i
    |> Regex.scan(text)
    |> List.flatten()
    |> Enum.map(&String.upcase/1)
    |> Enum.uniq()
  end

  defp success_criteria_from_text(_text), do: []

  defp goal_context(description) when is_binary(description) do
    description = String.trim(description)

    if description == "" do
      ""
    else
      active_stage = markdown_goal_field(description, "Active stage")
      outcome = markdown_goal_field(description, "Outcome")
      why = markdown_goal_field(description, "Why")

      [
        active_stage && "Active stage: #{active_stage}",
        outcome && "Outcome: #{outcome}",
        why && "Why: #{why}"
      ]
      |> Enum.filter(&is_binary/1)
      |> case do
        [] -> fallback_goal_context(description)
        fields -> Enum.join(fields, " | ")
      end
      |> String.slice(0, @max_goal_context_chars)
    end
  end

  defp goal_context(_description), do: ""

  defp markdown_goal_field(description, label) do
    pattern = Regex.compile!("^\\*\\*#{Regex.escape(label)}:\\*\\*\\s*(.+)$", "mi")

    case Regex.run(pattern, description, capture: :all_but_first) do
      [value] -> value |> String.trim() |> String.slice(0, 220)
      _other -> nil
    end
  end

  defp fallback_goal_context(description) do
    description
    |> String.split(~r/\n\s*\n/, trim: true)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == "" or String.starts_with?(&1, ["<!--", "#"])))
    |> List.first()
    |> case do
      nil -> ""
      paragraph -> paragraph
    end
  end

  defp summary_section(title, entries, mapper) do
    items =
      entries
      |> Enum.flat_map(fn entry -> entry |> mapper.() |> summary_values() end)
      |> Enum.map(&String.trim/1)
      |> Enum.reject(&(&1 == ""))
      |> Enum.uniq()
      |> Enum.take(@max_summary_items)

    case items do
      [] -> ""
      values -> Enum.join([title <> ":" | Enum.map(values, &("- " <> &1))], "\n")
    end
  end

  defp summary_values(nil), do: []
  defp summary_values(values) when is_list(values), do: Enum.filter(values, &is_binary/1)
  defp summary_values(value) when is_binary(value), do: [value]
  defp summary_values(value), do: [inspect(value)]

  defp normalize_document(document) do
    recorded_at = Map.get(document, :recorded_at) || Map.get(document, "recorded_at")
    source_type = required_field(document, :source_type)
    source_key = required_field(document, :source_key)

    %{
      evidence_id:
        Map.get(document, :evidence_id) || Map.get(document, "evidence_id") ||
          "mem_" <> digest("#{source_type}:#{source_key}"),
      source_type: source_type,
      source_key: source_key,
      issue_id: required_field(document, :issue_id),
      issue_identifier: required_field(document, :issue_identifier),
      session_id: optional_string(document, :session_id),
      title: document |> required_field(:title) |> truncate(),
      content: document |> required_field(:content) |> truncate(),
      metadata: document |> map_value(:metadata, %{}) |> stringify_keys(),
      recorded_at: normalize_timestamp(recorded_at)
    }
  end

  defp normalize_search_filters(filters, default_limit) do
    source_types = filter_value(filters, :source_types)

    %{
      issue_identifier: optional_filter(filters, :issue_identifier),
      session_id: optional_filter(filters, :session_id),
      source_types: normalize_source_types(source_types),
      from: optional_filter(filters, :from),
      to: optional_filter(filters, :to),
      limit: normalize_limit(filter_value(filters, :limit), default_limit)
    }
  end

  defp normalize_source_types(nil), do: nil

  defp normalize_source_types(types) when is_list(types) do
    normalized = Enum.filter(types, &(&1 in @source_types))
    if normalized == [], do: nil, else: normalized
  end

  defp normalize_source_types(_types), do: nil

  defp normalize_limit(limit, _default) when is_integer(limit), do: limit |> max(1) |> min(100)
  defp normalize_limit(_limit, default), do: default

  defp result_entries(%{"search_docs" => entries}) when is_list(entries), do: entries
  defp result_entries(_payload), do: []

  defp reply_with_ingestion_state({:ok, _payload} = reply, state) do
    now = utc_now_iso8601()

    {reply,
     %{
       state
       | ingestion_healthy: true,
         last_ingestion_success_at: now,
         last_error: clear_ingestion_error(state.last_error)
     }}
  end

  defp reply_with_ingestion_state({:error, reason} = reply, state) do
    next_state = %{state | ingestion_healthy: false, last_error: reason}
    audit_health_transition(state, next_state, "ingestion_failed")
    {reply, next_state}
  end

  defp reply_with_search_state({:ok, _payload} = reply, state) do
    next_state = %{
      state
      | available: true,
        connection_healthy: true,
        search_healthy: true,
        consecutive_search_failures: 0,
        circuit_open_until_ms: nil,
        last_search_success_at: utc_now_iso8601(),
        last_error: nil
    }

    audit_health_transition(state, next_state, "search_recovered")
    {reply, next_state}
  end

  defp reply_with_search_state({:error, reason} = reply, state) do
    failures = state.consecutive_search_failures + 1

    circuit_open_until_ms =
      if failures >= state.settings.failure_threshold do
        System.monotonic_time(:millisecond) + state.settings.circuit_breaker_ms
      else
        state.circuit_open_until_ms
      end

    next_state = %{
      state
      | available: false,
        search_healthy: false,
        consecutive_search_failures: failures,
        circuit_open_until_ms: circuit_open_until_ms,
        last_error: reason
    }

    audit_health_transition(state, next_state, "search_failed")
    {reply, next_state}
  end

  defp functional_health_probe(state) do
    normalized = normalize_search_filters(%{}, min(state.settings.search_limit, 3))
    request = search_request(state.settings.canary_query, normalized, state.settings.project)

    result =
      with {:ok, _health} <- state.client.health.(state.settings),
           {:ok, search_settings} <- state.client.current_search_settings.(state.settings),
           {:ok, payload} <- state.client.search.(request, state.settings),
           :ok <- validate_probe_payload(payload) do
        {:ok, search_settings}
      end

    case result do
      {:ok, search_settings} ->
        {_reply, next_state} = reply_with_search_state({:ok, %{}}, %{state | search_settings: search_settings})
        {:ok, next_state}

      {:error, reason} ->
        wrapped = {:memory_health_probe_failed, reason}

        updated_state = %{
          state
          | connection_healthy: probe_connection_healthy?(reason)
        }

        {_reply, next_state} = reply_with_search_state({:error, wrapped}, updated_state)
        {{:error, wrapped}, next_state}
    end
  end

  defp validate_probe_payload(%{"error" => error}) when is_binary(error) and error != "",
    do: {:error, {:onyx_search, error}}

  defp validate_probe_payload(_payload), do: :ok

  defp probe_connection_healthy?({:onyx_status, _status, _body}), do: true
  defp probe_connection_healthy?({:onyx_search, _error}), do: true
  defp probe_connection_healthy?(_reason), do: false

  defp schedule_health_probe(%State{enabled: false} = state), do: state

  defp schedule_health_probe(state) do
    if is_reference(state.probe_timer_ref), do: Process.cancel_timer(state.probe_timer_ref)

    delay =
      case circuit_open_for_ms(state) do
        remaining when is_integer(remaining) and remaining > 0 ->
          min(remaining, state.settings.health_probe_interval_ms)

        _ ->
          state.settings.health_probe_interval_ms
      end

    %{state | probe_timer_ref: Process.send_after(self(), :health_probe, delay)}
  end

  defp circuit_open?(%State{circuit_open_until_ms: until_ms}) when is_integer(until_ms) do
    until_ms > System.monotonic_time(:millisecond)
  end

  defp circuit_open?(_state), do: false

  defp circuit_open_for_ms(%State{circuit_open_until_ms: until_ms}) when is_integer(until_ms) do
    max(0, until_ms - System.monotonic_time(:millisecond))
  end

  defp circuit_open_for_ms(_state), do: 0

  defp audit_health_transition(previous, next, event) do
    changed? =
      previous.search_healthy != next.search_healthy or
        previous.ingestion_healthy != next.ingestion_healthy or
        circuit_open?(previous) != circuit_open?(next)

    if changed? do
      _ =
        AuditLog.record_async("memory.health_changed", %{
          outcome: if(next.available, do: "ok", else: "degraded"),
          resource_type: "memory",
          resource_id: next.settings.project,
          metadata: %{
            event: event,
            connection_healthy: next.connection_healthy,
            search_healthy: next.search_healthy,
            ingestion_healthy: next.ingestion_healthy,
            consecutive_search_failures: next.consecutive_search_failures,
            circuit_open: circuit_open?(next),
            error: next.last_error && inspect(next.last_error)
          }
        })
    end

    :ok
  end

  defp clear_ingestion_error({:memory_ingestion_failed, _reason}), do: nil
  defp clear_ingestion_error(error), do: error

  defp utc_now_iso8601 do
    DateTime.utc_now() |> DateTime.truncate(:microsecond) |> DateTime.to_iso8601()
  end

  defp default_client do
    %{
      health: &OnyxClient.health/1,
      current_search_settings: &OnyxClient.current_search_settings/1,
      ingest: &OnyxClient.ingest/2,
      search: &OnyxClient.search/2
    }
  end

  defp event_session_id(message) do
    payload = Map.get(message, :payload) || %{}
    params = Map.get(payload, "params") || Map.get(payload, :params) || %{}
    thread_id = Map.get(params, "threadId") || Map.get(params, :threadId)
    turn_id = Map.get(params, "turnId") || Map.get(params, :turnId)

    Map.get(message, :session_id) ||
      if(is_binary(thread_id) and is_binary(turn_id), do: "#{thread_id}-#{turn_id}")
  end

  defp event_metadata(message) do
    message
    |> Map.take([:codex_app_server_pid, :worker_host, :preempt_request_id])
    |> Map.new(fn {key, value} -> {to_string(key), value} end)
  end

  defp timestamp(message), do: normalize_timestamp(Map.get(message, :timestamp))

  defp normalize_timestamp(%DateTime{} = value), do: DateTime.to_iso8601(value)
  defp normalize_timestamp(value) when is_binary(value), do: value
  defp normalize_timestamp(_value), do: DateTime.utc_now() |> DateTime.to_iso8601()

  defp required_field(document, field) do
    Map.get(document, field) || Map.get(document, to_string(field)) || "unknown"
  end

  defp optional_string(document, field) do
    case Map.get(document, field) || Map.get(document, to_string(field)) do
      value when is_binary(value) and value != "" -> value
      _other -> nil
    end
  end

  defp optional_filter(filters, field) do
    case filter_value(filters, field) do
      value when is_binary(value) -> if String.trim(value) == "", do: nil, else: value
      _other -> nil
    end
  end

  defp filter_value(filters, field), do: Map.get(filters, field) || Map.get(filters, to_string(field))

  defp map_value(map, key, default \\ nil)

  defp map_value(map, key, default) when is_map(map) do
    case Map.fetch(map, key) do
      {:ok, value} -> value
      :error -> Map.get(map, to_string(key), default)
    end
  end

  defp map_value(_map, _key, default), do: default

  defp field(map, key), do: Map.get(map, key) || Map.get(map, to_string(key))

  defp stringify_keys(value) when is_map(value) do
    Map.new(value, fn {key, nested} -> {to_string(key), stringify_keys(nested)} end)
  end

  defp stringify_keys(value) when is_list(value), do: Enum.map(value, &stringify_keys/1)
  defp stringify_keys(value), do: value

  defp content_chunks(content) do
    chunks =
      content
      |> String.split(~r/\n\s*\n/, trim: true)
      |> Enum.flat_map(&hard_chunks/1)
      |> pack_chunks()

    if chunks == [], do: [content], else: chunks
  end

  defp hard_chunks(text) do
    Stream.unfold(String.trim(text), fn
      "" ->
        nil

      remaining ->
        chunk = String.slice(remaining, 0, @max_section_chars)
        rest = String.slice(remaining, @max_section_chars, String.length(remaining))
        {chunk, String.trim_leading(rest)}
    end)
    |> Enum.to_list()
  end

  defp pack_chunks(paragraphs) do
    {completed, current} =
      Enum.reduce(paragraphs, {[], ""}, fn paragraph, {completed, current} ->
        candidate = if current == "", do: paragraph, else: current <> "\n\n" <> paragraph

        cond do
          String.length(candidate) <= @max_section_chars ->
            {completed, candidate}

          current == "" ->
            {[paragraph | completed], ""}

          true ->
            {[current | completed], paragraph}
        end
      end)

    completed = if current == "", do: completed, else: [current | completed]
    Enum.reverse(completed)
  end

  defp document_version(%{source_type: "linear_project"} = document) do
    {document.title, document.content, document.metadata}
    |> :erlang.term_to_binary()
    |> digest()
  end

  defp document_version(document) do
    {document.title, document.content, document.metadata, document.recorded_at}
    |> :erlang.term_to_binary()
    |> digest()
  end

  defp onyx_document_id(document, project) do
    "loophony_" <> digest("#{project}:#{document.source_type}:#{document.source_key}")
  end

  defp optional_timestamp(%DateTime{} = value), do: DateTime.to_iso8601(value)
  defp optional_timestamp(value) when is_binary(value) and value != "", do: value
  defp optional_timestamp(_value), do: nil

  defp truncate(value) when is_binary(value), do: String.slice(value, 0, @max_content_chars)
  defp truncate(value), do: value |> inspect() |> truncate()

  defp digest(value), do: :crypto.hash(:sha256, value) |> Base.encode16(case: :lower) |> String.slice(0, 20)

  defp onyx_label(url) when is_binary(url) do
    uri = URI.parse(url)
    "#{uri.host}:#{uri.port || default_port(uri.scheme)}#{uri.path}"
  end

  defp onyx_label(_url), do: nil

  defp default_port("https"), do: 443
  defp default_port(_scheme), do: 80

  defp call(server, message, timeout) do
    GenServer.call(server, message, timeout)
  catch
    :exit, reason -> {:error, {:memory_store_unavailable, reason}}
  end
end
