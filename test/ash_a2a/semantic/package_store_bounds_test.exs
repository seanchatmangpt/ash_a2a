defmodule AshA2A.Semantic.PackageStoreBoundsTest do
  @moduledoc """
  SEC-09 court: `AshA2A.Semantic.PackageStore` is bounded (FIFO eviction at
  `:max_entries`, per-entry TTL). Real, uniquely named GenServer per test;
  real `ExecutionPackage` structs.
  """
  use ExUnit.Case, async: true

  alias AshA2A.Semantic.{ExecutionPackage, PackageStore}

  defp start_store(opts) do
    name = :"#{__MODULE__}.#{System.unique_integer([:positive])}"
    start_supervised!({PackageStore, Keyword.put(opts, :name, name)})
    [name: name]
  end

  # Only the fingerprint is load-bearing for the store's keying; the other
  # enforced keys are carried as nil (the store never inspects them).
  defp package(fp) do
    %ExecutionPackage{
      fingerprint: fp,
      source: nil,
      semantic_ir: nil,
      ontology: nil,
      planning_ir: nil,
      plan_candidate: nil
    }
  end

  test "evicts the oldest entry once max_entries is exceeded" do
    store = start_store(max_entries: 2, ttl_ms: 60_000)

    for fp <- ["a", "b", "c"], do: :ok = PackageStore.put(package(fp), store)

    assert PackageStore.size(store) == 2
    assert PackageStore.fetch("a", store) == :error
    assert {:ok, %ExecutionPackage{fingerprint: "b"}} = PackageStore.fetch("b", store)
    assert {:ok, %ExecutionPackage{fingerprint: "c"}} = PackageStore.fetch("c", store)
  end

  test "re-putting a fingerprint refreshes its FIFO position" do
    store = start_store(max_entries: 2, ttl_ms: 60_000)

    :ok = PackageStore.put(package("a"), store)
    :ok = PackageStore.put(package("b"), store)
    :ok = PackageStore.put(package("a"), store)
    :ok = PackageStore.put(package("c"), store)

    assert PackageStore.fetch("b", store) == :error
    assert {:ok, _} = PackageStore.fetch("a", store)
    assert PackageStore.size(store) == 2
  end

  test "an entry past its TTL fetches as :error and is removed" do
    store = start_store(max_entries: 10, ttl_ms: 1)

    :ok = PackageStore.put(package("ephemeral"), store)
    Process.sleep(5)

    assert PackageStore.fetch("ephemeral", store) == :error
    assert PackageStore.size(store) == 0
  end

  test "malformed bounds fall back to the bounded defaults instead of disabling eviction" do
    store = start_store(max_entries: "2", ttl_ms: "soon")
    %{max_entries: max, ttl_ms: ttl} = :sys.get_state(store[:name])
    assert max == 10_000
    assert ttl == :timer.hours(1)
    :ok = PackageStore.put(package("x"), store)
    assert {:ok, _} = PackageStore.fetch("x", store)
  end

  test "defaults are bounded" do
    store = start_store([])
    %{max_entries: max, ttl_ms: ttl} = :sys.get_state(store[:name])
    assert max == 10_000
    assert ttl == :timer.hours(1)
  end
end
