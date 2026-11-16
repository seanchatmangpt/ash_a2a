# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshA2A.EventJournalEtsTest do
  @moduledoc """
  `AshA2A.TaskStore.EventJournalEts` against a real, supervised ETS table.
  Status: UNVERIFIED (not run; no Elixir toolchain when written). No mocks.
  """
  use ExUnit.Case, async: true

  alias AshA2A.Protocol.EventJournal
  alias AshA2A.TaskStore.EventJournalEts

  setup do
    name = :"ash_a2a_event_journal_ets_test_#{System.unique_integer([:positive])}"
    start_supervised!({EventJournalEts, name: name})
    %{name: name, journal: {EventJournalEts, name}}
  end

  test "default module is the ETS journal" do
    assert EventJournal.default_module() == EventJournalEts
  end

  test "append then replay returns events in order, per task", %{journal: j} do
    for n <- 1..5, do: assert(:ok = EventJournal.append(j, "t-1", 1, %{n: n}))
    assert :ok = EventJournal.append(j, "t-2", 1, %{other: true})

    assert {:ok, events} = EventJournal.replay_after(j, "t-1", 0)
    assert events == Enum.map(1..5, &%{n: &1})
    assert {:ok, [%{other: true}]} = EventJournal.replay_after(j, "t-2", 0)
    assert {:ok, []} = EventJournal.replay_after(j, "unknown", 0)
  end

  test "replay_after returns only events of a strictly greater generation", %{journal: j} do
    :ok = EventJournal.append(j, "t", 1, :g1)
    :ok = EventJournal.append(j, "t", 2, :g2a)
    :ok = EventJournal.append(j, "t", 2, :g2b)
    :ok = EventJournal.append(j, "t", 3, :g3)

    assert {:ok, [:g1, :g2a, :g2b, :g3]} = EventJournal.replay_after(j, "t", 0)
    assert {:ok, [:g2a, :g2b, :g3]} = EventJournal.replay_after(j, "t", 1)
    assert {:ok, [:g3]} = EventJournal.replay_after(j, "t", 2)
    assert {:ok, []} = EventJournal.replay_after(j, "t", 3)
  end

  test "trim keeps only the newest keep_last events", %{journal: j} do
    for n <- 1..6, do: :ok = EventJournal.append(j, "t", div(n, 4), n)
    :ok = EventJournal.append(j, "other", 0, :untouched)

    assert :ok = EventJournal.trim(j, "t", 2)
    assert {:ok, [5, 6]} = EventJournal.replay_after(j, "t", -1)
    assert {:ok, [:untouched]} = EventJournal.replay_after(j, "other", -1)

    assert :ok = EventJournal.trim(j, "t", 0)
    assert {:ok, []} = EventJournal.replay_after(j, "t", -1)
  end

  test "concurrent appends to one task are all stored, none overwritten", %{journal: j} do
    results =
      1..50
      |> Task.async_stream(fn n -> EventJournal.append(j, "t", 1, {:evt, n}) end,
        max_concurrency: 25
      )
      |> Enum.map(fn {:ok, r} -> r end)

    assert Enum.all?(results, &(&1 == :ok))
    assert {:ok, events} = EventJournal.replay_after(j, "t", 0)
    assert events |> Enum.sort() == Enum.map(1..50, &{:evt, &1})
  end

  test "a missing journal table is an error, never :ok" do
    gone = {EventJournalEts, :ash_a2a_event_journal_never_started}

    assert {:error, :journal_unavailable} = EventJournal.append(gone, "t", 1, :e)
    assert {:error, :journal_unavailable} = EventJournal.replay_after(gone, "t", 0)
    assert {:error, :journal_unavailable} = EventJournal.trim(gone, "t", 1)
  end
end
