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

  Status: UNVERIFIED (no Elixir toolchain was available when this was
  written). See `docs/reference/event-journal.md`.
  """

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
  def append({mod, ref}, task_id, generation, event), do: mod.append(ref, task_id, generation, event)

  @doc "Replays through a `{module, ref}` journal."
  @spec replay_after(journal(), task_id(), generation()) :: {:ok, [event()]} | {:error, term()}
  def replay_after({mod, ref}, task_id, generation), do: mod.replay_after(ref, task_id, generation)

  @doc "Trims through a `{module, ref}` journal."
  @spec trim(journal(), task_id(), non_neg_integer()) :: :ok | {:error, term()}
  def trim({mod, ref}, task_id, keep_last), do: mod.trim(ref, task_id, keep_last)
end
