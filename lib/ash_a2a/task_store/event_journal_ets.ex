# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshA2A.TaskStore.EventJournalEts do
  @moduledoc """
  In-memory `AshA2A.Protocol.EventJournal` backed by a named ETS table.

  The default journal. It survives an agent crash (the table is owned by its
  own supervised process) but not a node restart; use
  `AshA2A.TaskStore.EventJournalEkv` for that.

  ## Wiring

      children = [
        {AshA2A.TaskStore.EventJournalEts, name: MyApp.EventJournal}
      ]

      journal = {AshA2A.TaskStore.EventJournalEts, MyApp.EventJournal}

  Within one task and generation the order is exact (an atomic counter).
  Status: UNVERIFIED (not compiled or run).
  """

  @behaviour AshA2A.Protocol.EventJournal

  @doc "Child spec; requires `:name` (the table name, also the journal ref)."
  @spec child_spec(keyword()) :: Supervisor.child_spec()
  def child_spec(opts) do
    name = Keyword.get(opts, :name) || raise ArgumentError, "#{inspect(__MODULE__)} requires :name"

    %{
      id: {__MODULE__, name},
      start: {__MODULE__, :start_link, [opts]},
      type: :worker
    }
  end

  @doc false
  def start_link(opts) do
    name = Keyword.fetch!(opts, :name)

    Agent.start_link(fn ->
      :ets.new(name, [:ordered_set, :public, :named_table, read_concurrency: true])
      name
    end)
  end

  @impl AshA2A.Protocol.EventJournal
  def append(table, task_id, generation, event)
      when is_binary(task_id) and is_integer(generation) and generation >= 0 do
    seq = :ets.update_counter(table, {:counter, task_id, generation}, 1, {{:counter, task_id, generation}, 0})
    key = {task_id, generation, seq}
    true = :ets.insert(table, {key, event})

    case :ets.lookup(table, key) do
      [{^key, ^event}] -> :ok
      _ -> {:error, :not_stored}
    end
  rescue
    ArgumentError -> {:error, :journal_unavailable}
  end

  @impl AshA2A.Protocol.EventJournal
  def replay_after(table, task_id, generation)
      when is_binary(task_id) and is_integer(generation) do
    entries =
      :ets.select(table, [
        {{{task_id, :"$1", :"$2"}, :"$3"}, [{:>, :"$1", generation}], [:"$3"]}
      ])

    {:ok, entries}
  rescue
    ArgumentError -> {:error, :journal_unavailable}
  end

  @impl AshA2A.Protocol.EventJournal
  def trim(table, task_id, keep_last)
      when is_binary(task_id) and is_integer(keep_last) and keep_last >= 0 do
    keys = :ets.select(table, [{{{task_id, :"$1", :"$2"}, :_}, [], [{{task_id, :"$1", :"$2"}}]}])
    drop = max(length(keys) - keep_last, 0)

    keys |> Enum.take(drop) |> Enum.each(&:ets.delete(table, &1))
    :ok
  rescue
    ArgumentError -> {:error, :journal_unavailable}
  end
end
