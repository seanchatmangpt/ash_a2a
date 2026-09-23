defmodule AshA2A.Chicago.FederatedDelegationTest do
  @moduledoc """
  `SA2A-FED` Federated Delegation Court run end to end (RFC-SA2A-001 §54
  Confused Deputy Prevention; RFC-SA2A-002 §75, §38, §68).

  Real collaborators throughout: two genuinely distinct, real supervised
  `A2A.Agent` GenServer processes (peer A, peer B), each with its own real
  `AshA2A.CommandBus` / `AshA2A.Dispatcher` / `AshA2A.Authority.Grant`
  admission path, a real cross-process `A2A.call/3` hop between them, real
  ETS resources read back through `Ash.read!/1`, real telemetry, and the
  durable OCEL artifact read by the independent consumer. No Mock/Mox/:meck/
  patch.

  `async: false` -- the court points `:authority_policy` / `:authority_broker`
  at a real, isolated broker for the duration of the run.
  """

  use ExUnit.Case, async: false

  @moduletag :serial
  @moduletag :serial_shard
  alias AshA2A.Chicago
  alias AshA2A.Chicago.{Query, Runner}
  alias AshA2A.Chicago.Courts.FederatedDelegation

  @moduletag :tmp_dir

  @expected %{
    "SA2A-FED-001" => :positive_control_passed,
    "SA2A-FED-002" => :falsifier_killed,
    "SA2A-FED-003" => :falsifier_killed
  }

  describe "SA2A-FED end to end over the real SUT" do
    @tag timeout: 120_000
    test "every falsifier reaches its verdict and every pass is corroborated by the independent OCEL consumer",
         %{tmp_dir: dir} do
      assert {:ok, run} =
               Runner.run(courts: [FederatedDelegation], profile: :core, evidence_dir: dir)

      by_id = Map.new(run.results, &{&1.falsifier_id, &1})
      assert Enum.sort(Map.keys(by_id)) == Enum.sort(Map.keys(@expected))

      for {id, verdict} <- @expected do
        result = by_id[id]
        assert result.verdict == verdict, "#{id}: #{inspect(result, pretty: true)}"
        assert result.attempt_observed? == true, "#{id}: #{inspect(result, pretty: true)}"
        assert result.ocel_corroborated? == true, "#{id}: #{result.ocel_detail}"
      end

      assert run.ocel.dropped == 0
    end

    test "the independent consumer answers the federation question from the durable artifact alone",
         %{tmp_dir: dir} do
      {:ok, run} = Runner.run(courts: [FederatedDelegation], profile: :core, evidence_dir: dir)
      assert {:ok, index} = Query.load(Path.join(dir, "ocel.json"), run.ocel.sha256)

      # The lawful cross-peer hop: both peers' own CommandBus admitted and
      # committed -- two distinct receipted DOs, not one.
      assert {true, _} = Query.eval(index, "SA2A-FED-001", {:count, "brce.admission", :gte, 2})
      assert {true, _} = Query.eval(index, "SA2A-FED-001", {:count, "brce.commit", :gte, 2})

      # Confused deputy: peer A's own admission is reached, but peer B never
      # acquires a second committed receipt on its own.
      assert {true, _} = Query.eval(index, "SA2A-FED-002", {:count, "brce.admission", :gte, 2})
      assert {false, _} = Query.eval(index, "SA2A-FED-002", {:count, "brce.commit", :gte, 2})

      # Bypass: the dispatcher was reached, but nothing actuated without a
      # preceding receipted prepare sharing command and receipt.
      assert {true, _} = Query.eval(index, "SA2A-FED-003", {:observed, "dispatch.start"})
    end
  end

  describe "court declaration (§11, discovery)" do
    test "SA2A-FED is a discoverable core court with fully declared falsifiers" do
      assert FederatedDelegation in Chicago.courts_for(:core)
      assert FederatedDelegation.gate() == nil

      falsifiers = FederatedDelegation.falsifiers()
      assert Enum.map(falsifiers, & &1.id) == Enum.sort(Map.keys(@expected))

      for f <- falsifiers do
        assert f.court_id == "SA2A-FED"
        assert f.attempt_predicate != nil, f.id
        assert f.outcome_predicate != nil, f.id
        assert :ok = Query.validate_predicate(f.attempt_predicate)
        assert :ok = Query.validate_predicate(f.outcome_predicate)
      end

      kinds = Enum.frequencies_by(falsifiers, & &1.kind)
      assert kinds == %{negative: 2, positive_control: 1}
    end
  end
end
