defmodule SymphonyElixir.RuntimeStore do
  @moduledoc """
  Durable state for automated waits, supervised jobs, and budget usage.

  Unlike the append-only audit trail, these tables represent current runtime state and may be
  updated. Every material transition is also appended to `SymphonyElixir.AuditLog`.
  """

  use GenServer

  alias Exqlite.Sqlite3
  alias SymphonyElixir.{AuditLog, Config, Linear.Issue}

  @schema """
  PRAGMA journal_mode = WAL;
  PRAGMA synchronous = NORMAL;
  PRAGMA busy_timeout = 5000;

  CREATE TABLE IF NOT EXISTS automated_waits (
    wait_id TEXT PRIMARY KEY,
    issue_id TEXT NOT NULL,
    issue_identifier TEXT NOT NULL,
    reason TEXT NOT NULL,
    wake_at TEXT,
    deadline_at TEXT,
    condition_json TEXT NOT NULL,
    resume_hint TEXT,
    heartbeat_interval_ms INTEGER,
    status TEXT NOT NULL,
    created_at TEXT NOT NULL,
    released_at TEXT,
    release_reason TEXT
  );

  CREATE UNIQUE INDEX IF NOT EXISTS idx_automated_waits_active_issue
    ON automated_waits(issue_id) WHERE status = 'waiting';
  CREATE INDEX IF NOT EXISTS idx_automated_waits_status_wake
    ON automated_waits(status, wake_at, created_at);

  CREATE TABLE IF NOT EXISTS durable_jobs (
    job_id TEXT PRIMARY KEY,
    issue_id TEXT NOT NULL,
    issue_identifier TEXT NOT NULL,
    command_json TEXT NOT NULL,
    command_hash TEXT NOT NULL,
    cwd TEXT NOT NULL,
    pid INTEGER,
    status TEXT NOT NULL,
    log_path TEXT NOT NULL,
    exit_path TEXT NOT NULL,
    started_at TEXT NOT NULL,
    heartbeat_at TEXT,
    finished_at TEXT,
    exit_code INTEGER,
    error TEXT
  );

  CREATE INDEX IF NOT EXISTS idx_durable_jobs_issue
    ON durable_jobs(issue_id, started_at DESC);
  CREATE INDEX IF NOT EXISTS idx_durable_jobs_status
    ON durable_jobs(status, started_at);

  CREATE TABLE IF NOT EXISTS issue_usage (
    issue_id TEXT PRIMARY KEY,
    issue_identifier TEXT NOT NULL,
    input_tokens INTEGER NOT NULL DEFAULT 0,
    output_tokens INTEGER NOT NULL DEFAULT 0,
    total_tokens INTEGER NOT NULL DEFAULT 0,
    runtime_seconds INTEGER NOT NULL DEFAULT 0,
    warned_at TEXT,
    exhausted_at TEXT,
    updated_at TEXT NOT NULL
  );

  CREATE TABLE IF NOT EXISTS daily_usage (
    usage_date TEXT PRIMARY KEY,
    input_tokens INTEGER NOT NULL DEFAULT 0,
    output_tokens INTEGER NOT NULL DEFAULT 0,
    total_tokens INTEGER NOT NULL DEFAULT 0,
    runtime_seconds INTEGER NOT NULL DEFAULT 0,
    updated_at TEXT NOT NULL
  );

  CREATE TABLE IF NOT EXISTS runtime_runs (
    run_id TEXT PRIMARY KEY,
    issue_id TEXT NOT NULL,
    runtime_seconds INTEGER NOT NULL,
    finished_at TEXT NOT NULL
  );
  """

  @wait_columns """
  wait_id, issue_id, issue_identifier, reason, wake_at, deadline_at, condition_json,
  resume_hint, heartbeat_interval_ms, status, created_at, released_at, release_reason
  """

  @job_columns """
  job_id, issue_id, issue_identifier, command_json, command_hash, cwd, pid, status,
  log_path, exit_path, started_at, heartbeat_at, finished_at, exit_code, error
  """

  defmodule State do
    @moduledoc false
    defstruct [:connection, :path, :path_override, enabled_override: nil]
  end

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @spec register_wait(Issue.t(), map()) :: {:ok, map()} | {:error, term()}
  def register_wait(%Issue{} = issue, attributes), do: register_wait(issue, attributes, __MODULE__)

  @spec register_wait(Issue.t(), map(), GenServer.server()) :: {:ok, map()} | {:error, term()}
  def register_wait(%Issue{} = issue, attributes, server) when is_map(attributes) do
    call(server, {:register_wait, issue, attributes})
  end

  @spec active_wait(String.t()) :: {:ok, map() | nil} | {:error, term()}
  def active_wait(issue_id), do: active_wait(issue_id, __MODULE__)

  @spec active_wait(String.t(), GenServer.server()) :: {:ok, map() | nil} | {:error, term()}
  def active_wait(issue_id, server) when is_binary(issue_id), do: call(server, {:active_wait, issue_id})

  @spec active_waits() :: {:ok, [map()]} | {:error, term()}
  def active_waits, do: active_waits(__MODULE__)

  @spec active_waits(GenServer.server()) :: {:ok, [map()]} | {:error, term()}
  def active_waits(server), do: active_waits(server, 15_000)

  @spec active_waits(GenServer.server(), timeout()) :: {:ok, [map()]} | {:error, term()}
  def active_waits(server, timeout), do: call(server, :active_waits, timeout)

  @spec release_wait(String.t(), String.t()) :: {:ok, map()} | {:error, term()}
  def release_wait(wait_id, reason), do: release_wait(wait_id, reason, __MODULE__)

  @spec release_wait(String.t(), String.t(), GenServer.server()) :: {:ok, map()} | {:error, term()}
  def release_wait(wait_id, reason, server) when is_binary(wait_id) and is_binary(reason) do
    call(server, {:release_wait, wait_id, reason})
  end

  @spec prompt_context(String.t()) :: String.t()
  def prompt_context(issue_id), do: prompt_context(issue_id, __MODULE__)

  @spec prompt_context(String.t(), GenServer.server()) :: String.t()
  def prompt_context(issue_id, server) when is_binary(issue_id) do
    case call(server, {:latest_released_wait, issue_id}) do
      {:ok, nil} -> ""
      {:ok, wait} -> format_wait_context(wait)
      _ -> ""
    end
  end

  @spec create_job(map()) :: {:ok, map()} | {:error, term()}
  def create_job(job), do: create_job(job, __MODULE__)

  @spec create_job(map(), GenServer.server()) :: {:ok, map()} | {:error, term()}
  def create_job(job, server) when is_map(job), do: call(server, {:create_job, job})

  @spec update_job(String.t(), map()) :: {:ok, map()} | {:error, term()}
  def update_job(job_id, attributes), do: update_job(job_id, attributes, __MODULE__)

  @spec update_job(String.t(), map(), GenServer.server()) :: {:ok, map()} | {:error, term()}
  def update_job(job_id, attributes, server) when is_binary(job_id) and is_map(attributes) do
    call(server, {:update_job, job_id, attributes})
  end

  @spec get_job(String.t()) :: {:ok, map() | nil} | {:error, term()}
  def get_job(job_id), do: get_job(job_id, __MODULE__)

  @spec get_job(String.t(), GenServer.server()) :: {:ok, map() | nil} | {:error, term()}
  def get_job(job_id, server) when is_binary(job_id), do: call(server, {:get_job, job_id})

  @spec list_jobs(map()) :: {:ok, [map()]} | {:error, term()}
  def list_jobs(filters \\ %{}), do: list_jobs(filters, __MODULE__)

  @spec list_jobs(map(), GenServer.server()) :: {:ok, [map()]} | {:error, term()}
  def list_jobs(filters, server) when is_map(filters), do: list_jobs(filters, server, 15_000)

  @spec list_jobs(map(), GenServer.server(), timeout()) :: {:ok, [map()]} | {:error, term()}
  def list_jobs(filters, server, timeout) when is_map(filters) do
    call(server, {:list_jobs, filters}, timeout)
  end

  @spec add_token_usage(String.t(), String.t(), map()) :: {:ok, map()} | {:error, term()}
  def add_token_usage(issue_id, issue_identifier, delta) do
    add_token_usage(issue_id, issue_identifier, delta, __MODULE__)
  end

  @spec add_token_usage(String.t(), String.t(), map(), GenServer.server()) ::
          {:ok, map()} | {:error, term()}
  def add_token_usage(issue_id, issue_identifier, delta, server)
      when is_binary(issue_id) and is_binary(issue_identifier) and is_map(delta) do
    call(server, {:add_token_usage, issue_id, issue_identifier, delta})
  end

  @spec finish_run(String.t(), String.t(), String.t(), non_neg_integer()) ::
          {:ok, map()} | {:error, term()}
  def finish_run(run_id, issue_id, issue_identifier, runtime_seconds) do
    finish_run(run_id, issue_id, issue_identifier, runtime_seconds, __MODULE__)
  end

  @spec finish_run(String.t(), String.t(), String.t(), non_neg_integer(), GenServer.server()) ::
          {:ok, map()} | {:error, term()}
  def finish_run(run_id, issue_id, issue_identifier, runtime_seconds, server)
      when is_binary(run_id) and is_binary(issue_id) and is_binary(issue_identifier) and
             is_integer(runtime_seconds) and runtime_seconds >= 0 do
    call(server, {:finish_run, run_id, issue_id, issue_identifier, runtime_seconds})
  end

  @spec budget_usage(String.t()) :: {:ok, map()} | {:error, term()}
  def budget_usage(issue_id), do: budget_usage(issue_id, __MODULE__)

  @spec budget_usage(String.t(), GenServer.server()) :: {:ok, map()} | {:error, term()}
  def budget_usage(issue_id, server) when is_binary(issue_id),
    do: budget_usage(issue_id, server, 15_000)

  @spec budget_usage(String.t(), GenServer.server(), timeout()) :: {:ok, map()} | {:error, term()}
  def budget_usage(issue_id, server, timeout) when is_binary(issue_id) do
    call(server, {:budget_usage, issue_id}, timeout)
  end

  @spec mark_budget_state(String.t(), String.t()) :: :ok | {:error, term()}
  def mark_budget_state(issue_id, state), do: mark_budget_state(issue_id, state, __MODULE__)

  @spec mark_budget_state(String.t(), String.t(), GenServer.server()) :: :ok | {:error, term()}
  def mark_budget_state(issue_id, state, server) when state in ["warned", "exhausted"] do
    call(server, {:mark_budget_state, issue_id, state})
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

  @impl true
  def init(opts) do
    {:ok,
     %State{
       path_override: Keyword.get(opts, :path),
       enabled_override: Keyword.get(opts, :enabled)
     }}
  end

  @impl true
  def handle_call({:register_wait, issue, attributes}, _from, state) do
    with {:ok, state} <- ensure_connection(state),
         {:ok, wait} <- normalize_wait(issue, attributes),
         :ok <- replace_active_wait(state.connection, wait),
         {:ok, stored} <- select_wait(state.connection, wait.wait_id) do
      audit("wait.registered", stored.issue_id, stored.issue_identifier, %{wait: stored})
      {:reply, {:ok, stored}, state}
    else
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:active_wait, issue_id}, _from, state) do
    reply_with_connection(state, fn connection -> select_active_wait(connection, issue_id) end)
  end

  def handle_call(:active_waits, _from, state) do
    reply_with_connection(state, &select_active_waits/1)
  end

  def handle_call({:release_wait, wait_id, reason}, _from, state) do
    with {:ok, state} <- ensure_connection(state),
         {:ok, released?} <- do_release_wait(state.connection, wait_id, reason),
         {:ok, %{} = wait} <- select_wait(state.connection, wait_id) do
      if released? do
        audit("wait.released", wait.issue_id, wait.issue_identifier, %{wait_id: wait_id, reason: reason})
      end

      {:reply, {:ok, wait}, state}
    else
      {:ok, nil} -> {:reply, {:error, :wait_not_found}, state}
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:latest_released_wait, issue_id}, _from, state) do
    reply_with_connection(state, fn connection -> select_latest_released_wait(connection, issue_id) end)
  end

  def handle_call({:create_job, job}, _from, state) do
    with {:ok, state} <- ensure_connection(state),
         :ok <- insert_job(state.connection, job),
         {:ok, stored} <- select_job(state.connection, value(job, :job_id)) do
      audit("job.started", stored.issue_id, stored.issue_identifier, %{job_id: stored.job_id, command_hash: stored.command_hash})
      {:reply, {:ok, stored}, state}
    else
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:update_job, job_id, attributes}, _from, state) do
    with {:ok, state} <- ensure_connection(state),
         {:ok, %{} = previous} <- select_job(state.connection, job_id),
         :ok <- do_update_job(state.connection, job_id, attributes),
         {:ok, job} when not is_nil(job) <- select_job(state.connection, job_id) do
      if material_job_transition?(previous, job) do
        audit("job.updated", job.issue_id, job.issue_identifier, %{
          job_id: job_id,
          previous_status: previous.status,
          status: job.status,
          exit_code: job.exit_code,
          error: job.error
        })
      end

      {:reply, {:ok, job}, state}
    else
      {:ok, nil} -> {:reply, {:error, :job_not_found}, state}
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:get_job, job_id}, _from, state) do
    reply_with_connection(state, fn connection -> select_job(connection, job_id) end)
  end

  def handle_call({:list_jobs, filters}, _from, state) do
    reply_with_connection(state, fn connection -> select_jobs(connection, filters) end)
  end

  def handle_call({:add_token_usage, issue_id, identifier, delta}, _from, state) do
    with {:ok, state} <- ensure_connection(state),
         :ok <- upsert_token_usage(state.connection, issue_id, identifier, delta),
         {:ok, usage} <- select_budget_usage(state.connection, issue_id) do
      {:reply, {:ok, usage}, state}
    else
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:finish_run, run_id, issue_id, identifier, runtime_seconds}, _from, state) do
    with {:ok, state} <- ensure_connection(state),
         {:ok, inserted?} <-
           finish_runtime_run(state.connection, run_id, issue_id, identifier, runtime_seconds),
         {:ok, usage} <- select_budget_usage(state.connection, issue_id) do
      {:reply, {:ok, Map.put(usage, :runtime_recorded, inserted?)}, state}
    else
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:budget_usage, issue_id}, _from, state) do
    reply_with_connection(state, fn connection -> select_budget_usage(connection, issue_id) end)
  end

  def handle_call({:mark_budget_state, issue_id, budget_state}, _from, state) do
    with {:ok, state} <- ensure_connection(state),
         :ok <- update_budget_state(state.connection, issue_id, budget_state) do
      {:reply, :ok, state}
    else
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  def handle_call(:summary, _from, state) do
    case ensure_connection(state) do
      {:ok, state} -> {:reply, runtime_summary(state.connection, state.path), state}
      {:error, :automation_disabled} -> {:reply, %{enabled: false, available: false}, state}
      {:error, reason} -> {:reply, %{enabled: true, available: false, error: inspect(reason)}, state}
    end
  end

  @impl true
  def terminate(_reason, state) do
    close_connection(state.connection)
    :ok
  end

  defp ensure_connection(%State{} = state) do
    case configured_automation() do
      {:ok, settings} ->
        enabled = if is_boolean(state.enabled_override), do: state.enabled_override, else: settings.enabled
        path = state.path_override || settings.database_path

        cond do
          !enabled ->
            {:error, :automation_disabled}

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

  defp configured_automation do
    {:ok, Config.settings!().automation}
  rescue
    error -> {:error, {:automation_config_unavailable, Exception.message(error)}}
  catch
    kind, reason -> {:error, {:automation_config_unavailable, kind, reason}}
  end

  defp open_connection(path, state) when is_binary(path) do
    with :ok <- File.mkdir_p(Path.dirname(path)),
         {:ok, connection} <- Sqlite3.open(path),
         :ok <- Sqlite3.execute(connection, @schema) do
      {:ok, %{state | connection: connection, path: path}}
    end
  end

  defp normalize_wait(%Issue{id: issue_id, identifier: identifier}, attributes)
       when is_binary(issue_id) and is_binary(identifier) do
    reason = normalized_text(value(attributes, :reason))
    resume_hint = optional_text(value(attributes, :resume_hint))
    wake_at = normalize_wake_at(value(attributes, :wake_at), value(attributes, :after_ms))
    deadline_at = normalize_datetime(value(attributes, :deadline_at))
    condition = normalize_condition(value(attributes, :condition))
    heartbeat = normalize_positive_integer(value(attributes, :heartbeat_interval_ms))

    cond do
      is_nil(reason) ->
        {:error, :wait_reason_required}

      match?({:error, _}, wake_at) ->
        wake_at

      match?({:error, _}, deadline_at) ->
        deadline_at

      is_nil(elem_value(wake_at)) and condition == %{} ->
        {:error, :wait_trigger_required}

      true ->
        {:ok,
         %{
           wait_id: random_id(),
           issue_id: issue_id,
           issue_identifier: identifier,
           reason: reason,
           wake_at: elem_value(wake_at),
           deadline_at: elem_value(deadline_at),
           condition: condition,
           resume_hint: resume_hint,
           heartbeat_interval_ms: heartbeat,
           status: "waiting",
           created_at: utc_now()
         }}
    end
  end

  defp normalize_wait(_issue, _attributes), do: {:error, :invalid_issue}

  defp insert_wait(connection, wait) do
    execute_statement(
      connection,
      """
      INSERT INTO automated_waits (
        wait_id, issue_id, issue_identifier, reason, wake_at, deadline_at, condition_json,
        resume_hint, heartbeat_interval_ms, status, created_at
      ) VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11)
      """,
      [
        wait.wait_id,
        wait.issue_id,
        wait.issue_identifier,
        wait.reason,
        wait.wake_at,
        wait.deadline_at,
        Jason.encode!(wait.condition),
        wait.resume_hint,
        wait.heartbeat_interval_ms,
        wait.status,
        wait.created_at
      ]
    )
  end

  defp supersede_active_wait(connection, issue_id) do
    execute_statement(
      connection,
      "UPDATE automated_waits SET status = 'superseded', released_at = ?1, release_reason = 'replaced' WHERE issue_id = ?2 AND status = 'waiting'",
      [utc_now(), issue_id]
    )
  end

  defp replace_active_wait(connection, wait) do
    with :ok <- Sqlite3.execute(connection, "BEGIN IMMEDIATE"),
         :ok <- supersede_active_wait(connection, wait.issue_id),
         :ok <- insert_wait(connection, wait),
         :ok <- Sqlite3.execute(connection, "COMMIT") do
      :ok
    else
      {:error, reason} ->
        _ = Sqlite3.execute(connection, "ROLLBACK")
        {:error, reason}
    end
  end

  defp do_release_wait(connection, wait_id, reason) do
    with :ok <-
           execute_statement(
             connection,
             "UPDATE automated_waits SET status = 'released', released_at = ?1, release_reason = ?2 WHERE wait_id = ?3 AND status = 'waiting'",
             [utc_now(), String.slice(reason, 0, 1_000), wait_id]
           ) do
      {:ok, changes(connection) > 0}
    end
  end

  defp select_wait(connection, wait_id) do
    select_one(connection, "SELECT #{@wait_columns} FROM automated_waits WHERE wait_id = ?1", [wait_id], &decode_wait/1)
  end

  defp select_active_wait(connection, issue_id) do
    select_one(
      connection,
      "SELECT #{@wait_columns} FROM automated_waits WHERE issue_id = ?1 AND status = 'waiting' ORDER BY created_at DESC LIMIT 1",
      [issue_id],
      &decode_wait/1
    )
  end

  defp select_active_waits(connection) do
    select_many(
      connection,
      "SELECT #{@wait_columns} FROM automated_waits WHERE status = 'waiting' ORDER BY created_at ASC",
      [],
      &decode_wait/1
    )
  end

  defp select_latest_released_wait(connection, issue_id) do
    select_one(
      connection,
      "SELECT #{@wait_columns} FROM automated_waits WHERE issue_id = ?1 AND status = 'released' ORDER BY released_at DESC LIMIT 1",
      [issue_id],
      &decode_wait/1
    )
  end

  defp decode_wait([
         wait_id,
         issue_id,
         issue_identifier,
         reason,
         wake_at,
         deadline_at,
         condition_json,
         resume_hint,
         heartbeat_interval_ms,
         status,
         created_at,
         released_at,
         release_reason
       ]) do
    %{
      wait_id: wait_id,
      issue_id: issue_id,
      issue_identifier: issue_identifier,
      reason: reason,
      wake_at: wake_at,
      deadline_at: deadline_at,
      condition: decode_json_map(condition_json),
      resume_hint: resume_hint,
      heartbeat_interval_ms: heartbeat_interval_ms,
      status: status,
      created_at: created_at,
      released_at: released_at,
      release_reason: release_reason
    }
  end

  defp insert_job(connection, job) do
    command = value(job, :command)

    execute_statement(
      connection,
      """
      INSERT INTO durable_jobs (
        job_id, issue_id, issue_identifier, command_json, command_hash, cwd, pid, status,
        log_path, exit_path, started_at, heartbeat_at
      ) VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11, ?12)
      """,
      [
        value(job, :job_id),
        value(job, :issue_id),
        value(job, :issue_identifier),
        Jason.encode!(command),
        value(job, :command_hash),
        value(job, :cwd),
        value(job, :pid),
        value(job, :status) || "running",
        value(job, :log_path),
        value(job, :exit_path),
        value(job, :started_at) || utc_now(),
        value(job, :heartbeat_at) || utc_now()
      ]
    )
  end

  defp do_update_job(connection, job_id, attributes) do
    allowed = [
      {:pid, "pid"},
      {:status, "status"},
      {:heartbeat_at, "heartbeat_at"},
      {:finished_at, "finished_at"},
      {:exit_code, "exit_code"},
      {:error, "error"}
    ]

    {sets, parameters} =
      Enum.reduce(allowed, {[], []}, fn {key, column}, {sets, parameters} ->
        case fetch_value(attributes, key) do
          {:ok, field_value} ->
            {sets ++ ["#{column} = ?#{length(parameters) + 1}"], parameters ++ [field_value]}

          :error ->
            {sets, parameters}
        end
      end)

    if sets == [] do
      :ok
    else
      execute_statement(
        connection,
        "UPDATE durable_jobs SET #{Enum.join(sets, ", ")} WHERE job_id = ?#{length(parameters) + 1}",
        parameters ++ [job_id]
      )
    end
  end

  defp select_job(connection, job_id) do
    select_one(connection, "SELECT #{@job_columns} FROM durable_jobs WHERE job_id = ?1", [job_id], &decode_job/1)
  end

  defp select_jobs(connection, filters) do
    {where, parameters} = job_filters(filters)

    select_many(
      connection,
      "SELECT #{@job_columns} FROM durable_jobs#{where} ORDER BY started_at DESC LIMIT 200",
      parameters,
      &decode_job/1
    )
  end

  defp job_filters(filters) do
    [{"issue_id", value(filters, :issue_id)}, {"status", value(filters, :status)}]
    |> Enum.reduce({[], []}, fn
      {column, raw}, {clauses, parameters} when is_binary(raw) and raw != "" ->
        {clauses ++ ["#{column} = ?#{length(parameters) + 1}"], parameters ++ [raw]}

      _entry, acc ->
        acc
    end)
    |> then(fn
      {[], parameters} -> {"", parameters}
      {clauses, parameters} -> {" WHERE " <> Enum.join(clauses, " AND "), parameters}
    end)
  end

  defp decode_job([
         job_id,
         issue_id,
         issue_identifier,
         command_json,
         command_hash,
         cwd,
         pid,
         status,
         log_path,
         exit_path,
         started_at,
         heartbeat_at,
         finished_at,
         exit_code,
         error
       ]) do
    %{
      job_id: job_id,
      issue_id: issue_id,
      issue_identifier: issue_identifier,
      command: decode_json_list(command_json),
      command_hash: command_hash,
      cwd: cwd,
      pid: pid,
      status: status,
      log_path: log_path,
      exit_path: exit_path,
      started_at: started_at,
      heartbeat_at: heartbeat_at,
      finished_at: finished_at,
      exit_code: exit_code,
      error: error
    }
  end

  defp material_job_transition?(previous, current) do
    previous.status != current.status or previous.exit_code != current.exit_code or previous.error != current.error
  end

  defp upsert_token_usage(connection, issue_id, identifier, delta) do
    input = non_negative(value(delta, :input_tokens))
    output = non_negative(value(delta, :output_tokens))
    total = non_negative(value(delta, :total_tokens))
    now = utc_now()
    date = String.slice(now, 0, 10)

    with :ok <- Sqlite3.execute(connection, "BEGIN IMMEDIATE"),
         :ok <-
           execute_statement(
             connection,
             """
             INSERT INTO issue_usage (issue_id, issue_identifier, input_tokens, output_tokens, total_tokens, updated_at)
             VALUES (?1, ?2, ?3, ?4, ?5, ?6)
             ON CONFLICT(issue_id) DO UPDATE SET
               issue_identifier = excluded.issue_identifier,
               input_tokens = issue_usage.input_tokens + excluded.input_tokens,
               output_tokens = issue_usage.output_tokens + excluded.output_tokens,
               total_tokens = issue_usage.total_tokens + excluded.total_tokens,
               updated_at = excluded.updated_at
             """,
             [issue_id, identifier, input, output, total, now]
           ),
         :ok <-
           execute_statement(
             connection,
             """
             INSERT INTO daily_usage (usage_date, input_tokens, output_tokens, total_tokens, updated_at)
             VALUES (?1, ?2, ?3, ?4, ?5)
             ON CONFLICT(usage_date) DO UPDATE SET
               input_tokens = daily_usage.input_tokens + excluded.input_tokens,
               output_tokens = daily_usage.output_tokens + excluded.output_tokens,
               total_tokens = daily_usage.total_tokens + excluded.total_tokens,
               updated_at = excluded.updated_at
             """,
             [date, input, output, total, now]
           ),
         :ok <- Sqlite3.execute(connection, "COMMIT") do
      :ok
    else
      {:error, reason} ->
        _ = Sqlite3.execute(connection, "ROLLBACK")
        {:error, reason}
    end
  end

  defp insert_runtime_run(connection, run_id, issue_id, runtime_seconds) do
    with :ok <-
           execute_statement(
             connection,
             "INSERT OR IGNORE INTO runtime_runs (run_id, issue_id, runtime_seconds, finished_at) VALUES (?1, ?2, ?3, ?4)",
             [run_id, issue_id, runtime_seconds, utc_now()]
           ) do
      {:ok, changes(connection) > 0}
    end
  end

  defp finish_runtime_run(connection, run_id, issue_id, identifier, runtime_seconds) do
    with :ok <- Sqlite3.execute(connection, "BEGIN IMMEDIATE"),
         {:ok, inserted?} <- insert_runtime_run(connection, run_id, issue_id, runtime_seconds),
         :ok <- maybe_add_runtime(connection, inserted?, issue_id, identifier, runtime_seconds),
         :ok <- Sqlite3.execute(connection, "COMMIT") do
      {:ok, inserted?}
    else
      {:error, reason} ->
        _ = Sqlite3.execute(connection, "ROLLBACK")
        {:error, reason}
    end
  end

  defp maybe_add_runtime(_connection, false, _issue_id, _identifier, _seconds), do: :ok

  defp maybe_add_runtime(connection, true, issue_id, identifier, seconds) do
    now = utc_now()
    date = String.slice(now, 0, 10)

    with :ok <-
           execute_statement(
             connection,
             """
             INSERT INTO issue_usage (issue_id, issue_identifier, runtime_seconds, updated_at)
             VALUES (?1, ?2, ?3, ?4)
             ON CONFLICT(issue_id) DO UPDATE SET
               issue_identifier = excluded.issue_identifier,
               runtime_seconds = issue_usage.runtime_seconds + excluded.runtime_seconds,
               updated_at = excluded.updated_at
             """,
             [issue_id, identifier, seconds, now]
           ) do
      execute_statement(
        connection,
        """
        INSERT INTO daily_usage (usage_date, runtime_seconds, updated_at)
        VALUES (?1, ?2, ?3)
        ON CONFLICT(usage_date) DO UPDATE SET
          runtime_seconds = daily_usage.runtime_seconds + excluded.runtime_seconds,
          updated_at = excluded.updated_at
        """,
        [date, seconds, now]
      )
    end
  end

  defp select_budget_usage(connection, issue_id) do
    issue_sql =
      "SELECT issue_identifier, input_tokens, output_tokens, total_tokens, runtime_seconds, warned_at, exhausted_at, updated_at FROM issue_usage WHERE issue_id = ?1"

    daily_sql =
      "SELECT usage_date, input_tokens, output_tokens, total_tokens, runtime_seconds, updated_at FROM daily_usage WHERE usage_date = ?1"

    date = Date.utc_today() |> Date.to_iso8601()

    with {:ok, issue_rows} <- query_rows(connection, issue_sql, [issue_id]),
         {:ok, daily_rows} <- query_rows(connection, daily_sql, [date]) do
      {:ok,
       %{
         issue: decode_issue_usage(issue_id, issue_rows),
         daily: decode_daily_usage(date, daily_rows)
       }}
    end
  end

  defp decode_issue_usage(issue_id, [
         [identifier, input, output, total, runtime, warned_at, exhausted_at, updated_at]
       ]) do
    %{
      issue_id: issue_id,
      issue_identifier: identifier,
      input_tokens: input,
      output_tokens: output,
      total_tokens: total,
      runtime_seconds: runtime,
      warned_at: warned_at,
      exhausted_at: exhausted_at,
      updated_at: updated_at
    }
  end

  defp decode_issue_usage(issue_id, _rows) do
    %{
      issue_id: issue_id,
      issue_identifier: nil,
      input_tokens: 0,
      output_tokens: 0,
      total_tokens: 0,
      runtime_seconds: 0,
      warned_at: nil,
      exhausted_at: nil,
      updated_at: nil
    }
  end

  defp decode_daily_usage(_date, [[usage_date, input, output, total, runtime, updated_at]]) do
    %{
      usage_date: usage_date,
      input_tokens: input,
      output_tokens: output,
      total_tokens: total,
      runtime_seconds: runtime,
      updated_at: updated_at
    }
  end

  defp decode_daily_usage(date, _rows) do
    %{usage_date: date, input_tokens: 0, output_tokens: 0, total_tokens: 0, runtime_seconds: 0, updated_at: nil}
  end

  defp update_budget_state(connection, issue_id, "warned") do
    execute_statement(
      connection,
      "UPDATE issue_usage SET warned_at = coalesce(warned_at, ?1) WHERE issue_id = ?2",
      [utc_now(), issue_id]
    )
  end

  defp update_budget_state(connection, issue_id, "exhausted") do
    execute_statement(
      connection,
      "UPDATE issue_usage SET exhausted_at = coalesce(exhausted_at, ?1) WHERE issue_id = ?2",
      [utc_now(), issue_id]
    )
  end

  defp runtime_summary(connection, path) do
    with {:ok, [[wait_count]]} <-
           query_rows(connection, "SELECT COUNT(*) FROM automated_waits WHERE status = 'waiting'", []),
         {:ok, [[job_count]]} <-
           query_rows(connection, "SELECT COUNT(*) FROM durable_jobs WHERE status IN ('starting', 'running', 'stopping')", []),
         {:ok, daily} <- select_budget_usage(connection, "__summary__") do
      %{
        enabled: true,
        available: true,
        path: path,
        waiting_count: wait_count,
        active_job_count: job_count,
        daily_usage: daily.daily
      }
    else
      {:error, reason} -> %{enabled: true, available: false, path: path, error: inspect(reason)}
    end
  end

  defp reply_with_connection(state, fun) do
    case ensure_connection(state) do
      {:ok, state} -> {:reply, fun.(state.connection), state}
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  defp select_one(connection, sql, parameters, decoder) do
    case query_rows(connection, sql, parameters) do
      {:ok, [row]} -> {:ok, decoder.(row)}
      {:ok, []} -> {:ok, nil}
      {:error, reason} -> {:error, reason}
    end
  end

  defp select_many(connection, sql, parameters, decoder) do
    case query_rows(connection, sql, parameters) do
      {:ok, rows} -> {:ok, Enum.map(rows, decoder)}
      {:error, reason} -> {:error, reason}
    end
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

  defp changes(connection) do
    case query_rows(connection, "SELECT changes()", []) do
      {:ok, [[count]]} when is_integer(count) -> count
      _ -> 0
    end
  end

  defp normalize_wake_at(wake_at, after_ms) do
    cond do
      is_integer(after_ms) and after_ms > 0 ->
        {:ok, DateTime.utc_now() |> DateTime.add(after_ms, :millisecond) |> DateTime.to_iso8601()}

      is_binary(wake_at) ->
        normalize_datetime(wake_at)

      true ->
        {:ok, nil}
    end
  end

  defp normalize_datetime(nil), do: {:ok, nil}

  defp normalize_datetime(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, datetime, _offset} -> {:ok, DateTime.to_iso8601(datetime)}
      _ -> {:error, :invalid_datetime}
    end
  end

  defp normalize_datetime(_value), do: {:error, :invalid_datetime}

  defp elem_value({:ok, value}), do: value
  defp elem_value(_value), do: nil

  defp normalize_condition(condition) when is_map(condition) do
    condition
    |> Enum.map(fn {key, val} -> {to_string(key), val} end)
    |> Map.new()
    |> Map.take(["type", "path", "url", "status", "job_id", "sha256"])
  end

  defp normalize_condition(_condition), do: %{}

  defp normalize_positive_integer(value) when is_integer(value) and value > 0, do: value
  defp normalize_positive_integer(_value), do: nil

  defp format_wait_context(wait) do
    """
    Automated wait resumed:

    - wait_id: #{wait.wait_id}
    - original reason: #{wait.reason}
    - released because: #{wait.release_reason}
    - released at: #{wait.released_at}
    - resume hint: #{wait.resume_hint || "none"}

    Refresh the relevant evidence before acting. Do not recreate the same wait unless the trigger
    is still unmet.
    """
    |> String.trim()
  end

  defp audit(action, issue_id, identifier, metadata) do
    _ =
      AuditLog.record_async(action, %{
        resource_type: "linear_issue",
        resource_id: issue_id,
        metadata: Map.put(metadata, :issue_identifier, identifier)
      })

    :ok
  end

  defp random_id, do: 12 |> :crypto.strong_rand_bytes() |> Base.url_encode64(padding: false)
  defp utc_now, do: DateTime.utc_now() |> DateTime.truncate(:microsecond) |> DateTime.to_iso8601()
  defp non_negative(value) when is_integer(value), do: max(value, 0)
  defp non_negative(_value), do: 0

  defp normalized_text(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      text -> String.slice(text, 0, 8_000)
    end
  end

  defp normalized_text(_value), do: nil
  defp optional_text(value), do: normalized_text(value)

  defp decode_json_map(json) do
    case Jason.decode(json) do
      {:ok, value} when is_map(value) -> value
      _ -> %{}
    end
  end

  defp decode_json_list(json) do
    case Jason.decode(json) do
      {:ok, value} when is_list(value) -> value
      _ -> []
    end
  end

  defp value(map, key) when is_map(map), do: Map.get(map, key) || Map.get(map, Atom.to_string(key))
  defp value(_map, _key), do: nil

  defp fetch_value(map, key) do
    cond do
      Map.has_key?(map, key) -> {:ok, Map.get(map, key)}
      Map.has_key?(map, Atom.to_string(key)) -> {:ok, Map.get(map, Atom.to_string(key))}
      true -> :error
    end
  end

  defp close_connection(nil), do: :ok
  defp close_connection(connection), do: Sqlite3.close(connection)

  defp call(server, message, timeout \\ 15_000) do
    GenServer.call(server, message, timeout)
  catch
    :exit, reason -> {:error, {:runtime_store_unavailable, reason}}
  end
end
