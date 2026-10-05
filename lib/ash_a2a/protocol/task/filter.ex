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
  - `:page_token` — task ID to start after
  - `:history_length` — truncate history (default 0 = clear)
  - `:include_artifacts` — keep artifacts (default false)
  """
  @spec apply([AshA2A.Protocol.Task.t()], keyword()) :: {:ok, map()} | {:error, :invalid_page_token}
  def apply(tasks, opts \\ []) do
    context_id = Keyword.get(opts, :context_id)
    status = Keyword.get(opts, :status)
    timestamp_after = Keyword.get(opts, :status_timestamp_after)
    page_size = Keyword.get(opts, :page_size, 50)
    page_token = Keyword.get(opts, :page_token)
    history_length = Keyword.get(opts, :history_length, 0)
    include_artifacts = Keyword.get(opts, :include_artifacts, false)

    filtered =
      tasks
      |> Enum.sort_by(& &1.status.timestamp, {:desc, DateTime})
      |> maybe_filter(&(&1.context_id == context_id), context_id)
      |> maybe_filter(&(&1.status.state == status), status)
      |> maybe_filter_timestamp(timestamp_after)

    total_size = length(filtered)

    case paginate(filtered, page_token) do
      {:error, _} = err ->
        err

      {:ok, remaining} ->
        page = Enum.take(remaining, page_size)

        next_token =
          if length(remaining) > page_size do
            page |> List.last() |> Map.get(:id)
          else
            ""
          end

        tasks =
          Enum.map(page, fn task ->
            task
            |> AshA2A.Protocol.Task.truncate_history(history_length)
            |> maybe_strip_artifacts(include_artifacts)
          end)

        {:ok,
         %{
           tasks: tasks,
           total_size: total_size,
           page_size: length(tasks),
           next_page_token: next_token
         }}
    end
  end

  defp maybe_filter(tasks, _fun, nil), do: tasks
  defp maybe_filter(tasks, fun, _val), do: Enum.filter(tasks, fun)

  defp maybe_filter_timestamp(tasks, nil), do: tasks

  defp maybe_filter_timestamp(tasks, after_dt) do
    Enum.filter(tasks, fn task ->
      task.status.timestamp != nil and
        DateTime.compare(task.status.timestamp, after_dt) == :gt
    end)
  end

  defp paginate(tasks, nil), do: {:ok, tasks}
  defp paginate(tasks, ""), do: {:ok, tasks}

  defp paginate(tasks, token) do
    case Enum.split_while(tasks, &(&1.id != token)) do
      {_before, [_match | rest]} -> {:ok, rest}
      {_, []} -> {:error, :invalid_page_token}
    end
  end

  defp maybe_strip_artifacts(task, true), do: task
  defp maybe_strip_artifacts(task, _), do: %{task | artifacts: []}
end
