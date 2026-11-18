# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshA2A.Chicago.FiboFinanceTest do
  @moduledoc """
  Qualifies the `CHI-FIN` court, Chicago style: the real graphlaw JSON ABI
  (compiled wasm, `GRAPHLAW_ABI_WASM`, run by Wasmtime), a real ETS ledger, a
  real journal file, a real `:kill` of a real process, and the durable OCEL
  artifact read back by the independent consumer. Nothing on the path is
  replaced by a double.

  Standing ceiling: finite published corpus passes on exact subject; authority
  NONE; synthetic subject; no general financial safety claim. The `$10M`
  ceiling is this court's policy, not FIBO's; there is no payment rail.

  Each negative falsifier is proven non-vacuous: with exactly its guard removed
  (`without: [guard]`) the forbidden outcome is observed.

  `async: false`: the observer attributes every telemetry event emitted between
  a stimulus start and stop to that falsifier.
  """

  use ExUnit.Case, async: false

  @moduletag :serial
  @moduletag :serial_shard
  @moduletag :tmp_dir
  @moduletag capture_log: true
  @moduletag timeout: 600_000

  alias AshA2A.Chicago.Courts.FiboFinance, as: Court
  alias AshA2A.Chicago.Fixtures.FiboFinance, as: Fx
  alias AshA2A.Chicago.Fixtures.FiboFinance.Abi
  alias AshA2A.Chicago.Runner

  @expected %{
    "CHI-FIN-001" => :falsifier_killed,
    "CHI-FIN-002" => :positive_control_passed,
    "CHI-FIN-003" => :falsifier_killed,
    "CHI-FIN-004" => :positive_control_passed,
    "CHI-FIN-005" => :falsifier_killed,
    "CHI-FIN-006" => :positive_control_passed,
    "CHI-FIN-007" => :falsifier_killed,
    "CHI-FIN-008" => :falsifier_killed,
    "CHI-FIN-009" => :falsifier_killed,
    "CHI-FIN-010" => :positive_control_passed,
    "CHI-FIN-011" => :falsifier_killed,
    "CHI-FIN-012" => :falsifier_killed,
    "CHI-FIN-013" => :positive_control_passed
  }

  setup_all do
    case Fx.start_abi() do
      {:ok, abi} ->
        on_exit(fn -> Abi.stop(abi) end)
        {:ok, abi: abi}

      {:blocked, reason} ->
        flunk(
          "BLOCKED[wasm-artifact]: #{reason} (set #{Abi.env()} to the HEAD-rebuilt graphlaw ABI wasm)"
        )
    end
  end

  describe "the CHI-FIN court over the real SUT" do
    test "the declared falsifier ids are contiguous and unique" do
      ids = Enum.map(Court.falsifiers(), & &1.id)
      assert ids == Enum.sort(ids)
      assert ids == Enum.uniq(ids)
      assert Enum.sort(ids) == Enum.sort(Map.keys(@expected))
    end

    test "every falsifier reaches its verdict and every pass is OCEL-corroborated", %{
      tmp_dir: dir
    } do
      assert {:ok, run} = Runner.run(courts: [Court], profile: :core, evidence_dir: dir)

      by_id = Map.new(run.results, &{&1.falsifier_id, &1})
      assert by_id |> Map.keys() |> Enum.sort() == @expected |> Map.keys() |> Enum.sort()

      for {id, verdict} <- @expected do
        result = by_id[id]

        assert result.verdict == verdict,
               "#{id}: expected #{verdict}, got #{result.verdict} -- " <>
                 "#{inspect(result.detail)} / #{inspect(result.ocel_detail)}"

        assert result.ocel_corroborated? == true, "#{id}: #{inspect(result.ocel_detail)}"
        assert result.evidence["graphlaw_abi_wasm_sha256"] =~ ~r/^[0-9a-f]{64}$/
      end

      assert run.ocel.dropped == 0

      receipt = JSON.decode!(File.read!(Path.join(dir, "standing_receipt.json")))
      assert receipt["results"]["falsifiers_killed"] == 8
      assert receipt["results"]["falsifiers_survived"] == 0
      assert receipt["results"]["positive_controls_passed"] == 5
      assert receipt["results"]["unresolved_ids"] == []
    end
  end

  describe "positive controls are real effects" do
    test "an in-envelope transfer writes exactly one row and completes", %{abi: abi} do
      s = Fx.within_envelope(abi)
      assert [%{outcome: :completed, observed_rows: 1}] = s.results
      assert [%{amount: amount}] = s.rows
      assert amount == Fx.usd(5)
    end

    test "the ceiling is inclusive at exactly $10M", %{abi: abi} do
      s = Fx.ceiling_boundary(abi)
      assert [%{outcome: :completed}] = s.results
      assert [%{amount: 10_000_000_000_000}] = s.rows
    end

    test "the exact $100M authority completes with the sealed counterparty", %{abi: abi} do
      s = Fx.exact_authority(abi)
      assert [%{outcome: :completed}] = s.results
      assert [%{amount: 100_000_000_000_000, counterparty: "urn:party:acme"}] = s.rows
    end
  end

  describe "refusals name the gate that decided" do
    test "each attack is refused at its own gate and writes nothing", %{abi: abi} do
      assert %{
               results: [%{outcome: {:refused, "envelope", :money_micros_envelope_exceeded}}],
               rows: []
             } =
               Fx.envelope_breach(abi)

      assert %{results: [%{outcome: {:refused, "ceiling", :grant_ceiling_exceeded}}], rows: []} =
               Fx.ceiling_breach(abi)

      assert %{results: [%{outcome: {:refused, "seal", :effect_mutated_after_seal}}], rows: []} =
               Fx.counterparty_mutation(abi)

      assert %{results: [%{outcome: {:refused, "key_status", :signing_key_revoked}}], rows: []} =
               Fx.revoked_key_submission(abi)
    end

    test "a replay is refused by the plan's pre_not and the ledger keeps one row", %{abi: abi} do
      s = Fx.replay(abi)

      assert [%{outcome: :completed}, %{outcome: {:refused, "plan", :already_settled}}] =
               s.results

      assert length(s.rows) == 1
    end

    test "a lying processor is withheld, not completed", %{abi: abi} do
      s = Fx.lying_processor(abi)
      assert [%{outcome: :withheld, observed_rows: 0}] = s.results
      assert s.rows == []
    end

    test "a crash after the effect is reconciled, not re-executed", %{abi: abi} do
      s = Fx.crash_after_do(abi)
      assert [%{outcome: :crashed}] = s.results
      assert [%{outcome: :reconciled}] = s.recovered
      assert length(s.rows) == 1
    end

    test "the cascade stops at the depth bound and a short one runs to its end", %{abi: abi} do
      bounded = Fx.cascade(abi, 10)
      assert bounded.stop == "depth_bound"
      assert length(bounded.rows) == 3

      short = Fx.cascade(abi, 3)
      assert short.stop == "chain_end"
      assert length(short.rows) == 3
    end
  end

  describe "non-vacuity: removing exactly one guard makes the forbidden outcome happen" do
    test "no envelope guard: the $25M transfer is debited", %{abi: abi} do
      s = Fx.envelope_breach(abi, [:envelope])
      assert [%{outcome: :completed}] = s.results
      assert [%{amount: 25_000_000_000_000}] = s.rows
    end

    test "no ceiling guard: the $25M transfer under a $10M ceiling is debited", %{abi: abi} do
      s = Fx.ceiling_breach(abi, [:ceiling])
      assert [%{outcome: :completed}] = s.results
      assert [%{amount: 25_000_000_000_000}] = s.rows
    end

    test "no seal guard: the mutated counterparty is paid", %{abi: abi} do
      s = Fx.counterparty_mutation(abi, [:seal])
      assert [%{outcome: :completed}] = s.results
      assert [%{counterparty: "urn:party:mallory"}] = s.rows
    end

    test "no key-status guard: the revoked key's transfer is debited", %{abi: abi} do
      s = Fx.revoked_key_submission(abi, [:key_status])
      assert [%{outcome: :completed}] = s.results
      assert length(s.rows) == 1
    end

    test "no replay guard: the replay debits twice (the observer then withholds the second)", %{
      abi: abi
    } do
      s = Fx.replay(abi, [:replay])
      assert [%{outcome: :completed}, %{outcome: :withheld, observed_rows: 2}] = s.results
      assert length(s.rows) == 2
    end

    test "no observer guard: the lying processor is completed with an empty ledger", %{abi: abi} do
      s = Fx.lying_processor(abi, [:observer])
      assert [%{outcome: :completed}] = s.results
      assert s.rows == []
    end

    test "no reconcile guard: recovery re-executes and the ledger holds two rows", %{abi: abi} do
      s = Fx.crash_after_do(abi, [:reconcile])
      assert [%{outcome: :reexecuted}] = s.recovered
      assert length(s.rows) == 2
    end

    test "no depth guard: the cascade runs past the bound", %{abi: abi} do
      s = Fx.cascade(abi, 10, [:depth])
      assert length(s.rows) > 3
    end
  end

  describe "the engine is a precondition, never assumed" do
    test "a missing ABI artifact is BLOCKED for every falsifier, never a pass", %{tmp_dir: dir} do
      previous = System.get_env(Abi.env())
      System.put_env(Abi.env(), Path.join(dir, "absent.wasm"))

      try do
        assert {:ok, run} = Runner.run(courts: [Court], profile: :core, evidence_dir: dir)
        assert length(run.results) == map_size(@expected)
        assert Enum.all?(run.results, &(&1.verdict == :blocked))
        refute Enum.any?(run.results, & &1.ocel_corroborated?)
      after
        if previous, do: System.put_env(Abi.env(), previous), else: System.delete_env(Abi.env())
      end
    end
  end
end
