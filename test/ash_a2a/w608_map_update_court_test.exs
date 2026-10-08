defmodule AshA2A.W608MapUpdateCourtTest do
  @moduledoc """
  Lane W608 (v26.10.7, WP-4 / OS-20) Map.update sweep court.

  Parameterized deterministic insertion across populated and empty baselines,
  run twice, over real Map.update-family insertion sites in real modules.

  The W606 rubric splits sites into class (a) absent-key-critical (patched to
  an explicit branch) and class (b) default-intended (left, disclosed). This
  court pins the observable contract of both shapes:

    * a class-(b) accumulator `Map.update(acc, k, default, fun)` must insert
      the default verbatim on an absent key (the fun is NOT applied to the
      default); every class-(b) accumulator site in lib/ is idempotent-fun
      (fun(default) == default), so its result is identical under either
      Map.update/4 absent-key semantics the OS-20 hazard names;
    * a dual-safe explicit-branch site (Protocol.Agent.State.track_context/2)
      must insert the default unmodified on the first insert and prepend
      exactly once per insert thereafter.

  No mocks: real ETS (AllocationCounters), a real Agent (MemoryClaimStore),
  and a pure struct (Protocol.Agent.State).
  """

  use ExUnit.Case, async: true

  alias AshA2A.C2.MemoryClaimStore
  alias AshA2A.Protocol.Agent.State
  alias AshA2A.Telemetry.AllocationCounters

  @sites [:allocation_counters, :agent_state_track_context, :claim_store]

  test "deterministic insertion across empty and populated baselines, x2 runs" do
    for run <- [1, 2] do
      for site <- @sites do
        key = "w608-#{run}-#{site}"

        empty = insert(site, key)
        assert empty == expected(site, key, :empty),
               "site #{site} run #{run}: empty-baseline diverged: #{inspect(empty)}"

        populated = insert_populated(site, key)
        assert populated == expected(site, key, :populated),
               "site #{site} run #{run}: populated-baseline diverged: #{inspect(populated)}"
      end
    end
  end

  test "absent-key default stored verbatim (no fun application), x2 runs" do
    for run <- [1, 2] do
      tid = AllocationCounters.new()
      handler = AllocationCounters.attach!(tid, make_ref(), owner: self())

      try do
        emit_allocation("w608-verbatim-#{run}", :llm)
        assert AllocationCounters.counts(tid) == %{"w608-verbatim-#{run}" => %{llm: 1}}

        emit_allocation("w608-verbatim-#{run}", :llm)
        assert AllocationCounters.counts(tid) == %{"w608-verbatim-#{run}" => %{llm: 2}}
      after
        AllocationCounters.detach(handler)
      end
    end
  end

  # --- parameterized site drivers ------------------------------------------

  defp insert(:allocation_counters, key) do
    tid = AllocationCounters.new()
    handler = AllocationCounters.attach!(tid, make_ref(), owner: self())
    emit_allocation(key, :llm)
    counts = AllocationCounters.counts(tid)
    AllocationCounters.detach(handler)
    counts
  end

  defp insert_populated(:allocation_counters, key) do
    tid = AllocationCounters.new()
    handler = AllocationCounters.attach!(tid, make_ref(), owner: self())
    emit_allocation(key, :machinery)
    emit_allocation(key, :llm)
    counts = AllocationCounters.counts(tid)
    AllocationCounters.detach(handler)
    counts
  end

  defp insert(:agent_state_track_context, key) do
    %State{}
    |> State.track_context(%{context_id: key, id: "task-first"})
    |> Map.get(:contexts)
  end

  defp insert_populated(:agent_state_track_context, key) do
    %State{}
    |> State.track_context(%{context_id: key, id: "task-prior"})
    |> State.track_context(%{context_id: key, id: "task-new"})
    |> Map.get(:contexts)
  end

  defp insert(:claim_store, key) do
    ensure_claim_store()
    MemoryClaimStore.complete(key, {:approved, :w608})
    Agent.get(MemoryClaimStore, &Map.get(&1, key))
  end

  defp insert_populated(:claim_store, key) do
    ensure_claim_store()
    claim_key = "#{key}-prior"
    :ok = MemoryClaimStore.claim(claim_key, "g-prior")
    MemoryClaimStore.complete(claim_key, {:approved, :w608})
    Agent.get(MemoryClaimStore, &Map.get(&1, claim_key))
  end

  # --- exact expected results -----------------------------------------------

  defp expected(:allocation_counters, key, :empty), do: %{key => %{llm: 1}}

  defp expected(:allocation_counters, key, :populated),
    do: %{key => %{machinery: 1, llm: 1}}

  defp expected(:agent_state_track_context, key, :empty),
    do: %{key => ["task-first"]}

  defp expected(:agent_state_track_context, key, :populated),
    do: %{key => ["task-new", "task-prior"]}

  defp expected(:claim_store, _key, :empty),
    do: {0, {:completed, {:approved, :w608}}}

  defp expected(:claim_store, _key, :populated),
    do: {"g-prior", {:completed, {:approved, :w608}}}

  # --- helpers ---------------------------------------------------------------

  defp emit_allocation(class, resolver) do
    :telemetry.execute([:ash_a2a, :semantic, :allocation], %{}, %{
      class: class,
      resolver: resolver
    })
  end

  defp ensure_claim_store do
    case MemoryClaimStore.start_link() do
      {:ok, _pid} -> :ok
      {:error, {:already_started, _pid}} -> :ok
    end
  end
end
