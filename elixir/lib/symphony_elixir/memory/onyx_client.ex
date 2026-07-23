defmodule SymphonyElixir.Memory.OnyxClient do
  @moduledoc """
  HTTP client for a self-hosted Onyx knowledge index.

  Loophony uses Onyx's Ingestion API for deterministic document upserts and the Search UI API for
  LLM-free hybrid retrieval. The API key stays in the daemon and is never forwarded to Codex
  tools.
  """

  @request_timeout_ms 90_000

  @spec health(map()) :: {:ok, map()} | {:error, term()}
  def health(settings) when is_map(settings) do
    request(:get, health_url(settings.onyx_api_url), settings)
  end

  @spec current_search_settings(map()) :: {:ok, map()} | {:error, term()}
  def current_search_settings(settings) when is_map(settings) do
    request(:get, endpoint(settings, "/search-settings/get-current-search-settings"), settings)
  end

  @spec ingest(map(), map()) :: {:ok, map()} | {:error, term()}
  def ingest(document, settings) when is_map(document) and is_map(settings) do
    request(:post, endpoint(settings, "/onyx-api/ingestion"), settings, json: document)
  end

  @spec search(map(), map()) :: {:ok, map()} | {:error, term()}
  def search(search_request, settings) when is_map(search_request) and is_map(settings) do
    request(:post, endpoint(settings, "/search/send-search-message"), settings, json: search_request)
  end

  defp request(method, url, settings, options \\ []) do
    options =
      options
      |> Keyword.put_new(:receive_timeout, @request_timeout_ms)
      |> Keyword.put(:headers, request_headers(settings, Keyword.get(options, :headers, [])))

    case Req.request(Keyword.merge(options, method: method, url: url)) do
      {:ok, %{status: status, body: body}} when status in 200..299 ->
        {:ok, normalize_body(body)}

      {:ok, %{status: status, body: body}} ->
        {:error, {:onyx_status, status, summarize(body)}}

      {:error, reason} ->
        {:error, {:onyx_request, reason}}
    end
  end

  defp request_headers(settings, headers) do
    case Map.get(settings, :onyx_api_key) do
      token when is_binary(token) and token != "" ->
        [{"authorization", "Bearer " <> token}, {"accept", "application/json"} | headers]

      _other ->
        [{"accept", "application/json"} | headers]
    end
  end

  defp endpoint(settings, path), do: String.trim_trailing(settings.onyx_api_url, "/") <> path

  defp health_url(api_url) do
    uri = URI.parse(api_url)
    URI.to_string(%{uri | path: "/health", query: nil, fragment: nil})
  end

  defp normalize_body(body) when is_map(body), do: body

  defp normalize_body(body) when is_binary(body) do
    case Jason.decode(body) do
      {:ok, decoded} when is_map(decoded) -> decoded
      _other -> %{"body" => body}
    end
  end

  defp normalize_body(body), do: %{"body" => inspect(body)}

  defp summarize(body) when is_binary(body), do: String.slice(body, 0, 1_000)
  defp summarize(body), do: inspect(body, limit: 30, printable_limit: 1_000)
end
