# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshA2A.A2ATransport.EventLog do
  @moduledoc """
  Pluggable persistence backend for `AshA2A.A2ATransport.TaskEvents`.

  `TaskEvents` always serves reads from its in-memory ETS log; the backend is
  a write-through journal that is replayed (`load_all/1`) when `TaskEvents`
  starts, so a durable backend restores the per-task seq/generation log across
  a real restart.

  Select a backend with the `:event_log` option of `TaskEvents`:

    * `nil` / `AshA2A.A2ATransport.EventLog.Ets` (default) -- no persistence,
      behaviour identical to before this seam existed;
    * `{AshA2A.A2ATransport.EventLog.Dets, dir: "/path"}` -- DETS file under
      `dir`, synced after every append;
    * `{module, opts}` -- any module implementing this behaviour.
  """

  @type handle :: term()
  @type row :: {String.t(), non_neg_integer(), String.t(), map(), boolean()}

  @callback open(opts :: keyword()) :: {:ok, handle()} | {:error, term()}
  @callback append(
              handle(),
              task_id :: String.t(),
              seq :: non_neg_integer(),
              kind :: String.t(),
              payload :: map(),
              final? :: boolean()
            ) :: :ok
  @callback delete(handle(), task_id :: String.t(), seq :: non_neg_integer()) :: :ok
  @callback delete_task(handle(), task_id :: String.t()) :: :ok
  @callback load_all(handle()) :: [row()]
  @callback close(handle()) :: :ok

  @doc false
  def normalize(nil), do: {AshA2A.A2ATransport.EventLog.Ets, []}
  def normalize(mod) when is_atom(mod), do: {mod, []}
  def normalize({mod, opts}) when is_atom(mod) and is_list(opts), do: {mod, opts}
end

defmodule AshA2A.A2ATransport.EventLog.Ets do
  @moduledoc "Default backend: no persistence (the hot ETS log in `TaskEvents` is the log)."
  @behaviour AshA2A.A2ATransport.EventLog

  @impl true
  def open(_opts), do: {:ok, nil}
  @impl true
  def append(_h, _task_id, _seq, _kind, _payload, _final?), do: :ok
  @impl true
  def delete(_h, _task_id, _seq), do: :ok
  @impl true
  def delete_task(_h, _task_id), do: :ok
  @impl true
  def load_all(_h), do: []
  @impl true
  def close(_h), do: :ok
end

defmodule AshA2A.A2ATransport.EventLog.Dets do
  @moduledoc """
  Durable backend: one DETS file (`events.dets`) under `:dir`.

  Options: `:dir` (required), `:file` (default `"events.dets"`). The table is
  owned by the `TaskEvents` process and is synced after every append, so an
  acknowledged publish survives a process stop.
  """
  @behaviour AshA2A.A2ATransport.EventLog

  @impl true
  def open(opts) do
    dir = Keyword.fetch!(opts, :dir)
    File.mkdir_p!(dir)
    file = dir |> Path.join(Keyword.get(opts, :file, "events.dets")) |> String.to_charlist()
    name = :"ash_a2a_event_log_#{:erlang.unique_integer([:positive])}"
    :dets.open_file(name, file: file, type: :set)
  end

  @impl true
  def append(h, task_id, seq, kind, payload, final?) do
    :ok = :dets.insert(h, {{task_id, seq}, kind, payload, final?})
    :ok = :dets.sync(h)
  end

  @impl true
  def delete(h, task_id, seq) do
    :ok = :dets.delete(h, {task_id, seq})
    :ok = :dets.sync(h)
  end

  @impl true
  def delete_task(h, task_id) do
    :dets.match_delete(h, {{task_id, :_}, :_, :_, :_})
    :ok = :dets.sync(h)
  end

  @impl true
  def load_all(h) do
    for {{task_id, seq}, kind, payload, final?} <- :dets.match_object(h, :_) do
      {task_id, seq, kind, payload, final?}
    end
    |> Enum.sort()
  end

  @impl true
  def close(h) do
    :dets.close(h)
    :ok
  end
end
