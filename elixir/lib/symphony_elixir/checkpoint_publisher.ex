defmodule SymphonyElixir.CheckpointPublisher do
  @moduledoc """
  Publishes durable loop checkpoints as append-only Linear comments.

  Each semantic checkpoint revision receives a deterministic marker. Before creating a comment,
  the publisher checks recent issue comments for that marker so a retried tool call does not create
  a duplicate. Existing comments are never edited or deleted.
  """

  alias SymphonyElixir.Linear.{Adapter, Issue}

  @max_field_characters 4_000
  @max_evidence_items 20
  @max_evidence_characters 2_000

  @spec publish(Issue.t(), map()) :: {:ok, map()} | {:error, term()}
  def publish(%Issue{} = issue, checkpoint) do
    opts = Application.get_env(:symphony_elixir, :checkpoint_publisher_options, [])
    publish(issue, checkpoint, opts)
  end

  @spec publish(Issue.t(), map(), keyword()) :: {:ok, map()} | {:error, term()}
  def publish(%Issue{id: issue_id} = issue, checkpoint, opts)
      when is_binary(issue_id) and is_map(checkpoint) and is_list(opts) do
    comment_lister = Keyword.get(opts, :comment_lister, &Adapter.comment_bodies/1)
    comment_creator = Keyword.get(opts, :comment_creator, &Adapter.create_comment/2)
    fingerprint = fingerprint(issue, checkpoint)
    marker = marker(fingerprint)

    case comment_lister.(issue_id) do
      {:ok, comments} ->
        publish_unless_present(
          comments,
          issue_id,
          checkpoint,
          marker,
          fingerprint,
          comment_creator
        )

      {:error, reason} ->
        {:error, {:comment_lookup_failed, reason}}

      other ->
        {:error, {:comment_lookup_failed, other}}
    end
  end

  defp publish_unless_present(comments, issue_id, checkpoint, marker, fingerprint, comment_creator) do
    if Enum.any?(comments, &String.contains?(&1, marker)) do
      {:ok, %{status: "already_published", fingerprint: fingerprint}}
    else
      create_checkpoint_comment(issue_id, checkpoint, marker, fingerprint, comment_creator)
    end
  end

  defp create_checkpoint_comment(issue_id, checkpoint, marker, fingerprint, comment_creator) do
    case comment_creator.(issue_id, format_comment(checkpoint, marker)) do
      :ok -> {:ok, %{status: "appended", fingerprint: fingerprint}}
      {:error, reason} -> {:error, {:comment_create_failed, reason}}
      other -> {:error, {:comment_create_failed, other}}
    end
  end

  defp fingerprint(issue, checkpoint) do
    canonical = %{
      issue_id: issue.id,
      checkpoint_key: value(checkpoint, :checkpoint_key),
      phase: value(checkpoint, :phase),
      goal_alignment: value(checkpoint, :goal_alignment),
      summary: value(checkpoint, :summary),
      decision: value(checkpoint, :decision),
      evidence: value(checkpoint, :evidence) || [],
      next_action: value(checkpoint, :next_action),
      outcome: value(checkpoint, :outcome)
    }

    canonical
    |> Jason.encode!()
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end

  defp marker(fingerprint), do: "<!-- loophony-checkpoint:#{fingerprint} -->"

  defp format_comment(checkpoint, marker) do
    recorded_at = value(checkpoint, :recorded_at) || DateTime.utc_now() |> DateTime.to_iso8601()
    recorded_at_kst = korean_time(recorded_at)
    evidence = checkpoint |> value(:evidence) |> List.wrap() |> Enum.take(@max_evidence_items)

    evidence_text =
      case evidence do
        [] -> "- 기록된 증거 없음"
        items -> Enum.map_join(items, "\n", &"- #{truncate(&1, @max_evidence_characters)}")
      end

    """
    ## Loophony Checkpoint — #{recorded_at} UTC / #{recorded_at_kst} KST

    #{marker}
    - 기록 시각 (UTC): `#{recorded_at}`
    - 기록 시각 (KST): `#{recorded_at_kst}`
    - checkpoint: `#{inline(value(checkpoint, :checkpoint_key))}`
    - 단계: `#{inline(value(checkpoint, :phase))}`
    - 결과: `#{inline(value(checkpoint, :outcome))}`
    - 목표 정렬: `#{inline(value(checkpoint, :goal_alignment) || "미지정")}`
    - 세션 turn: `#{inline(value(checkpoint, :turn_number) || "미지정")}`

    ### 요약

    #{field(value(checkpoint, :summary))}

    ### 결정

    #{field(value(checkpoint, :decision))}

    ### 증거

    #{evidence_text}

    ### 다음 행동

    #{field(value(checkpoint, :next_action))}
    """
    |> String.trim()
  end

  defp value(map, key), do: Map.get(map, key) || Map.get(map, Atom.to_string(key))

  defp field(value), do: value |> to_string() |> truncate(@max_field_characters)

  defp inline(value) do
    value
    |> to_string()
    |> String.replace("`", "'")
    |> String.replace(~r/\s+/, " ")
    |> truncate(240)
  end

  defp truncate(value, max_characters) when is_binary(value) do
    if String.length(value) > max_characters do
      String.slice(value, 0, max_characters) <> "…"
    else
      value
    end
  end

  defp truncate(value, max_characters), do: value |> to_string() |> truncate(max_characters)

  defp korean_time(iso8601) when is_binary(iso8601) do
    case DateTime.from_iso8601(iso8601) do
      {:ok, datetime, _offset} -> format_korean_time(datetime)
      _ -> "파싱 불가"
    end
  end

  defp format_korean_time(datetime) do
    datetime
    |> DateTime.add(9, :hour)
    |> Calendar.strftime("%Y-%m-%dT%H:%M:%S+09:00")
  end
end
