defmodule SymphonyElixir.BudgetPolicy do
  @moduledoc """
  Evaluates issue and daily token/runtime usage against configured safety budgets.
  """

  alias SymphonyElixir.Config

  @spec evaluate(map(), keyword()) :: map()
  def evaluate(usage, opts \\ []) when is_map(usage) and is_list(opts) do
    settings = Keyword.get(opts, :settings, Config.settings!().budget)
    issue = Map.get(usage, :issue, %{})
    daily = Map.get(usage, :daily, %{})

    if settings.enabled do
      metrics = %{
        issue_tokens: metric(Map.get(issue, :total_tokens, 0), settings.max_tokens_per_issue),
        daily_tokens: metric(Map.get(daily, :total_tokens, 0), settings.max_tokens_per_day),
        issue_runtime_seconds: metric(Map.get(issue, :runtime_seconds, 0), settings.max_active_seconds_per_issue)
      }

      exhausted =
        metrics
        |> Enum.filter(fn {_name, metric} -> metric.exhausted end)
        |> Enum.map(fn {name, _metric} -> Atom.to_string(name) end)

      maximum_percent = metrics |> Map.values() |> Enum.map(& &1.percent) |> Enum.max(fn -> 0 end)

      status =
        cond do
          exhausted != [] -> "exhausted"
          maximum_percent >= settings.warn_at_percent -> "warning"
          true -> "ok"
        end

      %{
        enabled: true,
        status: status,
        action: settings.on_exhausted,
        warn_at_percent: settings.warn_at_percent,
        maximum_percent: maximum_percent,
        exhausted_reasons: exhausted,
        metrics: metrics,
        usage: usage
      }
    else
      %{enabled: false, status: "disabled", exhausted_reasons: [], usage: usage}
    end
  end

  defp metric(used, limit) when is_integer(used) and is_integer(limit) and limit > 0 do
    %{
      used: max(used, 0),
      limit: limit,
      percent: min(div(max(used, 0) * 100, limit), 10_000),
      exhausted: used >= limit
    }
  end

  defp metric(_used, limit), do: %{used: 0, limit: limit, percent: 0, exhausted: false}
end
