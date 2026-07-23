defmodule SymphonyElixir.MemoryEvaluation do
  @moduledoc """
  Deterministic retrieval-quality evaluation for Korean and English golden questions.

  Answer prose is deliberately out of scope: this evaluates whether expected evidence appears in
  the top retrieved results with intact provenance.
  """

  @spec evaluate([map()], (String.t(), map() -> {:ok, map()} | {:error, term()}), keyword()) :: map()
  def evaluate(cases, searcher, opts \\ [])
      when is_list(cases) and is_function(searcher, 2) and is_list(opts) do
    k = Keyword.get(opts, :k, 10) |> max(1)
    results = Enum.map(cases, &evaluate_case(&1, searcher, k))
    recalls = Enum.map(results, & &1.recall_at_k)

    %{
      total_cases: length(results),
      passed_cases: Enum.count(results, & &1.passed),
      failed_cases: Enum.count(results, &(not &1.passed)),
      mean_recall_at_k: mean(recalls),
      k: k,
      results: results
    }
  end

  defp evaluate_case(test_case, searcher, k) do
    query = value(test_case, :query) || ""
    expected = value(test_case, :expected_evidence_ids) || []
    filters = value(test_case, :filters) || %{}

    case searcher.(query, Map.put(filters, :limit, k)) do
      {:ok, payload} ->
        actual =
          payload
          |> value(:matches)
          |> List.wrap()
          |> Enum.take(k)
          |> Enum.map(&value(&1, :evidence_id))
          |> Enum.filter(&is_binary/1)

        hits = Enum.count(expected, &(&1 in actual))
        recall = if expected == [], do: 1.0, else: hits / length(expected)

        %{
          id: value(test_case, :id),
          query: query,
          expected_evidence_ids: expected,
          actual_evidence_ids: actual,
          recall_at_k: recall,
          passed: recall == 1.0,
          error: nil
        }

      {:error, reason} ->
        %{
          id: value(test_case, :id),
          query: query,
          expected_evidence_ids: expected,
          actual_evidence_ids: [],
          recall_at_k: 0.0,
          passed: false,
          error: inspect(reason)
        }
    end
  end

  defp mean([]), do: 0.0
  defp mean(values), do: Enum.sum(values) / length(values)

  defp value(map, key) when is_map(map), do: Map.get(map, key) || Map.get(map, Atom.to_string(key))
  defp value(_map, _key), do: nil
end
