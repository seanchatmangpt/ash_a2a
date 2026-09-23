defmodule AshA2A.Chicago.PostconditionTest do
  @moduledoc """
  Gate 8 independent postcondition observation (RFC-SA2A-002 §8, §39, §73),
  Chicago style: the real `AshA2A.CommandBus`, the real ETS
  `AshA2A.Chicago.Fixtures.Postcondition.Ledger`, a real
  `AshA2A.ReceiptStore.Memory`, real telemetry, and the durable OCEL artifact
  read back by the independent consumer.

  `async: false` -- the Chicago observer attributes every telemetry event
  emitted inside a stimulus to that falsifier, and the telemetry assertions
  below attach global handlers.
  """

  use ExUnit.Case, async: false

  @moduletag :serial
  @moduletag :serial_shard
  alias AshA2A.{Authority, Command, CommandBus, Identity, Postcondition, Receipt}
  alias AshA2A.Chicago
  alias AshA2A.Chicago.{Query, Runner}
  alias AshA2A.Chicago.Courts.Postcondition, as: Court
  alias AshA2A.Chicago.Fixtures.Postcondition, as: Fixtures

  alias AshA2A.Chicago.Fixtures.Postcondition.{
    AlwaysRefusingVerifier,
    Ledger,
    LedgerVerifier,
    ReportReadingVerifier
  }

  alias AshA2A.Semantic.Refusal

  @moduletag :tmp_dir

  defmodule RaisingVerifier do
    @moduledoc "Real verifier whose read path raises (a crashing reader is an observation, not a verdict)."
    @behaviour AshA2A.Postcondition
    @impl true
    def verify(_expect, _probe), do: raise("ledger reader unavailable")
  end

  defmodule NotAVerifier do
    @moduledoc "A module that does not implement `AshA2A.Postcondition`."
  end

  describe "CHI-POST court end to end (Runner, profile :do)" do
    test "every falsifier reaches its verdict and every pass is OCEL-corroborated", %{
      tmp_dir: dir
    } do
      assert {:ok, run} = Runner.run(courts: [Court], profile: :do, evidence_dir: dir)
      by_id = Map.new(run.results, &{&1.falsifier_id, &1})

      assert Enum.sort(Map.keys(by_id)) ==
               ~w(CHI-POST-001 CHI-POST-002 CHI-POST-003 CHI-POST-004 CHI-POST-005 CHI-POST-006)

      expected = %{
        "CHI-POST-001" => :falsifier_killed,
        "CHI-POST-002" => :falsifier_killed,
        "CHI-POST-003" => :falsifier_killed,
        "CHI-POST-004" => :falsifier_killed,
        "CHI-POST-005" => :positive_control_passed,
        "CHI-POST-006" => :falsifier_killed
      }

      for {id, verdict} <- expected do
        result = by_id[id]
        assert result.verdict == verdict, "#{id}: #{inspect(result, pretty: true)}"
        assert result.attempt_observed? == true, id
        assert result.gate == 8
        assert result.ocel_corroborated? == true, "#{id}: #{result.ocel_detail}"
        assert AshA2A.Chicago.Result.counts_as_pass?(result), id
      end

      assert run.ocel.dropped == 0

      receipt = JSON.decode!(File.read!(Path.join(dir, "standing_receipt.json")))
      assert receipt["results"]["falsifiers_killed"] == 5
      assert receipt["results"]["positive_controls_passed"] == 1
      assert Enum.find(receipt["gates"], &(&1["gate"] == 8))["status"] == "PASSED"
      assert receipt["evidence"]["independent_postcondition"] == "PASS"
    end

    test "the independent consumer reads the postcondition decisions from disk", %{tmp_dir: dir} do
      {:ok, run} = Runner.run(courts: [Court], profile: :do, evidence_dir: dir)
      assert {:ok, index} = Query.load(Path.join(dir, "ocel.json"), run.ocel.sha256)

      # Lying and divergent actuators: contradicted, never completed.
      for id <- ["CHI-POST-001", "CHI-POST-002"] do
        assert {true, _} =
                 Query.eval(
                   index,
                   id,
                   {:observed, "brce.postcondition", %{"outcome" => "contradicted"}}
                 )

        assert {true, _} =
                 Query.eval(
                   index,
                   id,
                   {:observed, "receipt.committed", %{"status" => "postcondition_contradicted"}}
                 )

        assert {false, _} =
                 Query.eval(
                   index,
                   id,
                   {:observed, "receipt.committed", %{"status" => "completed"}}
                 )
      end

      # The report-reading verifier is detectably non-independent.
      assert {true, _} =
               Query.eval(
                 index,
                 "CHI-POST-003",
                 {:observed, "brce.postcondition",
                  %{
                    "outcome" => "unverified",
                    "reason" => "verifier_not_independent",
                    "independent" => "false"
                  }}
               )

      # Observation follows actuation for the same command.
      assert {true, _} =
               Query.eval(
                 index,
                 "CHI-POST-005",
                 {:precedes, "brce.actuate.stop", "brce.postcondition", "command"}
               )
    end

    test "the court is discoverable for SA2A-DO and owns gate 8" do
      assert Court in Chicago.courts_for(:do)
      refute Court in Chicago.courts_for(:plan)
      assert Court.gate() == 8
      assert Enum.all?(Court.falsifiers(), &(&1.attempt_predicate && &1.outcome_predicate))
    end
  end

  describe "AshA2A.Postcondition through the real CommandBus" do
    setup do
      name = Module.concat(__MODULE__, "Store#{System.unique_integer([:positive])}")
      {:ok, pid} = AshA2A.ReceiptStore.Memory.start_link(name: name)
      on_exit(fn -> if Process.alive?(pid), do: GenServer.stop(pid) end)

      handler = "postcondition-test-#{System.unique_integer([:positive])}"
      test_pid = self()

      :telemetry.attach(
        handler,
        [:ash_a2a, :command_bus, :postcondition],
        fn _event, _measurements, meta, _config -> send(test_pid, {:postcondition, meta}) end,
        nil
      )

      on_exit(fn -> :telemetry.detach(handler) end)
      %{store_opts: [name: name]}
    end

    test "honest actuator + independent verifier: verified, completed, independent", ctx do
      {key, result} = submit(:honest_write, LedgerVerifier, ctx.store_opts)

      assert {:ok, %Receipt{status: :completed} = receipt} = result
      assert %{status: :verified, independent: true, reason: nil} = receipt.metadata.postcondition
      assert Fixtures.stored_values(key) == ["X"]
      assert_received {:postcondition, %{outcome: :verified, independent: true}}
    end

    test "lying actuator: contradicted, receipted as such, returned as an error", ctx do
      {key, result} = submit(:lying_write, LedgerVerifier, ctx.store_opts)

      assert {:error, %{code: :postcondition_contradicted, receipt: returned}} = result
      assert returned.status == :postcondition_contradicted
      assert Fixtures.stored_values(key) == []

      # The committed receipt, read back independently, carries no completed standing.
      assert {:ok, stored} = AshA2A.ReceiptStore.Memory.fetch(returned.command_id, ctx.store_opts)
      assert stored.status == :postcondition_contradicted

      assert %{status: :contradicted, evidence: %{"observed" => []}} =
               stored.metadata.postcondition

      assert_received {:postcondition, %{outcome: :contradicted}}
    end

    test "replaying a contradicted command never resurrects completed standing", ctx do
      {key, command, message, opts} = build(:lying_write, LedgerVerifier, ctx.store_opts)

      assert {:error, %{code: :postcondition_contradicted}} =
               CommandBus.run(command, message, Ledger, opts)

      assert {:ok, %Receipt{replayed?: true, status: :postcondition_contradicted}} =
               CommandBus.run(command, message, Ledger, opts)

      assert Fixtures.stored_values(key) == []
    end

    test "divergent actuator: contradicted with the independently observed value", ctx do
      {key, result} = submit(:divergent_write, LedgerVerifier, ctx.store_opts)

      assert {:error, %{code: :postcondition_contradicted, postcondition: pc}} = result
      assert pc.evidence == %{"expected" => "X", "observed" => ["X:diverged"]}
      assert Fixtures.stored_values(key) == ["X:diverged"]
    end

    test "report-reading verifier is detected as non-independent", ctx do
      {_key, result} = submit(:lying_write, ReportReadingVerifier, ctx.store_opts)

      assert {:ok, %Receipt{} = receipt} = result

      assert %{
               status: :unverified,
               reason: :verifier_not_independent,
               independent: false,
               evidence: %{
                 "verdict_under_actuator_report" => "verified",
                 "verdict_under_counterfactual_report" => "contradicted"
               }
             } = receipt.metadata.postcondition

      assert_received {:postcondition, %{outcome: :unverified, independent: false}}
    end

    test "missing postcondition on a :change command is unverified, never verified", ctx do
      {_key, result} = submit(:lying_write, nil, ctx.store_opts)

      assert {:ok, %Receipt{} = receipt} = result

      assert %{status: :unverified, reason: :no_postcondition_declared, verifier: nil} =
               receipt.metadata.postcondition

      assert_received {:postcondition,
                       %{outcome: :unverified, reason: :no_postcondition_declared}}
    end

    test "always-refusing verifier contradicts even a real change (it cannot pass the positive control)",
         ctx do
      {key, result} = submit(:honest_write, AlwaysRefusingVerifier, ctx.store_opts)

      assert {:error, %{code: :postcondition_contradicted}} = result
      assert Fixtures.stored_values(key) == ["X"]
    end

    test "a raising verifier and a non-verifier module are unverified, never verified", ctx do
      {_key, raised} = submit(:honest_write, RaisingVerifier, ctx.store_opts)
      assert {:ok, %Receipt{metadata: %{postcondition: pc}}} = raised
      assert %{status: :unverified, reason: :verifier_raised} = pc
      assert pc.evidence["detail"] =~ "ledger reader unavailable"

      {_key, missing} = submit(:honest_write, NotAVerifier, ctx.store_opts)

      assert {:ok, %Receipt{metadata: %{postcondition: %{reason: :verifier_not_implemented}}}} =
               missing
    end

    test "an :observe command with no postcondition emits no postcondition observation", ctx do
      principal = Identity.principal("postcondition-test")
      capability = Fixtures.capability(:read)

      command =
        Command.new(capability,
          command_id: "postcondition-observe-#{System.unique_integer([:positive])}",
          agent_id: "postcondition-test",
          principal_id: principal,
          input: %{}
        )

      message = A2A.Message.new_user([A2A.Part.Data.new(%{})])

      assert {:ok, %Receipt{consequence: :observe} = receipt} =
               CommandBus.run(command, message, Ledger, store_opts: ctx.store_opts)

      refute Map.has_key?(receipt.metadata, :postcondition)
      refute_received {:postcondition, _}
    end
  end

  describe "AshA2A.Postcondition contract" do
    test "no success claim is unverified without consulting the verifier" do
      probe = %Postcondition.Probe{consequence: :change, actuator_report: {:error, :boom}}
      pc = %Postcondition{id: "p", verifier: AlwaysRefusingVerifier, expect: %{}}

      assert %{status: :unverified, reason: :no_success_claim, independent: nil} =
               Postcondition.evaluate(pc, probe, [])
    end

    test "absence is nil only for :observe" do
      assert Postcondition.evaluate(nil, %Postcondition.Probe{consequence: :observe}, []) == nil

      for consequence <- [:change, :external_do] do
        assert %{status: :unverified, reason: :no_postcondition_declared} =
                 Postcondition.evaluate(nil, %Postcondition.Probe{consequence: consequence}, [])
      end
    end

    test "postcondition_contradicted classifies without editing the Refusal table" do
      assert Refusal.classify(:postcondition_contradicted) == :refused_meta_rigor
    end
  end

  defp submit(action, verifier, store_opts) do
    {key, command, message, opts} = build(action, verifier, store_opts)
    {key, CommandBus.run(command, message, Ledger, opts)}
  end

  defp build(action, verifier, store_opts) do
    key = "unit-#{action}-#{System.unique_integer([:positive])}"
    capability = Fixtures.capability(action)
    principal = Identity.principal("postcondition-test")

    command =
      Command.new(capability,
        command_id: "postcondition-" <> key,
        agent_id: "postcondition-test",
        principal_id: principal,
        authority: Authority.new(principal, capability, token_id: "tok-" <> key),
        input: %{key: key, value: "X"}
      )

    message = A2A.Message.new_user([A2A.Part.Data.new(%{"key" => key, "value" => "X"})])

    opts =
      [store_opts: store_opts] ++
        if verifier,
          do: [
            postcondition: %Postcondition{
              id: "ledger.value_persisted",
              verifier: verifier,
              expect: %{key: key, value: "X"}
            }
          ],
          else: []

    {key, command, message, opts}
  end
end
