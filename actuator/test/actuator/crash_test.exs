defmodule Actuator.CrashTest do
  @moduledoc """
  Crash court with a REAL OS process: a child `mix run` executes the effect against a real
  state directory and the Store halts the VM (exit 137) at a named point. The parent then
  restarts the Store on the same directory and asserts final state only:
  unknown_outcome, ledger effect count (the file oracle), replay = evidence, no retry, and
  reconcile as the only exit. The crash points are compiled in only under the test env.
  """
  use ExUnit.Case, async: false
  alias Actuator.{Config, Kit, Store}

  @moduletag :crash
  @id "ei:crash-0001"

  setup do
    Process.flag(:trap_exit, true)
    dir = Kit.tmp_dir("crash")
    now = System.os_time(:second)
    built = Kit.build(state_dir: dir, now: now, effect: %{"effect_instance_id" => @id})

    registry =
      for r <- built.records do
        %{
          "kid" => r.kid,
          "alg" => r.alg,
          "public_key" => Base.url_encode64(r.public_key, padding: false),
          "custodian_id" => r.custodian_id,
          "custody_tier" => "i2",
          "state" => "active",
          "revocation_epoch" => 7
        }
      end

    config = Path.join(dir, "config.json")

    File.write!(
      config,
      Jason.encode!(%{
        "state_dir" => dir,
        "audience" => Kit.audience(),
        "policy_epoch" => 3,
        "allowed_subjects" => ["subject:orders/42"],
        "quorum_default" => 1,
        "registry" => registry
      })
    )

    File.write!(
      Path.join(dir, "revocation.json"),
      Jason.encode!(%{"refreshed_at" => now, "epoch" => 7, "revoked" => []})
    )

    File.write!(Path.join(dir, "effect.bin"), built.effect_bytes)
    File.write!(Path.join(dir, "cert.bin"), built.cert_bytes)
    {:ok, dir: dir, config: config, built: built, now: now}
  end

  defp child(ctx, point) do
    mix = System.find_executable("mix") || flunk("mix not on PATH")
    script = Path.expand("../support/crash_child.exs", __DIR__)

    System.cmd(
      mix,
      [
        "run",
        "--no-start",
        "--no-compile",
        "--no-deps-check",
        script,
        ctx.config,
        Path.join(ctx.dir, "effect.bin"),
        Path.join(ctx.dir, "cert.bin")
      ],
      env: [{"MIX_ENV", "test"}, {"ACTUATOR_TEST_CRASH", point}],
      stderr_to_stdout: true
    )
  end

  defp ledger_entries(dir) do
    path = Path.join(dir, "effect_ledger.jsonl")

    if File.exists?(path),
      do: path |> File.read!() |> String.split("\n", trim: true) |> Enum.map(&Jason.decode!/1),
      else: []
  end

  defp journal_events(dir),
    do:
      Path.join(dir, "journal.jsonl")
      |> File.read!()
      |> String.split("\n", trim: true)
      |> Enum.map(&Jason.decode!/1)

  test "control: without a crash the child completes the effect", ctx do
    {out, status} = child(ctx, "none")
    assert status == 0, out
    assert out =~ "CHILD_RETURNED {:ok, %{status: :performed"
    assert length(ledger_entries(ctx.dir)) == 1
  end

  test "kill between perform and completion: restart -> unknown_outcome, effect count 1, replay = evidence",
       ctx do
    {out, status} = child(ctx, "after_perform")
    assert status == 137, out
    refute out =~ "CHILD_RETURNED"

    assert length(ledger_entries(ctx.dir)) == 1
    assert Enum.map(journal_events(ctx.dir), & &1["t"]) == ["executing"]

    {:ok, store} = Store.start_link(state_dir: ctx.dir)
    assert {:ok, %{"state" => "unknown_outcome"}} = Store.status(store, @id)
    assert List.last(journal_events(ctx.dir))["t"] == "unknown_outcome"

    {:ok, real} = Config.load(ctx.config)
    eff = File.read!(Path.join(ctx.dir, "effect.bin"))
    cert = File.read!(Path.join(ctx.dir, "cert.bin"))

    assert {:ok, %{status: :replayed, evidence: %{"state" => "unknown_outcome"}}} =
             Actuator.execute(store, real, eff, cert)

    assert length(ledger_entries(ctx.dir)) == 1

    # a higher-generation certificate does not retry an unknown_outcome instance either
    retry =
      Kit.build(
        state_dir: ctx.dir,
        now: ctx.now,
        cert: %{"generation" => 2},
        keys: ctx.built.keys,
        nonce_prefix: "retry",
        effect: %{"effect_instance_id" => @id}
      )

    assert {:error, 14, :unknown_outcome} =
             Actuator.execute(
               store,
               %{real | generations: %{@id => 2}},
               retry.effect_bytes,
               retry.cert_bytes
             )

    assert length(ledger_entries(ctx.dir)) == 1

    # reconcile is the only exit; afterwards replay still performs nothing
    assert {:ok, %{"state" => "completed"}} =
             Store.reconcile(store, @id, :confirmed_performed, "operator verified ledger entry")

    assert {:ok, %{status: :replayed, evidence: %{"state" => "completed"}}} =
             Actuator.execute(store, real, eff, cert)

    assert length(ledger_entries(ctx.dir)) == 1
  end

  test "kill after write-ahead before perform: unknown_outcome, effect count 0, never retried",
       ctx do
    {_out, status} = child(ctx, "after_write_ahead")
    assert status == 137
    assert ledger_entries(ctx.dir) == []

    {:ok, store} = Store.start_link(state_dir: ctx.dir)
    assert {:ok, %{"state" => "unknown_outcome"}} = Store.status(store, @id)
    {:ok, real} = Config.load(ctx.config)
    eff = File.read!(Path.join(ctx.dir, "effect.bin"))
    cert = File.read!(Path.join(ctx.dir, "cert.bin"))
    assert {:ok, %{status: :replayed}} = Actuator.execute(store, real, eff, cert)
    assert ledger_entries(ctx.dir) == []

    assert {:ok, %{"state" => "reconciled_not_performed"}} =
             Store.reconcile(store, @id, :confirmed_not_performed, "checked ledger: absent")

    assert {:ok, %{status: :replayed, evidence: %{"state" => "reconciled_not_performed"}}} =
             Actuator.execute(store, real, eff, cert)

    assert ledger_entries(ctx.dir) == []
  end

  test "restart preserves state across a second restart (unknown_outcome is durable)", ctx do
    {_out, 137} = child(ctx, "after_perform")
    {:ok, s1} = Store.start_link(state_dir: ctx.dir)
    GenServer.stop(s1)
    {:ok, s2} = Store.start_link(state_dir: ctx.dir)
    assert {:ok, %{"state" => "unknown_outcome"}} = Store.status(s2, @id)
    assert length(ledger_entries(ctx.dir)) == 1
  end
end
