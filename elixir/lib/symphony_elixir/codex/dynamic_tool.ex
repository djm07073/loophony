defmodule SymphonyElixir.Codex.DynamicTool do
  @moduledoc """
  Executes client-side tool calls requested by Codex app-server turns.
  """

  alias SymphonyElixir.{
    AuditLog,
    CheckpointPublisher,
    JobSupervisor,
    Linear.Client,
    Linear.Issue,
    LoopStore,
    MemoryStore,
    RuntimeStore
  }

  @linear_graphql_tool "linear_graphql"
  @linear_graphql_description """
  Execute a raw GraphQL query or mutation against Linear using Symphony's configured auth.
  """
  @linear_graphql_input_schema %{
    "type" => "object",
    "additionalProperties" => false,
    "required" => ["query"],
    "properties" => %{
      "query" => %{
        "type" => "string",
        "description" => "GraphQL query or mutation document to execute against Linear."
      },
      "variables" => %{
        "type" => ["object", "null"],
        "description" => "Optional GraphQL variables object.",
        "additionalProperties" => true
      }
    }
  }

  @loop_checkpoint_tool "symphony_loop_checkpoint"
  @loop_checkpoint_description """
  Persist one structured observe-orient-act-verify-learn-handoff checkpoint to Symphony's local
  SQLite loop memory and append an immutable progress comment to Linear. Use stable checkpoint_key
  values so identical retries do not create duplicate Linear comments.
  """
  @loop_checkpoint_input_schema %{
    "type" => "object",
    "additionalProperties" => false,
    "required" => ["checkpoint_key", "phase", "summary", "decision", "evidence", "next_action", "outcome"],
    "properties" => %{
      "checkpoint_key" => %{"type" => "string", "description" => "Stable idempotency key within this issue."},
      "phase" => %{"type" => "string", "enum" => ~w(observe orient act verify learn handoff)},
      "goal_alignment" => %{"type" => ["string", "null"], "enum" => ["aligned", "adjusted", "rejected", nil]},
      "summary" => %{"type" => "string", "description" => "Observed state or result."},
      "decision" => %{"type" => "string", "description" => "Decision made from the observed feedback."},
      "evidence" => %{
        "type" => "array",
        "items" => %{"type" => "string"},
        "maxItems" => 50,
        "description" => "Concrete tests, metrics, hashes, paths, commits, or Linear references."
      },
      "next_action" => %{"type" => "string", "description" => "The next bounded action or stop rationale."},
      "outcome" => %{"type" => "string", "enum" => ~w(continue waiting done rejected blocked retry)}
    }
  }

  @wait_tool "symphony_wait"
  @wait_description """
  Register a durable automated wait and then end the current turn. The Elixir orchestrator probes
  the timestamp or condition without using Codex and resumes the issue only when it is ready.
  Automated waits are not human Blocked states.
  """
  @wait_input_schema %{
    "type" => "object",
    "additionalProperties" => false,
    "required" => ["reason"],
    "properties" => %{
      "reason" => %{"type" => "string"},
      "wake_at" => %{"type" => ["string", "null"], "description" => "ISO-8601 UTC wake time."},
      "after_ms" => %{"type" => ["integer", "null"], "minimum" => 1},
      "deadline_at" => %{"type" => ["string", "null"], "description" => "ISO-8601 deadline that also wakes the issue."},
      "resume_hint" => %{"type" => ["string", "null"]},
      "heartbeat_interval_ms" => %{"type" => ["integer", "null"], "minimum" => 1},
      "condition" => %{
        "type" => ["object", "null"],
        "additionalProperties" => false,
        "properties" => %{
          "type" => %{
            "type" => "string",
            "enum" => ["file_exists", "file_sha256_changed", "http_status", "job_complete"]
          },
          "path" => %{"type" => "string"},
          "url" => %{"type" => "string"},
          "status" => %{"type" => "integer"},
          "job_id" => %{"type" => "string"},
          "sha256" => %{"type" => "string"}
        }
      }
    }
  }

  @job_start_tool "symphony_job_start"
  @job_start_description """
  Start a detached durable process owned by Loophony from the current issue workspace. Use this
  for collectors or other long-running commands that must survive Codex turn boundaries.
  """
  @job_start_input_schema %{
    "type" => "object",
    "additionalProperties" => false,
    "required" => ["executable"],
    "properties" => %{
      "executable" => %{"type" => "string"},
      "args" => %{"type" => "array", "items" => %{"type" => "string"}, "maxItems" => 128},
      "cwd" => %{"type" => "string", "description" => "Workspace-relative working directory."}
    }
  }

  @job_status_tool "symphony_job_status"
  @job_stop_tool "symphony_job_stop"
  @job_id_input_schema %{
    "type" => "object",
    "additionalProperties" => false,
    "required" => ["job_id"],
    "properties" => %{"job_id" => %{"type" => "string"}}
  }

  @spec execute(String.t() | nil, term(), keyword()) :: map()
  def execute(tool, arguments, opts \\ []) do
    case tool do
      @linear_graphql_tool ->
        execute_linear_graphql(arguments, opts)

      @loop_checkpoint_tool ->
        execute_loop_checkpoint(arguments, opts)

      @wait_tool ->
        execute_wait(arguments, opts)

      @job_start_tool ->
        execute_job_start(arguments, opts)

      @job_status_tool ->
        execute_job_status(arguments, opts)

      @job_stop_tool ->
        execute_job_stop(arguments, opts)

      other ->
        failure_response(%{
          "error" => %{
            "message" => "Unsupported dynamic tool: #{inspect(other)}.",
            "supportedTools" => supported_tool_names()
          }
        })
    end
  end

  @spec tool_specs() :: [map()]
  def tool_specs do
    [
      %{
        "name" => @linear_graphql_tool,
        "description" => @linear_graphql_description,
        "inputSchema" => @linear_graphql_input_schema
      },
      %{
        "name" => @loop_checkpoint_tool,
        "description" => @loop_checkpoint_description,
        "inputSchema" => @loop_checkpoint_input_schema
      },
      %{
        "name" => @wait_tool,
        "description" => @wait_description,
        "inputSchema" => @wait_input_schema
      },
      %{
        "name" => @job_start_tool,
        "description" => @job_start_description,
        "inputSchema" => @job_start_input_schema
      },
      %{
        "name" => @job_status_tool,
        "description" => "Read one durable Loophony job's current state and artifact paths.",
        "inputSchema" => @job_id_input_schema
      },
      %{
        "name" => @job_stop_tool,
        "description" => "Request graceful termination of one durable Loophony job.",
        "inputSchema" => @job_id_input_schema
      }
    ]
  end

  defp execute_linear_graphql(arguments, opts) do
    linear_client = Keyword.get(opts, :linear_client, &Client.graphql/3)

    with {:ok, query, variables} <- normalize_linear_graphql_arguments(arguments),
         {:ok, response} <- linear_client.(query, variables, []) do
      graphql_response(response)
    else
      {:error, reason} ->
        failure_response(tool_error_payload(reason))
    end
  end

  defp execute_loop_checkpoint(arguments, opts) do
    issue = Keyword.get(opts, :issue)
    turn_number = Keyword.get(opts, :turn_number, 1)
    recorder = Keyword.get(opts, :loop_recorder, &LoopStore.record_checkpoint/3)
    memory_indexer = Keyword.get(opts, :memory_indexer, &MemoryStore.index_checkpoint/2)
    checkpoint_publisher = Keyword.get(opts, :checkpoint_publisher, &CheckpointPublisher.publish/2)
    session_context = Map.new(Keyword.take(opts, [:session_id, :thread_id, :turn_id]))

    memory_context =
      session_context
      |> maybe_put(:project_description, issue && issue.project_description)
      |> maybe_put(:issue_description, issue && issue.description)

    checkpoint_arguments =
      if is_map(arguments), do: Map.merge(arguments, session_context), else: arguments

    case issue do
      %Issue{} ->
        record_and_publish_checkpoint(
          issue,
          checkpoint_arguments,
          turn_number,
          recorder,
          memory_indexer,
          memory_context,
          checkpoint_publisher
        )

      _ ->
        failure_response(loop_checkpoint_error(:missing_issue_context))
    end
  end

  defp execute_wait(arguments, opts) do
    issue = Keyword.get(opts, :issue)
    workspace = Keyword.get(opts, :workspace)
    runtime_store = Keyword.get(opts, :runtime_store, RuntimeStore)

    with %Issue{} <- issue,
         true <- is_map(arguments),
         {:ok, normalized} <- normalize_wait_arguments(arguments, workspace),
         {:ok, wait} <- RuntimeStore.register_wait(issue, normalized, runtime_store) do
      payload = Map.put(wait, :instruction, "End the current turn now; Loophony will resume it when the trigger is ready.")
      dynamic_tool_response(true, encode_payload(payload))
    else
      false -> failure_response(%{"error" => %{"message" => "symphony_wait expects an object."}})
      nil -> failure_response(%{"error" => %{"message" => "symphony_wait is missing issue context."}})
      {:error, reason} -> failure_response(%{"error" => %{"message" => "Automated wait was not registered.", "reason" => inspect(reason)}})
      _context -> failure_response(%{"error" => %{"message" => "symphony_wait has invalid issue context."}})
    end
  end

  defp execute_job_start(arguments, opts) do
    issue = Keyword.get(opts, :issue)
    workspace = Keyword.get(opts, :workspace)
    supervisor = Keyword.get(opts, :job_supervisor, JobSupervisor)

    with %Issue{} <- issue,
         true <- is_map(arguments),
         {:ok, job} <- JobSupervisor.start_job(issue, arguments, workspace: workspace, server: supervisor) do
      dynamic_tool_response(true, encode_payload(job))
    else
      false -> failure_response(%{"error" => %{"message" => "symphony_job_start expects an object."}})
      nil -> failure_response(%{"error" => %{"message" => "symphony_job_start is missing issue context."}})
      {:error, reason} -> failure_response(%{"error" => %{"message" => "Durable job was not started.", "reason" => inspect(reason)}})
      _context -> failure_response(%{"error" => %{"message" => "symphony_job_start has invalid issue context."}})
    end
  end

  defp execute_job_status(arguments, opts) do
    issue = Keyword.get(opts, :issue)
    runtime_store = Keyword.get(opts, :runtime_store, RuntimeStore)

    with %Issue{id: issue_id} <- issue,
         {:ok, job_id} <- normalize_job_id(arguments),
         {:ok, job} when not is_nil(job) <- RuntimeStore.get_job(job_id, runtime_store),
         true <- job.issue_id == issue_id do
      dynamic_tool_response(true, encode_payload(job))
    else
      nil -> failure_response(%{"error" => %{"message" => "symphony_job_status is missing issue context."}})
      false -> failure_response(%{"error" => %{"message" => "Durable job does not belong to this issue."}})
      {:ok, nil} -> failure_response(%{"error" => %{"message" => "Durable job was not found."}})
      {:error, reason} -> failure_response(%{"error" => %{"message" => "Durable job status is unavailable.", "reason" => inspect(reason)}})
      _context -> failure_response(%{"error" => %{"message" => "symphony_job_status has invalid issue context."}})
    end
  end

  defp execute_job_stop(arguments, opts) do
    issue = Keyword.get(opts, :issue)
    runtime_store = Keyword.get(opts, :runtime_store, RuntimeStore)
    supervisor = Keyword.get(opts, :job_supervisor, JobSupervisor)

    with %Issue{id: issue_id} <- issue,
         {:ok, job_id} <- normalize_job_id(arguments),
         {:ok, job} when not is_nil(job) <- RuntimeStore.get_job(job_id, runtime_store),
         true <- job.issue_id == issue_id,
         {:ok, job} <- JobSupervisor.stop_job(job_id, server: supervisor) do
      dynamic_tool_response(true, encode_payload(job))
    else
      nil -> failure_response(%{"error" => %{"message" => "symphony_job_stop is missing issue context."}})
      false -> failure_response(%{"error" => %{"message" => "Durable job does not belong to this issue."}})
      {:ok, nil} -> failure_response(%{"error" => %{"message" => "Durable job was not found."}})
      {:error, reason} -> failure_response(%{"error" => %{"message" => "Durable job was not stopped.", "reason" => inspect(reason)}})
      _context -> failure_response(%{"error" => %{"message" => "symphony_job_stop has invalid issue context."}})
    end
  end

  defp normalize_wait_arguments(arguments, workspace) do
    condition = Map.get(arguments, "condition") || Map.get(arguments, :condition)

    case normalize_wait_condition(condition, workspace) do
      {:ok, normalized_condition} ->
        normalized =
          arguments
          |> Enum.map(fn {key, value} -> {to_string(key), value} end)
          |> Map.new()
          |> Map.put("condition", normalized_condition)

        {:ok, normalized}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp normalize_wait_condition(nil, _workspace), do: {:ok, %{}}

  defp normalize_wait_condition(condition, workspace) when is_map(condition) do
    normalized = condition |> Enum.map(fn {key, value} -> {to_string(key), value} end) |> Map.new()

    if normalized["type"] in ["file_exists", "file_sha256_changed"] do
      normalize_wait_file_condition(normalized, workspace)
    else
      {:ok, normalized}
    end
  end

  defp normalize_wait_condition(_condition, _workspace), do: {:error, :invalid_wait_condition}

  defp normalize_wait_file_condition(%{"path" => condition_path} = condition, workspace)
       when is_binary(workspace) and is_binary(condition_path) do
    path =
      if Path.type(condition_path) == :absolute,
        do: Path.expand(condition_path),
        else: Path.expand(condition_path, workspace)

    root = Path.expand(workspace)

    if path == root or String.starts_with?(path, String.trim_trailing(root, "/") <> "/") do
      {:ok, Map.put(condition, "path", path)}
    else
      {:error, :wait_path_outside_workspace}
    end
  end

  defp normalize_wait_file_condition(_condition, _workspace), do: {:error, :invalid_wait_file_condition}

  defp normalize_job_id(arguments) when is_map(arguments) do
    case Map.get(arguments, "job_id") || Map.get(arguments, :job_id) do
      job_id when is_binary(job_id) and job_id != "" -> {:ok, job_id}
      _ -> {:error, :job_id_required}
    end
  end

  defp normalize_job_id(_arguments), do: {:error, :invalid_arguments}

  defp record_and_publish_checkpoint(
         issue,
         arguments,
         turn_number,
         recorder,
         memory_indexer,
         memory_context,
         publisher
       ) do
    case recorder.(issue, arguments, turn_number) do
      {:ok, checkpoint} ->
        :ok = memory_indexer.(checkpoint, memory_context)
        publish_checkpoint(issue, checkpoint, publisher)

      {:error, reason} ->
        failure_response(loop_checkpoint_error(reason))
    end
  end

  defp publish_checkpoint(issue, checkpoint, publisher) do
    case publisher.(issue, checkpoint) do
      {:ok, publication} ->
        _ =
          AuditLog.record_async("loop.checkpoint_published", %{
            resource_type: "linear_issue",
            resource_id: issue.id,
            metadata: %{
              issue_identifier: issue.identifier,
              checkpoint_key: Map.get(checkpoint, :checkpoint_key),
              outcome: Map.get(checkpoint, :outcome),
              publication_status: publication.status
            }
          })

        payload = Map.put(checkpoint, :linear_progress, publication)
        dynamic_tool_response(true, encode_payload(payload))

      {:error, reason} ->
        failure_response(checkpoint_publication_error(checkpoint, reason))
    end
  end

  defp loop_checkpoint_error(reason) do
    %{
      "error" => %{
        "message" => "Symphony loop checkpoint was not recorded.",
        "reason" => inspect(reason)
      }
    }
  end

  defp checkpoint_publication_error(checkpoint, reason) do
    %{
      "error" => %{
        "message" => "Checkpoint was stored locally but its append-only Linear comment was not published.",
        "checkpointKey" => Map.get(checkpoint, :checkpoint_key) || Map.get(checkpoint, "checkpoint_key"),
        "reason" => inspect(reason),
        "retryable" => true
      }
    }
  end

  defp maybe_put(map, key, value) when is_binary(value) do
    case String.trim(value) do
      "" -> map
      normalized -> Map.put(map, key, normalized)
    end
  end

  defp maybe_put(map, _key, _value), do: map

  defp normalize_linear_graphql_arguments(arguments) when is_binary(arguments) do
    case String.trim(arguments) do
      "" -> {:error, :missing_query}
      query -> {:ok, query, %{}}
    end
  end

  defp normalize_linear_graphql_arguments(arguments) when is_map(arguments) do
    case normalize_query(arguments) do
      {:ok, query} ->
        case normalize_variables(arguments) do
          {:ok, variables} ->
            {:ok, query, variables}

          {:error, reason} ->
            {:error, reason}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp normalize_linear_graphql_arguments(_arguments), do: {:error, :invalid_arguments}

  defp normalize_query(arguments) do
    case Map.get(arguments, "query") || Map.get(arguments, :query) do
      query when is_binary(query) ->
        case String.trim(query) do
          "" -> {:error, :missing_query}
          trimmed -> {:ok, trimmed}
        end

      _ ->
        {:error, :missing_query}
    end
  end

  defp normalize_variables(arguments) do
    case Map.get(arguments, "variables") || Map.get(arguments, :variables) || %{} do
      variables when is_map(variables) -> {:ok, variables}
      _ -> {:error, :invalid_variables}
    end
  end

  defp graphql_response(response) do
    success =
      case response do
        %{"errors" => errors} when is_list(errors) and errors != [] -> false
        %{errors: errors} when is_list(errors) and errors != [] -> false
        _ -> true
      end

    dynamic_tool_response(success, encode_payload(response))
  end

  defp failure_response(payload) do
    dynamic_tool_response(false, encode_payload(payload))
  end

  defp dynamic_tool_response(success, output) when is_boolean(success) and is_binary(output) do
    %{
      "success" => success,
      "output" => output,
      "contentItems" => [
        %{
          "type" => "inputText",
          "text" => output
        }
      ]
    }
  end

  defp encode_payload(payload) when is_map(payload) or is_list(payload) do
    Jason.encode!(payload, pretty: true)
  end

  defp encode_payload(payload), do: inspect(payload)

  defp tool_error_payload(:missing_query) do
    %{
      "error" => %{
        "message" => "`linear_graphql` requires a non-empty `query` string."
      }
    }
  end

  defp tool_error_payload(:invalid_arguments) do
    %{
      "error" => %{
        "message" => "`linear_graphql` expects either a GraphQL query string or an object with `query` and optional `variables`."
      }
    }
  end

  defp tool_error_payload(:invalid_variables) do
    %{
      "error" => %{
        "message" => "`linear_graphql.variables` must be a JSON object when provided."
      }
    }
  end

  defp tool_error_payload(:missing_linear_api_token) do
    %{
      "error" => %{
        "message" => "Symphony is missing Linear auth. Set `linear.api_key` in `WORKFLOW.md` or export `LINEAR_API_KEY`."
      }
    }
  end

  defp tool_error_payload({:linear_api_status, status}) do
    %{
      "error" => %{
        "message" => "Linear GraphQL request failed with HTTP #{status}.",
        "status" => status
      }
    }
  end

  defp tool_error_payload({:linear_api_request, reason}) do
    %{
      "error" => %{
        "message" => "Linear GraphQL request failed before receiving a successful response.",
        "reason" => inspect(reason)
      }
    }
  end

  defp tool_error_payload(reason) do
    %{
      "error" => %{
        "message" => "Linear GraphQL tool execution failed.",
        "reason" => inspect(reason)
      }
    }
  end

  defp supported_tool_names do
    Enum.map(tool_specs(), & &1["name"])
  end
end
