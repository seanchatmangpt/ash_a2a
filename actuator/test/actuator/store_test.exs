defmodule Actuator.StoreTest do
  @moduledoc """
  End-to-end courts on the real Store with a real state directory. The oracle is the ledger
  FILE, re-derived here with :crypto and Jason (independent of Actuator.Ledger).
  """
  use ExUnit.Case, async: true
  alias Actuator.{Kit, Store}

  @zero String.duplicate("0", 64)

  setup do
    Process.flag(:trap_exit, true)
    dir = Kit.tmp_dir("store")
    {:ok, pid} = Store.start_link(state_dir: dir)
    {:ok, dir: dir, store: pid}
  end

  # independent oracle
  defp ledger(dir) do
    path = Path.join(dir, "effect_ledger.jsonl")

    if File.exists?(path),
      do: path |> File.read!() |> String.split("\n", trim: true) |> Enum.map(&Jason.decode!/1),
      else: []
  end

  defp chain_ok?(entries) do
    entries
    |> Enum.with_index()
    |> Enum.reduce({true, @zero}, fn {e, i}, {ok, prev} ->
      {h, body} = Map.pop(e, "hash")
      calc = Base.encode16(:crypto.hash(:sha256, prev <> Jcs.encode(body)), case: :lower)
      {ok and e["seq"] == i and e["prev"] == prev and calc == h, h}
    end)
    |> elem(0)
  end

  defp exec(built, store),
    do: Actuator.execute(store, built.ctx, built.effect_bytes, built.cert_bytes)

  test "performs exactly one ledger_append into an append-only hash-chained ledger", %{
    dir: dir,
    store: s
  } do
    b = Kit.build(state_dir: dir)
    assert {:ok, %{status: :performed, evidence: ev}} = exec(b, s)
    assert ev["state"] == "completed" and ev["ledger_seq"] == 0

    [entry] = ledger(dir)
    assert entry["entry"] == "hello"
    assert entry["effect_instance_id"] == "ei:0001-abcdef"
    assert entry["hash"] == ev["ledger_hash"]
    assert chain_ok?([entry])
  end

  test "replay of the same certificate returns evidence and never performs again", %{
    dir: dir,
    store: s
  } do
    b = Kit.build(state_dir: dir)
    assert {:ok, %{status: :performed, evidence: ev}} = exec(b, s)
    for _ <- 1..3, do: assert({:ok, %{status: :replayed, evidence: ^ev}} = exec(b, s))
    assert length(ledger(dir)) == 1
  end

  test "second effect chains onto the first; noop_probe consumes the claim path but writes no ledger entry",
       %{dir: dir, store: s} do
    a = Kit.build(state_dir: dir)

    b =
      Kit.build(
        state_dir: dir,
        effect: %{"effect_instance_id" => "ei:0002-abcdef", "params" => %{"entry" => "second"}}
      )

    noop =
      Kit.build(
        state_dir: dir,
        effect: %{
          "effect_type" => "noop_probe",
          "capability" => "actuator.noop.probe",
          "consequence_class" => "none",
          "effect_instance_id" => "ei:0003-abcdef",
          "resource_bounds" => %{"max_bytes" => 0},
          "params" => %{}
        }
      )

    assert {:ok, %{status: :performed}} = exec(a, s)
    assert {:ok, %{status: :performed}} = exec(b, s)

    assert {:ok, %{status: :performed, evidence: %{"state" => "completed", "ledger_seq" => nil}}} =
             exec(noop, s)

    [e1, e2] = ledger(dir)
    assert e2["prev"] == e1["hash"] and chain_ok?([e1, e2])
  end

  test "a refused request leaves no claim and no ledger entry", %{dir: dir, store: s} do
    b = Kit.build(state_dir: dir, effect_after: %{"params" => %{"entry" => "swapped"}})
    assert {:error, 2, :effect_digest_mismatch} = exec(b, s)
    assert Store.snapshot(s) == %{}
    assert ledger(dir) == []
    assert File.read!(Path.join(dir, "journal.jsonl")) == ""
  end

  test "a (kid, nonce) pair bound to one instance cannot authorise another instance", %{
    dir: dir,
    store: s
  } do
    a = Kit.build(state_dir: dir, nonce_prefix: "shared")

    b =
      Kit.build(
        state_dir: dir,
        keys: a.keys,
        nonce_prefix: "shared",
        effect: %{"effect_instance_id" => "ei:0009-abcdef"}
      )

    assert {:ok, %{status: :performed}} = exec(a, s)
    assert {:error, 14, :nonce_replayed} = exec(b, s)
    assert length(ledger(dir)) == 1
  end

  test "generation must equal the actuator's view for a fresh instance", %{dir: dir, store: s} do
    b = Kit.build(state_dir: dir, ctx: [generations: %{"ei:0001-abcdef" => 5}])
    assert {:error, 16, :generation_stale} = exec(b, s)

    ok =
      Kit.build(
        state_dir: dir,
        cert: %{"generation" => 5},
        ctx: [generations: %{"ei:0001-abcdef" => 5}]
      )

    assert {:ok, %{status: :performed}} = exec(ok, s)
  end

  test "a completed instance presented with a different digest or generation is refused, not replayed",
       %{dir: dir, store: s} do
    a = Kit.build(state_dir: dir)
    assert {:ok, %{status: :performed}} = exec(a, s)
    diff = Kit.build(state_dir: dir, effect: %{"params" => %{"entry" => "different"}})
    assert {:error, 15, :effect_already_completed} = exec(diff, s)
    gen = Kit.build(state_dir: dir, cert: %{"generation" => 2})
    assert {:error, 15, :effect_already_completed} = exec(gen, s)
    assert length(ledger(dir)) == 1
  end

  test "state survives restart: completed stays completed and replays", %{dir: dir, store: s} do
    b = Kit.build(state_dir: dir)
    assert {:ok, %{status: :performed}} = exec(b, s)
    GenServer.stop(s)
    {:ok, s2} = Store.start_link(state_dir: dir)
    assert {:ok, %{status: :replayed}} = exec(b, s2)
    assert length(ledger(dir)) == 1
  end

  test "a tampered ledger refuses to boot (fail closed)", %{dir: dir, store: s} do
    assert {:ok, _} = exec(Kit.build(state_dir: dir), s)
    GenServer.stop(s)
    path = Path.join(dir, "effect_ledger.jsonl")
    File.write!(path, String.replace(File.read!(path), "hello", "HELLO"))

    assert {:error, {:store_boot_refused, {:broken_chain, 0, :hash}}} =
             Store.start_link(state_dir: dir)
  end

  test "a torn journal tail (crash mid-write) is discarded on boot", %{dir: dir, store: s} do
    assert {:ok, _} = exec(Kit.build(state_dir: dir), s)
    GenServer.stop(s)
    File.write!(Path.join(dir, "journal.jsonl"), "{\"t\":\"exec", [:append])
    {:ok, s2} = Store.start_link(state_dir: dir)
    assert {:ok, %{"state" => "completed"}} = Store.status(s2, "ei:0001-abcdef")
  end

  test "reconcile is refused unless the instance is unknown_outcome", %{dir: dir, store: s} do
    assert {:ok, _} = exec(Kit.build(state_dir: dir), s)

    assert {:error, :not_unknown_outcome} =
             Store.reconcile(s, "ei:0001-abcdef", :confirmed_performed, "n")

    assert {:error, :unknown_instance} =
             Store.reconcile(s, "ei:nope-nope-nope", :confirmed_performed, "n")
  end
end
