# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshA2A.FuzzTaskStoreTest do
  # Seeded fuzz of the TaskStore read paths (ETS and Ekv) over corrupted stored
  # terms, and of EventJournal.replay_after/3 with out-of-order generations.
  use ExUnit.Case, async: true

  alias AshA2A.FuzzGen
  alias AshA2A.Protocol.{EventJournal, Task}
  alias AshA2A.Protocol.TaskStore.ETS

  @iterations FuzzGen.iterations(300)

  setup do
    id = System.unique_integer([:positive])
    ets = :"fuzz_ts_ets_#{id}"
    {:ok, pid} = ETS.start_link(name: ets)
    ekv = :"fuzz_ts_ekv_#{id}"
    dir = Path.join(System.tmp_dir!(), "fuzz_ts_ekv_#{id}")
    File.rm_rf!(dir)

    start_supervised!(
      Supervisor.child_spec(AshA2A.TaskStore.Ekv.child_spec(name: ekv, data_dir: dir),
        id: {:fuzz_ekv, ekv}
      )
    )

    on_exit(fn ->
      AshA2A.TestSupport.SafeStop.stop(pid)
      File.rm_rf!(dir)
    end)

    %{
      stores: [
        {ETS, ets, fn key, value -> :ets.insert(ets, {key, value}) end},
        {AshA2A.TaskStore.Ekv, ekv,
         fn key, value -> :ok = EKV.put(ekv, "a2a_task/" <> key, value) end}
      ],
      ekv: ekv
    }
  end

  defp good_task(i),
    do: %Task{
      id: "good-#{i}",
      context_id: "ctx",
      status: %{state: :completed, timestamp: "2026-01-01T00:00:00Z"}
    }

  defp garbage do
    FuzzGen.pick([
      nil,
      :atom,
      5,
      "binary",
      {:tuple, 1},
      [1, 2],
      %{},
      %{context_id: "ctx"},
      %{id: "x", __struct__: String},
      %Task{id: "bad", context_id: "ctx", status: FuzzGen.wrong_value()},
      %Task{id: "bad2", context_id: FuzzGen.wrong_value(), status: nil, history: 5},
      %Task{id: "bad3", context_id: "ctx", status: nil, generation: FuzzGen.wrong_value()},
      %Task{id: "bad4", context_id: "ctx", status: %{state: FuzzGen.wrong_value(), timestamp: 3}}
    ])
  end

  defp total?(result) do
    match?({:ok, _}, result) or match?({:error, _}, result)
  end

  test "get/list/list_all over corrupted rows never raise", %{stores: stores} do
    FuzzGen.seed(1601)

    for {mod, ref, put_raw} <- stores do
      put_raw.("good-0", good_task(0))

      for i <- 1..@iterations do
        put_raw.("row-#{i}", garbage())
      end

      for i <- 1..@iterations do
        for call <- [
              fn -> mod.get(ref, "row-#{i}") end,
              fn -> mod.get(ref, "good-0") end,
              fn -> mod.get(ref, "absent") end
            ] do
          assert FuzzGen.run_with_deadline(call) |> case do
                   {:ok, r} -> total?(r)
                   other -> flunk("#{inspect(mod)} get row-#{i}: #{inspect(other)}")
                 end
        end
      end

      for call <- [
            fn -> mod.list(ref, "ctx") end,
            fn -> mod.list_all(ref, []) end,
            fn -> mod.list_all(ref, page_size: 3, context_id: "ctx") end,
            fn -> mod.list_all(ref, status: :completed, include_artifacts: true) end
          ] do
        case FuzzGen.run_with_deadline(call) do
          {:ok, r} -> assert total?(r), "#{inspect(mod)}: #{inspect(r, limit: 5)}"
          other -> flunk("#{inspect(mod)} list: #{inspect(other, limit: 5)}")
        end
      end
    end
  end

  test "a row that is not a Task is not found by get/2 and absent from listings", %{
    stores: stores
  } do
    for {mod, ref, put_raw} <- stores do
      put_raw.("good-1", good_task(1))
      put_raw.("junk", {:not, :a_task})
      assert {:error, :not_found} = mod.get(ref, "junk")
      assert {:ok, [%Task{id: "good-1"}]} = mod.list(ref, "ctx")
      assert {:ok, %{tasks: [%Task{id: "good-1"}]}} = mod.list_all(ref, [])
    end
  end

  defp journals(%{ekv: ekv}) do
    id = System.unique_integer([:positive])
    ets = :"fuzz_ej_ets_#{id}"
    start_supervised!({AshA2A.TaskStore.EventJournalEts, name: ets}, id: {:fuzz_ej, ets})

    [
      {AshA2A.TaskStore.EventJournalEts, ets},
      {AshA2A.TaskStore.EventJournalEkv, ekv}
    ]
  end

  test "replay_after returns events strictly newer than the generation, oldest first", ctx do
    FuzzGen.seed(1602)

    for {mod, ref} <- journals(ctx) do
      for round <- 1..20 do
        task = "t-#{inspect(mod)}-#{round}"
        gens = for _ <- 1..(1 + FuzzGen.int(25)), do: FuzzGen.int(10)

        for {g, n} <- Enum.with_index(gens) do
          assert :ok = EventJournal.append({mod, ref}, task, g, {g, n})
        end

        for after_gen <- -1..10 do
          assert {:ok, events} = EventJournal.replay_after({mod, ref}, task, after_gen)
          got_gens = Enum.map(events, &elem(&1, 0))
          assert got_gens == Enum.sort(got_gens), "not ordered by generation: #{inspect(events)}"
          assert Enum.all?(got_gens, &(&1 > after_gen))

          expect = Enum.count(gens, &(&1 > after_gen))
          assert length(events) == expect
        end
      end
    end
  end

  test "replay_after tolerates corrupt journal rows and hostile arguments", ctx do
    FuzzGen.seed(1603)
    [{ets_mod, ets}, {ekv_mod, ekv}] = journals(ctx)
    :ok = EventJournal.append({ets_mod, ets}, "t", 3, :ok)
    :ets.insert(ets, {{"t", :bad, 1}, :junk})
    :ets.insert(ets, {:weird, :row})
    :ok = EKV.put(ekv, "a2a_event/" <> Base.url_encode64("t", padding: false) <> "/zzz", %{task_id: "t", generation: :bad, event: 1})
    :ok = EKV.put(ekv, "a2a_event/" <> Base.url_encode64("t", padding: false) <> "/yyy", :junk)

    for {mod, ref} <- [{ets_mod, ets}, {ekv_mod, ekv}], _ <- 1..@iterations do
      args = [
        FuzzGen.pick(["t", "", "absent", FuzzGen.evil_string()]),
        FuzzGen.pick([-1, 0, 3, 99, FuzzGen.huge_int(), -FuzzGen.huge_int()])
      ]

      case FuzzGen.run_with_deadline(fn -> apply(EventJournal, :replay_after, [{mod, ref} | args]) end) do
        {:ok, {:ok, l}} when is_list(l) -> :ok
        {:ok, {:error, _}} -> :ok
        other -> flunk("#{inspect(mod)} #{inspect(args)}: #{inspect(other)}")
      end
    end
  end
end
