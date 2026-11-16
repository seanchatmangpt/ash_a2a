# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshA2A.TaskStore.EventJournalEkv do
  @moduledoc """
  On-disk, cluster-replicated `AshA2A.Protocol.EventJournal` backed by `EKV`.

  Share the `EKV` instance with `AshA2A.TaskStore.Ekv` (keys are under their
  own `a2a_event/` prefix) or start a separate one:

      children = [
        AshA2A.TaskStore.Ekv.child_spec(name: MyApp.Tasks, data_dir: "/var/lib/my_app/tasks")
      ]

      journal = {AshA2A.TaskStore.EventJournalEkv, MyApp.Tasks}

  ## Semantics

    * Each event is its own key, written insert-if-absent (`if_vsn: nil`), so
      concurrent appenders on different nodes never overwrite one another.
    * `append/4` reads the record back and returns `:ok` only if it matches;
      otherwise `{:error, :not_stored}`. EKV errors are returned as
      `{:error, reason}`, not raised and not swallowed.
    * Order is generation, then wall-clock microseconds, then node name, then a
      node-local counter. Across nodes appending to the same generation
      concurrently this is wall-clock order and clock skew can reorder it.
    * Replay is a prefix scan and reads the local replica (eventual): an event
      just appended on another node may not be visible yet.

  Status: compiled; see `test/ash_a2a/event_journal_ekv_test.exs`.
  """

  @behaviour AshA2A.Protocol.EventJournal

  @prefix "a2a_event/"

  @impl AshA2A.Protocol.EventJournal
  def append(name, task_id, generation, event)
      when is_binary(task_id) and is_integer(generation) and generation >= 0 do
    key = new_key(task_id, generation)
    record = %{task_id: task_id, generation: generation, event: event}

    case EKV.put(name, key, record, if_vsn: nil) do
      {:ok, _vsn} -> read_back(name, key, record, false)
      {:error, :unconfirmed} -> read_back(name, key, record, true)
      {:error, reason} -> {:error, reason}
      other -> {:error, {:unexpected, other}}
    end
  end

  @impl AshA2A.Protocol.EventJournal
  def replay_after(name, task_id, generation)
      when is_binary(task_id) and is_integer(generation) do
    events =
      name
      |> entries(task_id)
      |> Enum.filter(fn {_key, record, _vsn} -> record.generation > generation end)
      |> Enum.map(fn {_key, record, _vsn} -> record.event end)

    {:ok, events}
  rescue
    error -> {:error, error}
  end

  @impl AshA2A.Protocol.EventJournal
  def trim(name, task_id, keep_last)
      when is_binary(task_id) and is_integer(keep_last) and keep_last >= 0 do
    all = entries(name, task_id)
    drop = max(length(all) - keep_last, 0)

    all
    |> Enum.take(drop)
    |> Enum.reduce_while(:ok, fn {key, _record, vsn}, :ok ->
      # Keys are written in CAS mode (`if_vsn: nil`), so an eventual `EKV.delete/2`
      # is refused with `:cas_managed_key`; delete in CAS mode against the version read.
      case EKV.delete(name, key, if_vsn: vsn) do
        {:ok, _} -> {:cont, :ok}
        # Someone else already changed or removed it; trim is best-effort bounding.
        {:error, :conflict} -> {:cont, :ok}
        other -> {:halt, {:error, other}}
      end
    end)
  rescue
    error -> {:error, error}
  end

  defp read_back(name, key, record, consistent?) do
    stored =
      if consistent?, do: EKV.get(name, key, consistent: true), else: EKV.get(name, key)

    if stored == record, do: :ok, else: {:error, :not_stored}
  rescue
    error -> {:error, error}
  end

  # Sorted by key; keys embed zero-padded generation and timestamp.
  defp entries(name, task_id) do
    name
    |> EKV.scan(task_prefix(task_id))
    |> Enum.filter(fn {_key, value, _vsn} ->
      match?(%{task_id: ^task_id, generation: _}, value)
    end)
    |> Enum.sort_by(fn {key, _value, _vsn} -> key end)
  end

  # Task ids are base64url-encoded so an id containing "/" cannot collide with
  # another task's key prefix.
  defp task_prefix(task_id), do: @prefix <> Base.url_encode64(task_id, padding: false) <> "/"

  defp new_key(task_id, generation) do
    task_prefix(task_id) <>
      pad(generation, 20) <>
      "/" <>
      pad(System.os_time(:microsecond), 20) <>
      "-" <>
      Atom.to_string(node()) <>
      "-" <>
      pad(System.unique_integer([:positive, :monotonic]), 12)
  end

  defp pad(int, width), do: int |> Integer.to_string() |> String.pad_leading(width, "0")
end
