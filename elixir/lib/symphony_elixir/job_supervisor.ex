defmodule SymphonyElixir.JobSupervisor do
  @moduledoc """
  Supervises detached, durable jobs launched from issue workspaces.

  Job identity, command hashes, logs, exit markers, and state live in `RuntimeStore`, allowing a
  daemon restart to recover observation of an already-running operating-system process.
  """

  use GenServer

  require Logger

  alias SymphonyElixir.{Config, Linear.Issue, PathSafety, RuntimeStore}

  @active_statuses ["starting", "running", "stopping"]
  @process_exit_grace_ms 2_000
  @max_args 128
  @max_arg_bytes 16_000

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @spec start_job(Issue.t(), map(), keyword()) :: {:ok, map()} | {:error, term()}
  def start_job(%Issue{} = issue, attributes, opts \\ []) when is_map(attributes) and is_list(opts) do
    server = Keyword.get(opts, :server, __MODULE__)
    GenServer.call(server, {:start_job, issue, attributes, opts}, 30_000)
  catch
    :exit, reason -> {:error, {:job_supervisor_unavailable, reason}}
  end

  @spec stop_job(String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def stop_job(job_id, opts \\ []) when is_binary(job_id) and is_list(opts) do
    server = Keyword.get(opts, :server, __MODULE__)
    GenServer.call(server, {:stop_job, job_id})
  catch
    :exit, reason -> {:error, {:job_supervisor_unavailable, reason}}
  end

  @spec status(String.t(), keyword()) :: {:ok, map() | nil} | {:error, term()}
  def status(job_id, opts \\ []) when is_binary(job_id) and is_list(opts) do
    store = Keyword.get(opts, :runtime_store, RuntimeStore)
    RuntimeStore.get_job(job_id, store)
  end

  @spec list(map(), keyword()) :: {:ok, [map()]} | {:error, term()}
  def list(filters \\ %{}, opts \\ []) when is_map(filters) and is_list(opts) do
    store = Keyword.get(opts, :runtime_store, RuntimeStore)
    RuntimeStore.list_jobs(filters, store)
  end

  @impl true
  def init(opts) do
    state = %{
      runtime_store: Keyword.get(opts, :runtime_store, RuntimeStore),
      poll_interval_ms: Keyword.get(opts, :poll_interval_ms),
      timer_ref: nil
    }

    {:ok, schedule_poll(state, 0)}
  end

  @impl true
  def handle_call({:start_job, issue, attributes, opts}, _from, state) do
    result = do_start_job(issue, attributes, opts, state.runtime_store)
    {:reply, result, state}
  end

  def handle_call({:stop_job, job_id}, _from, state) do
    result = do_stop_job(job_id, state.runtime_store)
    {:reply, result, state}
  end

  @impl true
  def handle_info(:poll, state) do
    poll_jobs(state.runtime_store)
    {:noreply, schedule_poll(%{state | timer_ref: nil}, poll_interval(state))}
  end

  def handle_info(_message, state), do: {:noreply, state}

  defp do_start_job(%Issue{} = issue, attributes, opts, runtime_store) do
    workspace = Keyword.get(opts, :workspace)
    executable = value(attributes, :executable)
    args = value(attributes, :args) || []
    relative_cwd = value(attributes, :cwd) || "."

    with {:ok, cwd} <- validate_cwd(workspace, relative_cwd),
         {:ok, resolved_executable} <- resolve_executable(executable, cwd, workspace),
         {:ok, normalized_args} <- normalize_args(args),
         {:ok, paths} <- create_job_paths(workspace) do
      command = [resolved_executable | normalized_args]

      case spawn_detached(command, cwd, paths) do
        {:ok, pid} ->
          persist_spawned_job(issue, command, cwd, pid, paths, runtime_store)

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  defp do_stop_job(job_id, runtime_store) do
    case RuntimeStore.get_job(job_id, runtime_store) do
      {:ok, %{status: status} = job} when status in @active_statuses ->
        with :ok <- terminate_job(job) do
          RuntimeStore.update_job(
            job_id,
            %{status: "stopping", heartbeat_at: utc_now()},
            runtime_store
          )
        end

      {:ok, %{} = job} ->
        {:ok, job}

      {:ok, nil} ->
        {:error, :job_not_found}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp poll_jobs(runtime_store) do
    case RuntimeStore.list_jobs(%{}, runtime_store) do
      {:ok, jobs} ->
        jobs
        |> Enum.filter(&(&1.status in @active_statuses))
        |> Enum.each(&refresh_job(&1, runtime_store))

      {:error, reason} ->
        Logger.warning("Unable to poll durable jobs: #{inspect(reason)}")
    end
  end

  defp refresh_job(job, runtime_store) do
    cond do
      exit_code = read_exit_code(job.exit_path) ->
        status = if exit_code == 0, do: "completed", else: "failed"

        _ =
          RuntimeStore.update_job(
            job.job_id,
            %{
              status: status,
              exit_code: exit_code,
              finished_at: utc_now(),
              heartbeat_at: utc_now()
            },
            runtime_store
          )

      process_alive?(job) ->
        status = if job.status == "stopping", do: "stopping", else: "running"
        _ = RuntimeStore.update_job(job.job_id, %{status: status, heartbeat_at: utc_now()}, runtime_store)

      within_process_exit_grace?(job) ->
        _ = RuntimeStore.update_job(job.job_id, %{heartbeat_at: utc_now()}, runtime_store)

      true ->
        _ =
          RuntimeStore.update_job(
            job.job_id,
            %{
              status: "lost",
              finished_at: utc_now(),
              error: "process is absent and no durable exit marker was written"
            },
            runtime_store
          )
    end
  end

  defp validate_cwd(workspace, relative_cwd) when is_binary(workspace) and is_binary(relative_cwd) do
    candidate = if Path.type(relative_cwd) == :absolute, do: relative_cwd, else: Path.join(workspace, relative_cwd)

    with {:ok, canonical_workspace} <- PathSafety.canonicalize(workspace),
         {:ok, canonical_candidate} <- PathSafety.canonicalize(candidate),
         true <- descendant?(canonical_candidate, canonical_workspace),
         true <- File.dir?(canonical_candidate) do
      {:ok, canonical_candidate}
    else
      false -> {:error, :job_cwd_outside_workspace}
      {:error, reason} -> {:error, reason}
    end
  end

  defp validate_cwd(_workspace, _relative_cwd), do: {:error, :job_workspace_required}

  defp resolve_executable(executable, cwd, workspace) when is_binary(executable) do
    with {:ok, candidate} <- executable_candidate(executable, cwd),
         :ok <- validate_executable_scope(executable, candidate, workspace),
         true <- File.regular?(candidate) do
      {:ok, candidate}
    else
      false -> {:error, :job_executable_not_found}
      {:error, reason} -> {:error, reason}
    end
  end

  defp resolve_executable(_executable, _cwd, _workspace), do: {:error, :job_executable_required}

  defp persist_spawned_job(issue, command, cwd, pid, paths, runtime_store) do
    job = job_record(issue, command, cwd, pid, paths)

    case RuntimeStore.create_job(job, runtime_store) do
      {:ok, stored} ->
        {:ok, stored}

      {:error, reason} ->
        _ = terminate_job(job)
        {:error, {:job_persistence_failed, reason}}
    end
  end

  defp executable_candidate(executable, cwd) do
    cond do
      Path.type(executable) == :absolute -> {:ok, executable}
      String.contains?(executable, "/") -> {:ok, Path.expand(executable, cwd)}
      candidate = System.find_executable(executable) -> {:ok, candidate}
      true -> {:error, :job_executable_not_found}
    end
  end

  defp validate_executable_scope(executable, candidate, workspace) do
    if workspace_relative_executable?(executable) and
         !descendant?(candidate, Path.expand(workspace)) do
      {:error, :job_executable_outside_workspace}
    else
      :ok
    end
  end

  defp workspace_relative_executable?(executable) do
    Path.type(executable) != :absolute and String.contains?(executable, "/")
  end

  defp normalize_args(args) when is_list(args) and length(args) <= @max_args do
    if Enum.all?(args, &(is_binary(&1) and byte_size(&1) <= @max_arg_bytes)) do
      {:ok, args}
    else
      {:error, :invalid_job_args}
    end
  end

  defp normalize_args(_args), do: {:error, :invalid_job_args}

  defp create_job_paths(workspace) do
    job_id = random_id()
    directory = Path.join([workspace, ".loophony", "jobs", job_id])

    with :ok <- File.mkdir_p(directory) do
      {:ok,
       %{
         job_id: job_id,
         directory: directory,
         log_path: Path.join(directory, "job.log"),
         exit_path: Path.join(directory, "exit-code")
       }}
    end
  end

  defp spawn_detached(command, cwd, paths) do
    [executable | args] = command
    command_line = Enum.map_join([executable | args], " ", &shell_quote/1)

    inner = """
    finish() { status="$1"; printf '%s\\n' "$status" > #{shell_quote(paths.exit_path)}; exit "$status"; }
    trap 'kill -TERM "$child" 2>/dev/null; wait "$child"; finish $?' TERM INT
    #{command_line} &
    child=$!
    wait "$child"
    finish $?
    """

    script =
      "/usr/bin/nohup /bin/sh -c #{shell_quote(inner)} >> #{shell_quote(paths.log_path)} 2>&1 < /dev/null & echo $!"

    case System.cmd("/bin/sh", ["-c", script], cd: cwd, stderr_to_stdout: true) do
      {output, 0} -> parse_pid(output)
      {output, status} -> {:error, {:job_spawn_failed, status, String.slice(output, 0, 1_000)}}
    end
  rescue
    error -> {:error, {:job_spawn_failed, Exception.message(error)}}
  end

  defp parse_pid(output) do
    case Integer.parse(String.trim(output)) do
      {pid, ""} when pid > 1 -> {:ok, pid}
      _ -> {:error, {:invalid_job_pid, String.slice(output, 0, 200)}}
    end
  end

  defp job_record(issue, command, cwd, pid, paths) do
    %{
      job_id: paths.job_id,
      issue_id: issue.id,
      issue_identifier: issue.identifier,
      command: command,
      command_hash: digest(command),
      cwd: cwd,
      pid: pid,
      status: "running",
      log_path: paths.log_path,
      exit_path: paths.exit_path,
      started_at: utc_now(),
      heartbeat_at: utc_now()
    }
  end

  defp terminate_pid(pid) when is_integer(pid) and pid > 1 do
    case System.cmd("/bin/kill", ["-TERM", Integer.to_string(pid)], stderr_to_stdout: true) do
      {_output, 0} -> :ok
      {output, status} -> {:error, {:job_stop_failed, status, String.trim(output)}}
    end
  end

  defp terminate_pid(_pid), do: {:error, :invalid_job_pid}

  defp terminate_job(%{pid: pid} = job) do
    if process_owned?(job), do: terminate_pid(pid), else: {:error, :job_process_identity_mismatch}
  end

  defp process_alive?(%{pid: pid} = job) when is_integer(pid) and pid > 1 do
    case System.cmd("/bin/kill", ["-0", Integer.to_string(pid)], stderr_to_stdout: true) do
      {_output, 0} -> process_owned?(job)
      _ -> false
    end
  end

  defp process_alive?(_job), do: false

  defp process_owned?(%{pid: pid, exit_path: exit_path})
       when is_integer(pid) and pid > 1 and is_binary(exit_path) do
    case System.cmd("/bin/ps", ["-ww", "-p", Integer.to_string(pid), "-o", "command="], stderr_to_stdout: true) do
      {command, 0} -> String.contains?(command, exit_path)
      _ -> false
    end
  end

  defp process_owned?(_job), do: false

  defp within_process_exit_grace?(%{started_at: started_at}) when is_binary(started_at) do
    case DateTime.from_iso8601(started_at) do
      {:ok, datetime, _offset} -> DateTime.diff(DateTime.utc_now(), datetime, :millisecond) < @process_exit_grace_ms
      _ -> false
    end
  end

  defp within_process_exit_grace?(_job), do: false

  defp read_exit_code(path) when is_binary(path) do
    case File.read(path) do
      {:ok, content} ->
        case Integer.parse(String.trim(content)) do
          {code, ""} -> code
          _ -> nil
        end

      _ ->
        nil
    end
  end

  defp read_exit_code(_path), do: nil

  defp schedule_poll(state, delay_ms) do
    if is_reference(state.timer_ref), do: Process.cancel_timer(state.timer_ref)
    %{state | timer_ref: Process.send_after(self(), :poll, max(delay_ms, 0))}
  end

  defp poll_interval(state) do
    state.poll_interval_ms || configured_poll_interval()
  end

  defp configured_poll_interval do
    Config.settings!().automation.job_poll_interval_ms
  rescue
    _error -> 1_000
  catch
    _kind, _reason -> 1_000
  end

  defp descendant?(path, root) do
    path == root or String.starts_with?(path, String.trim_trailing(root, "/") <> "/")
  end

  defp shell_quote(value) do
    "'" <> String.replace(value, "'", "'\"'\"'") <> "'"
  end

  defp digest(value) do
    value
    |> Jason.encode!()
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end

  defp random_id, do: 12 |> :crypto.strong_rand_bytes() |> Base.url_encode64(padding: false)
  defp utc_now, do: DateTime.utc_now() |> DateTime.truncate(:microsecond) |> DateTime.to_iso8601()
  defp value(map, key), do: Map.get(map, key) || Map.get(map, Atom.to_string(key))
end
