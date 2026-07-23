defmodule SymphonyElixir.AuditLog do
  @moduledoc """
  Append-only, tamper-evident operational audit log.

  Events are stored in SQLite with a SHA-256 hash chain. The chain makes accidental or offline
  modification detectable; it is not a substitute for exporting hashes to an independently
  controlled system. Secret-looking metadata keys are redacted before persistence.
  """

  use GenServer

  alias Exqlite.Sqlite3
  alias SymphonyElixir.Config

  @genesis_hash String.duplicate("0", 64)
  @max_text_bytes 8_000
  @secret_key ~r/(authorization|cookie|credential|password|secret|api[_-]?key|access[_-]?token|refresh[_-]?token|auth[_-]?token|(^|[_-])token$)/i

  @schema """
  PRAGMA journal_mode = WAL;
  PRAGMA synchronous = FULL;
  PRAGMA busy_timeout = 5000;

  CREATE TABLE IF NOT EXISTS audit_events (
    sequence INTEGER PRIMARY KEY AUTOINCREMENT,
    event_id TEXT NOT NULL UNIQUE,
    actor TEXT NOT NULL,
    action TEXT NOT NULL,
    outcome TEXT NOT NULL,
    resource_type TEXT,
    resource_id TEXT,
    metadata_json TEXT NOT NULL,
    hash_version INTEGER NOT NULL DEFAULT 1,
    previous_hash TEXT NOT NULL,
    event_hash TEXT NOT NULL UNIQUE,
    recorded_at TEXT NOT NULL
  );

  CREATE INDEX IF NOT EXISTS idx_audit_events_recorded
    ON audit_events(recorded_at DESC, sequence DESC);
  CREATE INDEX IF NOT EXISTS idx_audit_events_resource
    ON audit_events(resource_type, resource_id, sequence DESC);
  """

  @insert """
  INSERT INTO audit_events (
    event_id, actor, action, outcome, resource_type, resource_id, metadata_json,
    hash_version, previous_hash, event_hash, recorded_at
  ) VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11)
  """

  @select_columns """
  sequence, event_id, actor, action, outcome, resource_type, resource_id, metadata_json,
  hash_version, previous_hash, event_hash, recorded_at
  """

  defmodule State do
    @moduledoc false
    defstruct [:connection, :path, :path_override, enabled_override: nil]
  end

  @type event :: %{
          sequence: pos_integer(),
          event_id: String.t(),
          actor: String.t(),
          action: String.t(),
          outcome: String.t(),
          resource_type: String.t() | nil,
          resource_id: String.t() | nil,
          metadata: map(),
          hash_version: pos_integer(),
          previous_hash: String.t(),
          event_hash: String.t(),
          recorded_at: String.t()
        }

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @spec record(String.t(), map()) :: {:ok, event()} | {:error, term()}
  def record(action, attributes \\ %{}), do: record(action, attributes, __MODULE__)

  @spec record(String.t(), map(), GenServer.server()) :: {:ok, event()} | {:error, term()}
  def record(action, attributes, server) when is_binary(action) and is_map(attributes) do
    call(server, {:record, action, attributes})
  end

  @spec record_async(String.t(), map(), GenServer.server()) :: :ok
  def record_async(action, attributes, server \\ __MODULE__)
      when is_binary(action) and is_map(attributes) do
    GenServer.cast(server, {:record, action, attributes})
  end

  @spec recent(non_neg_integer(), map()) :: {:ok, [event()]} | {:error, term()}
  def recent(limit \\ 100, filters \\ %{}), do: recent(limit, filters, __MODULE__)

  @spec recent(non_neg_integer(), map(), GenServer.server()) :: {:ok, [event()]} | {:error, term()}
  def recent(limit, filters, server) when is_integer(limit) and is_map(filters) do
    call(server, {:recent, limit, filters})
  end

  @spec summary() :: map()
  def summary, do: summary(__MODULE__)

  @spec summary(GenServer.server()) :: map()
  def summary(server), do: summary(server, 15_000)

  @spec summary(GenServer.server(), timeout()) :: map()
  def summary(server, timeout) do
    case call(server, :summary, timeout) do
      %{} = payload -> payload
      {:error, reason} -> %{enabled: false, available: false, error: inspect(reason)}
    end
  end

  @spec verify() :: {:ok, map()} | {:error, term()}
  def verify, do: verify(__MODULE__)

  @spec verify(GenServer.server()) :: {:ok, map()} | {:error, term()}
  def verify(server), do: call(server, :verify, 60_000)

  @impl true
  def init(opts) do
    {:ok,
     %State{
       path_override: Keyword.get(opts, :path),
       enabled_override: Keyword.get(opts, :enabled)
     }}
  end

  @impl true
  def handle_call({:record, action, attributes}, _from, state) do
    with {:ok, state} <- ensure_connection(state),
         {:ok, event} <- safe_append_event(state.connection, action, attributes) do
      {:reply, {:ok, event}, state}
    else
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:recent, limit, filters}, _from, state) do
    with {:ok, state} <- ensure_connection(state),
         {:ok, events} <- select_recent(state.connection, limit, filters) do
      {:reply, {:ok, events}, state}
    else
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  def handle_call(:summary, _from, state) do
    case ensure_connection(state) do
      {:ok, state} ->
        payload = audit_summary(state.connection, state.path)
        {:reply, payload, state}

      {:error, :audit_disabled} ->
        {:reply, %{enabled: false, available: false, total_events: 0}, state}

      {:error, reason} ->
        {:reply, %{enabled: true, available: false, error: inspect(reason)}, state}
    end
  end

  def handle_call(:verify, _from, state) do
    with {:ok, state} <- ensure_connection(state),
         {:ok, result} <- verify_chain(state.connection) do
      {:reply, {:ok, result}, state}
    else
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  @impl true
  def handle_cast({:record, action, attributes}, state) do
    case ensure_connection(state) do
      {:ok, state} ->
        _ = safe_append_event(state.connection, action, attributes)
        {:noreply, state}

      {:error, _reason} ->
        {:noreply, state}
    end
  end

  @impl true
  def terminate(_reason, state) do
    close_connection(state.connection)
    :ok
  end

  defp ensure_connection(%State{} = state) do
    case configured_audit() do
      {:ok, settings} ->
        enabled = if is_boolean(state.enabled_override), do: state.enabled_override, else: settings.enabled
        path = state.path_override || settings.database_path

        cond do
          !enabled ->
            {:error, :audit_disabled}

          state.connection && state.path == path ->
            {:ok, state}

          true ->
            close_connection(state.connection)
            open_connection(path, state)
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp configured_audit do
    {:ok, Config.settings!().audit}
  rescue
    error -> {:error, {:audit_config_unavailable, Exception.message(error)}}
  catch
    kind, reason -> {:error, {:audit_config_unavailable, kind, reason}}
  end

  defp open_connection(path, state) when is_binary(path) do
    with :ok <- File.mkdir_p(Path.dirname(path)),
         {:ok, connection} <- Sqlite3.open(path),
         :ok <- Sqlite3.execute(connection, @schema),
         :ok <- ensure_hash_version_column(connection) do
      {:ok, %{state | connection: connection, path: path}}
    end
  end

  defp append_event(connection, action, attributes) do
    with :ok <- Sqlite3.execute(connection, "BEGIN IMMEDIATE"),
         {:ok, previous_hash} <- latest_hash(connection),
         event = build_event(action, attributes, previous_hash),
         :ok <- insert_event(connection, event),
         :ok <- Sqlite3.execute(connection, "COMMIT"),
         {:ok, stored} <- select_event(connection, event.event_id) do
      {:ok, stored}
    else
      {:error, reason} ->
        _ = Sqlite3.execute(connection, "ROLLBACK")
        {:error, reason}
    end
  end

  defp safe_append_event(connection, action, attributes) do
    append_event(connection, action, attributes)
  rescue
    error ->
      _ = Sqlite3.execute(connection, "ROLLBACK")
      {:error, {:audit_append_exception, Exception.message(error)}}
  catch
    kind, reason ->
      _ = Sqlite3.execute(connection, "ROLLBACK")
      {:error, {:audit_append_exception, kind, reason}}
  end

  defp build_event(action, attributes, previous_hash) do
    recorded_at = DateTime.utc_now() |> DateTime.truncate(:microsecond) |> DateTime.to_iso8601()
    event_id = random_id()
    actor = normalized_text(value(attributes, :actor), "system")
    outcome = normalized_text(value(attributes, :outcome), "ok")
    resource_type = optional_text(value(attributes, :resource_type))
    resource_id = optional_text(value(attributes, :resource_id))
    metadata = attributes |> value(:metadata) |> normalize_metadata()

    canonical = %{
      event_id: event_id,
      actor: actor,
      action: normalized_text(action, "unknown"),
      outcome: outcome,
      resource_type: resource_type,
      resource_id: resource_id,
      metadata: metadata,
      hash_version: 1,
      previous_hash: previous_hash,
      recorded_at: recorded_at
    }

    Map.put(canonical, :event_hash, digest(canonical))
  end

  defp insert_event(connection, event) do
    execute_statement(connection, @insert, [
      event.event_id,
      event.actor,
      event.action,
      event.outcome,
      event.resource_type,
      event.resource_id,
      Jason.encode!(event.metadata),
      event.hash_version,
      event.previous_hash,
      event.event_hash,
      event.recorded_at
    ])
  end

  defp latest_hash(connection) do
    case query_rows(connection, "SELECT event_hash FROM audit_events ORDER BY sequence DESC LIMIT 1", []) do
      {:ok, [[hash]]} when is_binary(hash) -> {:ok, hash}
      {:ok, []} -> {:ok, @genesis_hash}
      {:error, reason} -> {:error, reason}
    end
  end

  defp select_event(connection, event_id) do
    case query_rows(
           connection,
           "SELECT #{@select_columns} FROM audit_events WHERE event_id = ?1",
           [event_id]
         ) do
      {:ok, [row]} -> {:ok, decode_event(row)}
      {:ok, []} -> {:error, :audit_event_not_found}
      {:error, reason} -> {:error, reason}
    end
  end

  defp select_recent(connection, limit, filters) do
    limit = normalize_limit(limit)
    {where, parameters} = audit_filters(filters)
    sql = "SELECT #{@select_columns} FROM audit_events#{where} ORDER BY sequence DESC LIMIT ?#{length(parameters) + 1}"

    case query_rows(connection, sql, parameters ++ [limit]) do
      {:ok, rows} -> {:ok, Enum.map(rows, &decode_event/1)}
      {:error, reason} -> {:error, reason}
    end
  end

  defp audit_filters(filters) do
    [
      {"resource_type", value(filters, :resource_type)},
      {"resource_id", value(filters, :resource_id)},
      {"action", value(filters, :action)},
      {"outcome", value(filters, :outcome)}
    ]
    |> Enum.reduce({[], []}, fn
      {column, raw_value}, {clauses, parameters} when is_binary(raw_value) ->
        case String.trim(raw_value) do
          "" -> {clauses, parameters}
          normalized -> {clauses ++ ["#{column} = ?#{length(parameters) + 1}"], parameters ++ [normalized]}
        end

      _entry, acc ->
        acc
    end)
    |> then(fn
      {[], parameters} -> {"", parameters}
      {clauses, parameters} -> {" WHERE " <> Enum.join(clauses, " AND "), parameters}
    end)
  end

  defp audit_summary(connection, path) do
    case query_rows(
           connection,
           "SELECT COUNT(*), MIN(recorded_at), MAX(recorded_at), MAX(sequence) FROM audit_events",
           []
         ) do
      {:ok, [[count, first_at, last_at, last_sequence]]} ->
        %{
          enabled: true,
          available: true,
          path: path,
          total_events: count,
          first_event_at: first_at,
          last_event_at: last_at,
          last_sequence: last_sequence || 0,
          hash_chain: "sha256/canonical-term-v1"
        }

      {:error, reason} ->
        %{enabled: true, available: false, path: path, error: inspect(reason)}
    end
  end

  defp verify_chain(connection) do
    case query_rows(connection, "SELECT #{@select_columns} FROM audit_events ORDER BY sequence ASC", []) do
      {:ok, rows} -> verify_rows(rows, @genesis_hash, 0)
      {:error, reason} -> {:error, reason}
    end
  end

  defp verify_rows([], previous_hash, count) do
    {:ok, %{valid: true, verified_events: count, head_hash: previous_hash}}
  end

  defp verify_rows([row | rest], expected_previous_hash, count) do
    event = decode_event(row)
    canonical = Map.drop(event, [:sequence, :event_hash])
    computed_hash = digest(canonical)

    cond do
      event.previous_hash != expected_previous_hash ->
        {:ok,
         %{
           valid: false,
           verified_events: count,
           failed_sequence: event.sequence,
           reason: "previous_hash_mismatch"
         }}

      event.event_hash != computed_hash ->
        {:ok,
         %{
           valid: false,
           verified_events: count,
           failed_sequence: event.sequence,
           reason: "event_hash_mismatch"
         }}

      true ->
        verify_rows(rest, event.event_hash, count + 1)
    end
  end

  defp decode_event([
         sequence,
         event_id,
         actor,
         action,
         outcome,
         resource_type,
         resource_id,
         metadata_json,
         hash_version,
         previous_hash,
         event_hash,
         recorded_at
       ]) do
    %{
      sequence: sequence,
      event_id: event_id,
      actor: actor,
      action: action,
      outcome: outcome,
      resource_type: resource_type,
      resource_id: resource_id,
      metadata: decode_metadata(metadata_json),
      hash_version: hash_version,
      previous_hash: previous_hash,
      event_hash: event_hash,
      recorded_at: recorded_at
    }
  end

  defp normalize_metadata(%_{} = metadata), do: %{"value" => sanitize(metadata)}

  defp normalize_metadata(metadata) when is_map(metadata) do
    metadata
    |> Enum.map(fn {key, value} ->
      normalized_key = normalize_key(key)
      normalized_value = if Regex.match?(@secret_key, normalized_key), do: "[REDACTED]", else: sanitize(value)
      {normalized_key, normalized_value}
    end)
    |> Map.new()
  end

  defp normalize_metadata(_metadata), do: %{}

  defp sanitize(%DateTime{} = value), do: DateTime.to_iso8601(value)
  defp sanitize(%NaiveDateTime{} = value), do: NaiveDateTime.to_iso8601(value)
  defp sanitize(%Date{} = value), do: Date.to_iso8601(value)
  defp sanitize(%Time{} = value), do: Time.to_iso8601(value)

  defp sanitize(%_{} = value) do
    value |> inspect(limit: 20, printable_limit: @max_text_bytes) |> truncate()
  end

  defp sanitize(value) when is_map(value), do: normalize_metadata(value)
  defp sanitize(value) when is_list(value), do: Enum.take(value, 100) |> Enum.map(&sanitize/1)
  defp sanitize(value) when is_binary(value), do: truncate(value)
  defp sanitize(value) when is_number(value) or is_boolean(value) or is_nil(value), do: value
  defp sanitize(value), do: value |> inspect(limit: 20, printable_limit: @max_text_bytes) |> truncate()

  defp decode_metadata(metadata_json) do
    case Jason.decode(metadata_json) do
      {:ok, metadata} when is_map(metadata) -> metadata
      _ -> %{}
    end
  end

  defp digest(event) do
    event
    |> canonical_term()
    |> :erlang.term_to_binary([:deterministic])
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end

  defp canonical_term(value) when is_map(value) do
    entries =
      value
      |> Enum.map(fn {key, nested} -> {normalize_key(key), canonical_term(nested)} end)
      |> Enum.sort_by(fn {key, _nested} -> key end)

    {:map, entries}
  end

  defp canonical_term(value) when is_list(value), do: {:list, Enum.map(value, &canonical_term/1)}
  defp canonical_term(value), do: value

  defp ensure_hash_version_column(connection) do
    case query_rows(connection, "PRAGMA table_info(audit_events)", []) do
      {:ok, rows} -> maybe_add_hash_version_column(connection, rows)
      {:error, reason} -> {:error, reason}
    end
  end

  defp maybe_add_hash_version_column(connection, rows) do
    if Enum.any?(rows, fn [_cid, name | _rest] -> name == "hash_version" end) do
      :ok
    else
      Sqlite3.execute(
        connection,
        "ALTER TABLE audit_events ADD COLUMN hash_version INTEGER NOT NULL DEFAULT 1"
      )
    end
  end

  defp random_id do
    16 |> :crypto.strong_rand_bytes() |> Base.url_encode64(padding: false)
  end

  defp normalized_text(value, default) when is_binary(value) do
    case String.trim(value) do
      "" -> default
      text -> truncate(text)
    end
  end

  defp normalized_text(_value, default), do: default

  defp optional_text(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      text -> truncate(text)
    end
  end

  defp optional_text(_value), do: nil

  defp truncate(value) when byte_size(value) <= @max_text_bytes, do: value

  defp truncate(value) do
    value
    |> binary_part(0, @max_text_bytes)
    |> trim_invalid_utf8()
  end

  defp trim_invalid_utf8(value) do
    if String.valid?(value), do: value, else: trim_invalid_utf8(binary_part(value, 0, byte_size(value) - 1))
  end

  defp normalize_key(key) when is_binary(key), do: truncate(key)
  defp normalize_key(key) when is_atom(key) or is_number(key), do: key |> to_string() |> truncate()
  defp normalize_key(key), do: key |> inspect(limit: 10, printable_limit: 200) |> truncate()

  defp value(map, key) when is_map(map), do: Map.get(map, key) || Map.get(map, Atom.to_string(key))
  defp value(_map, _key), do: nil

  defp normalize_limit(limit) when is_integer(limit) do
    configured = configured_query_limit()
    limit |> max(1) |> min(configured) |> min(1_000)
  end

  defp configured_query_limit do
    Config.settings!().audit.query_limit
  rescue
    _error -> 500
  catch
    _kind, _reason -> 500
  end

  defp execute_statement(connection, sql, parameters) do
    with {:ok, statement} <- Sqlite3.prepare(connection, sql) do
      try do
        with :ok <- Sqlite3.bind(statement, parameters),
             :done <- Sqlite3.step(connection, statement) do
          :ok
        else
          {:error, reason} -> {:error, reason}
          other -> {:error, {:unexpected_sqlite_result, other}}
        end
      after
        Sqlite3.release(connection, statement)
      end
    end
  end

  defp query_rows(connection, sql, parameters) do
    case Sqlite3.prepare(connection, sql) do
      {:ok, statement} ->
        try do
          :ok = Sqlite3.bind(statement, parameters)
          Sqlite3.fetch_all(connection, statement)
        after
          Sqlite3.release(connection, statement)
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp close_connection(nil), do: :ok
  defp close_connection(connection), do: Sqlite3.close(connection)

  defp call(server, message, timeout \\ 15_000) do
    GenServer.call(server, message, timeout)
  catch
    :exit, reason -> {:error, {:audit_unavailable, reason}}
  end
end
