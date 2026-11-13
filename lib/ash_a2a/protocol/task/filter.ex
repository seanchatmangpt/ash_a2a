defmodule AshA2A.Protocol.Task.Filter do
  @moduledoc false

  @doc """
  Filters, paginates, and transforms a list of tasks.

  Tasks are sorted by `status.timestamp` descending, then filtered by the
  given options. Pagination uses task IDs as opaque cursor tokens.

  ## Options

  - `:context_id` — keep only tasks with this context ID
  - `:status` — keep only tasks in this state (atom)
  - `:status_timestamp_after` — keep only tasks updated after this DateTime
  - `:page_size` — max tasks per page (default 50)
  - `:page_token` — task ID to start after. If that task no longer exists
    (deleted between pages, or filtered out) the result is
    `{:error, :invalid_page_token}` -- never a silent restart from page one.
  - `:history_length` — truncate history (default 0 = clear)
  - `:timeline_length` — truncate timeline (nil = keep all, 0 = none, N = last N)
  - `:include_artifacts` — keep artifacts (default false)
  """
  @spec apply([AshA2A.Protocol.Task.t()], keyword()) ::
          {:ok, map()} | {:error, :invalid_page_token}
  def apply(tasks, opts \\ []) do
    context_id = Keyword.get(opts, :context_id)
    status = Keyword.get(opts, :status)
    timestamp_after = Keyword.get(opts, :status_timestamp_after)
    page_size = Keyword.get(opts, :page_size, 50)
    page_token = Keyword.get(opts, :page_token)
    history_length = Keyword.get(opts, :history_length, 0)
    include_artifacts = Keyword.get(opts, :include_artifacts, false)
    # ListTasksRequest.timeline_length: nil (unset) keeps the whole timeline.
    timeline_length = Keyword.get(opts, :timeline_length)

    filtered =
      tasks
      |> Enum.sort_by(&sort_key/1, :desc)
      |> maybe_filter(&(&1.context_id == context_id), context_id)
      |> maybe_filter(&(status_state(&1) == status), status)
      |> maybe_filter_timestamp(timestamp_after)

    total_size = length(filtered)

    case paginate(filtered, page_token) do
      {:error, _} = err ->
        err

      {:ok, remaining} ->
        page = Enum.take(remaining, page_size)

        next_token =
          if length(remaining) > page_size do
            page |> List.last() |> encode_cursor()
          else
            ""
          end

        tasks =
          Enum.map(page, fn task ->
            task
            |> AshA2A.Protocol.Task.truncate_history(history_length)
            |> AshA2A.Protocol.Task.Generation.truncate_timeline(timeline_length)
            |> maybe_strip_artifacts(include_artifacts)
          end)

        {:ok,
         %{
           tasks: tasks,
           total_size: total_size,
           page_size: page_size,
           next_page_token: next_token
         }}
    end
  end

  # Deterministic total order: status timestamp descending, then id descending
  # as the tie-breaker. A nil status or timestamp sorts last (epoch 0).
  defp sort_key(task), do: {timestamp_us(task), task.id || ""}

  defp timestamp_us(%{status: %{timestamp: %DateTime{} = ts}}),
    do: DateTime.to_unix(ts, :microsecond)

  defp timestamp_us(_task), do: 0

  defp status_state(%{status: %{state: state}}), do: state
  defp status_state(_task), do: nil

  defp maybe_filter(tasks, _fun, nil), do: tasks
  defp maybe_filter(tasks, fun, _val), do: Enum.filter(tasks, fun)

  defp maybe_filter_timestamp(tasks, nil), do: tasks

  defp maybe_filter_timestamp(tasks, after_dt) do
    Enum.filter(tasks, fn task ->
      case task do
        %{status: %{timestamp: %DateTime{} = ts}} -> DateTime.compare(ts, after_dt) in [:gt, :eq]
        _ -> false
      end
    end)
  end

  defp paginate(tasks, nil), do: {:ok, tasks}
  defp paginate(tasks, ""), do: {:ok, tasks}

  # Opaque cursor: url-safe base64 of "<timestamp_us>:<id>". Resumes strictly
  # after that sort key, so it stays valid when the cursor task itself was
  # filtered out or deleted between pages. A legacy raw task-id token is still
  # honoured when that task is present.
  defp paginate(tasks, token) when is_binary(token) do
    case decode_cursor(token) do
      {:ok, key} ->
        {:ok, Enum.filter(tasks, &(sort_key(&1) < key))}

      :error ->
        case Enum.split_while(tasks, &(&1.id != token)) do
          {_before, [_match | rest]} -> {:ok, rest}
          {_, []} -> {:error, :invalid_page_token}
        end
    end
  end

  defp paginate(_tasks, _token), do: {:error, :invalid_page_token}

  defp encode_cursor(task) do
    {ts, id} = sort_key(task)
    Base.url_encode64("#{ts}:#{id}", padding: false)
  end

  defp decode_cursor(token) do
    with {:ok, raw} <- Base.url_decode64(token, padding: false),
         [ts, id] when id != "" <- String.split(raw, ":", parts: 2),
         {ts_int, ""} <- Integer.parse(ts) do
      {:ok, {ts_int, id}}
    else
      _ -> :error
    end
  end

  defp maybe_strip_artifacts(task, true), do: task
  defp maybe_strip_artifacts(task, _), do: %{task | artifacts: []}
end
