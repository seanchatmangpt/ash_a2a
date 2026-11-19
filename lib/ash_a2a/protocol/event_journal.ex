# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshA2A.Protocol.EventJournal do
  @moduledoc """
  Behaviour for a durable, per-task event journal.

  `AshA2A.Protocol.TaskStore` keeps the latest task *snapshot*. A client that
  resubscribes on a fresh agent or a second node can therefore only be given
  that snapshot, not the status and artifact events it missed. An event
  journal records those events so a reattaching stream can replay them.

  A journal is addressed as `{module, ref}`, the same convention as
  `:task_store`. `ref` is opaque to callers (an ETS table name, an EKV
  instance name). Every callback takes `ref` first.

  ## Callbacks

    * `c:append/4` records one `event` (any term, usually a map) for a task
      at a task generation. It returns `:ok` only after the event has been
      read back from the journal; a silently dropped write is
      `{:error, :not_stored}`, never `:ok` (same discipline as
      `AshA2A.Cluster.Checkpoint.land/4`).
    * `c:replay_after/3` returns the events a subscriber that already holds
      task generation `generation` has not seen: every event whose
      generation is strictly greater, oldest first.
    * `c:trim/3` bounds growth by keeping only the most recent `keep_last`
      events of a task.

  ## Ordering

  Events order by generation, then by append order. `AshA2A.TaskStore.EventJournalEts`
  assigns a per-task, per-generation counter, so its order is exact.
  `AshA2A.TaskStore.EventJournalEkv` orders by wall-clock microseconds (ties
  broken by node and a local counter), so across nodes appending concurrently
  to the same task generation the order is wall-clock order, not causal order.

  ## Authority

  A journal is storage only. Holding a journal reference grants no authority
  to read a task: a caller that replays events must have passed the same
  owner check as for `tasks/get`.

  ## Writer

  With `config :ash_a2a, :event_journal, {module, ref}` set, every agent
  (`AshA2A.Protocol.Agent` and `AshA2A.Agent`) journals each task write whose
  generation advanced: one `messageUpdate`, `statusUpdate` or `artifactUpdate`
  `StreamResponse` map per mutation, at the task's generation after it
  (`AshA2A.Protocol.Task.Delta`). `tasks/resubscribe` with `lastSeenGeneration` replays
  them. A failed append never fails the task write: it is logged and emitted
  as `[:ash_a2a, :event_journal, :append_failed]`. When a task reaches a
  terminal state its journal is trimmed to the newest
  `config :ash_a2a, :event_journal_keep_last` events (default 256).

  See `docs/reference/event-journal.md`.
  """

  require Logger

  alias AshA2A.Protocol.Task.Generation

  @default_keep_last 256

  @type ref :: term()
  @type journal :: {module(), ref()}
  @type task_id :: String.t()
  @type generation :: non_neg_integer()
  @type event :: term()

  @doc "Appends `event`, returning `:ok` only after reading it back."
  @callback append(ref(), task_id(), generation(), event()) :: :ok | {:error, term()}

  @doc "Events with generation strictly greater than `generation`, oldest first."
  @callback replay_after(ref(), task_id(), generation()) :: {:ok, [event()]} | {:error, term()}

  @doc "Keeps only the newest `keep_last` events of the task."
  @callback trim(ref(), task_id(), keep_last :: non_neg_integer()) :: :ok | {:error, term()}

  @doc "The default journal implementation module (ETS)."
  @spec default_module() :: module()
  def default_module, do: AshA2A.TaskStore.EventJournalEts

  @doc "Appends through a `{module, ref}` journal."
  @spec append(journal(), task_id(), generation(), event()) :: :ok | {:error, term()}
  def append({mod, ref}, task_id, generation, event),
    do: mod.append(ref, task_id, generation, event)

  @doc "Replays through a `{module, ref}` journal."
  @spec replay_after(journal(), task_id(), generation()) :: {:ok, [event()]} | {:error, term()}
  def replay_after({mod, ref}, task_id, generation),
    do: mod.replay_after(ref, task_id, generation)

  @doc "Trims through a `{module, ref}` journal."
  @spec trim(journal(), task_id(), non_neg_integer()) :: :ok | {:error, term()}
  def trim({mod, ref}, task_id, keep_last), do: mod.trim(ref, task_id, keep_last)

  @doc """
  The journal configured by `config :ash_a2a, :event_journal, {module, ref}`,
  or `nil` when none is set.
  """
  @spec configured() :: journal() | nil
  def configured do
    case Application.get_env(:ash_a2a, :event_journal) do
      {mod, _ref} = journal when is_atom(mod) and not is_nil(mod) -> journal
      _ -> nil
    end
  end

  @doc """
  Journals the events of one task write.

  `previous` is the task as it was stored before the write (`nil` for a new
  task). One event is appended per mutation in between
  (`AshA2A.Protocol.Task.Delta.events/2`: `statusUpdate`, `artifactUpdate`,
  `messageUpdate`), each at the task's generation after it. Always returns
  `:ok`: an append or trim failure is logged and emitted as
  `[:ash_a2a, :event_journal, :append_failed]`, never raised.
  """
  @spec record_task(journal() | nil, AshA2A.Protocol.Task.t() | nil, AshA2A.Protocol.Task.t()) ::
          :ok
  def record_task(nil, _previous, _task), do: :ok

  def record_task({mod, _ref} = journal, previous, %AshA2A.Protocol.Task{} = task)
      when is_atom(mod) do
    generation = Generation.generation_of(task)

    guarded(task.id, generation, :append, fn ->
      previous
      |> AshA2A.Protocol.Task.Delta.events(task)
      |> Enum.reduce_while(:ok, fn {gen, event}, :ok ->
        case wire(event) do
          nil ->
            {:cont, :ok}

          wrapped ->
            case append(journal, task.id, gen, wrapped) do
              :ok -> {:cont, :ok}
              other -> {:halt, other}
            end
        end
      end)
    end)

    advanced? = is_nil(previous) or generation > Generation.generation_of(previous)

    # Trimmed on every advance, not only at the end: a long-running task
    # must not grow the journal without bound.
    if advanced? do
      guarded(task.id, generation, :trim, fn -> trim(journal, task.id, keep_last()) end)
    end

    :ok
  end

  def record_task(_journal, _previous, _task), do: :ok

  @doc "How many events a task keeps (`:event_journal_keep_last`, default 256)."
  @spec keep_last() :: non_neg_integer()
  def keep_last do
    case Application.get_env(:ash_a2a, :event_journal_keep_last, @default_keep_last) do
      n when is_integer(n) and n >= 0 -> n
      _ -> @default_keep_last
    end
  end

  defp wire(event) do
    case AshA2A.Protocol.JSON.encode_stream_response(event) do
      {:ok, wrapped} -> wrapped
      _ -> nil
    end
  end

  # The producer (an agent GenServer inside a task write) must survive any
  # journal failure: error tuple, raise, throw or exit.
  defp guarded(task_id, generation, op, fun) do
    case fun.() do
      :ok -> :ok
      other -> failed(task_id, generation, op, other)
    end
  rescue
    error -> failed(task_id, generation, op, {:raised, error})
  catch
    kind, value -> failed(task_id, generation, op, {kind, value})
  end

  defp failed(task_id, generation, op, reason) do
    Logger.warning(
      "ash_a2a event journal: #{op} failed for #{inspect(task_id)} " <>
        "at generation #{generation}: #{inspect(reason, limit: 5)}"
    )

    :telemetry.execute([:ash_a2a, :event_journal, :append_failed], %{count: 1}, %{
      task_id: task_id,
      generation: generation,
      operation: op
    })

    :ok
  end
end
