defmodule SymphonyElixir.WaitCondition do
  @moduledoc """
  Evaluates durable automated-wait triggers without invoking Codex.
  """

  alias SymphonyElixir.{Config, JobSupervisor}

  @spec ready?(map(), keyword()) :: {:ready, String.t()} | :waiting | {:error, term()}
  def ready?(wait, opts \\ []) when is_map(wait) and is_list(opts) do
    now = Keyword.get(opts, :now, DateTime.utc_now())

    cond do
      reached?(Map.get(wait, :deadline_at), now) ->
        {:ready, "deadline_reached"}

      reached?(Map.get(wait, :wake_at), now) ->
        {:ready, "wake_at_reached"}

      true ->
        evaluate_condition(Map.get(wait, :condition, %{}), opts)
    end
  end

  defp evaluate_condition(condition, _opts) when map_size(condition) == 0, do: :waiting

  defp evaluate_condition(%{"type" => "file_exists", "path" => path}, _opts) when is_binary(path) do
    if File.regular?(path) or File.dir?(path), do: {:ready, "file_exists"}, else: :waiting
  end

  defp evaluate_condition(%{"type" => "file_sha256_changed", "path" => path} = condition, _opts)
       when is_binary(path) do
    expected = Map.get(condition, "sha256")

    case File.read(path) do
      {:ok, content} ->
        actual = :crypto.hash(:sha256, content) |> Base.encode16(case: :lower)
        if is_binary(expected) and actual != String.downcase(expected), do: {:ready, "file_sha256_changed"}, else: :waiting

      {:error, :enoent} ->
        :waiting

      {:error, reason} ->
        {:error, {:file_probe_failed, reason}}
    end
  end

  defp evaluate_condition(%{"type" => "http_status", "url" => url} = condition, opts)
       when is_binary(url) do
    expected = Map.get(condition, "status", 200)
    http_get = Keyword.get(opts, :http_get, &default_http_get/1)

    with :ok <- validate_http_url(url),
         {:ok, status} <- http_get.(url) do
      if status == expected, do: {:ready, "http_status_#{status}"}, else: :waiting
    end
  end

  defp evaluate_condition(%{"type" => "job_complete", "job_id" => job_id}, opts)
       when is_binary(job_id) do
    job_status = Keyword.get(opts, :job_status, &JobSupervisor.status/1)

    case job_status.(job_id) do
      {:ok, %{status: status}} when status in ["completed", "failed", "lost"] ->
        {:ready, "job_#{status}"}

      {:ok, %{}} ->
        :waiting

      {:ok, nil} ->
        {:error, :job_not_found}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp evaluate_condition(%{"type" => type}, _opts), do: {:error, {:unsupported_wait_condition, type}}
  defp evaluate_condition(_condition, _opts), do: {:error, :invalid_wait_condition}

  defp reached?(nil, _now), do: false

  defp reached?(iso8601, now) when is_binary(iso8601) do
    case DateTime.from_iso8601(iso8601) do
      {:ok, datetime, _offset} -> DateTime.compare(now, datetime) in [:eq, :gt]
      _ -> false
    end
  end

  defp reached?(_value, _now), do: false

  defp validate_http_url(url) do
    uri = URI.parse(url)

    with {:ok, allowed_hosts} <- configured_allowed_hosts() do
      cond do
        uri.scheme not in ["http", "https"] -> {:error, :unsupported_wait_url_scheme}
        !is_binary(uri.host) -> {:error, :invalid_wait_url}
        String.downcase(uri.host) not in allowed_hosts -> {:error, :wait_url_host_not_allowed}
        true -> :ok
      end
    end
  end

  defp configured_allowed_hosts do
    {:ok, Config.settings!().automation.allowed_http_hosts}
  rescue
    error -> {:error, {:automation_config_unavailable, Exception.message(error)}}
  catch
    kind, reason -> {:error, {:automation_config_unavailable, kind, reason}}
  end

  defp default_http_get(url) do
    case Req.get(url, receive_timeout: 5_000, redirect: false) do
      {:ok, %{status: status}} -> {:ok, status}
      {:error, reason} -> {:error, {:wait_http_probe_failed, reason}}
    end
  end
end
