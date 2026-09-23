defmodule AshA2A.Chicago.BrceGate7Test do
  @moduledoc """
  RFC-SA2A-002 Gate 7 (§38), BRCE Court (§68) and Prepared Receipt Court
  (§69): the `CHI-BRCE` court run end to end, plus narrow Chicago tests of the
  sole-DO fence it forced (`AshA2A.BrceAnchor`).

  Real collaborators throughout: the real `AshA2A.CommandBus`,
  `AshA2A.Dispatcher`, `AshA2A.Agent`, `AshA2A.ReceiptOutbox` journal on
  disk, real `AshA2A.ReceiptStore.Memory` processes, real ETS resources read
  back through `Ash.read!/1`, real telemetry, and the durable OCEL artifact
  read by the independent consumer. No Mock/Mox/:meck/patch.

  `async: false` -- the observer attributes every telemetry event emitted
  between a stimulus start and stop to that falsifier, and the court points
  `:receipt_outbox_dir` / `:authority_broker` at real faulted or isolated
  environments for the duration of a stimulus.
  """

  use ExUnit.Case, async: false

  @moduletag :serial
  @moduletag :serial_shard
  alias AshA2A.{Authority, BrceAnchor, Command, CommandBus, Dispatcher, Identity, Receipt}
  alias AshA2A.{ReceiptOutbox, ReceiptStore}
  alias AshA2A.Chicago
  alias AshA2A.Chicago.{Query, Runner}
  alias AshA2A.Chicago.Courts.Brce
  alias AshA2A.Chicago.Fixtures.Brce, as: Fx
  alias AshA2A.Chicago.Fixtures.Brce.Ledger
  alias AshA2A.Semantic.Refusal

  @moduletag :tmp_dir

  @expected %{
    "CHI-BRCE-001" => :falsifier_killed,
    "CHI-BRCE-002" => :falsifier_killed,
    "CHI-BRCE-003" => :falsifier_killed,
    "CHI-BRCE-004" => :falsifier_killed,
    "CHI-BRCE-005" => :falsifier_killed,
    "CHI-BRCE-006" => :falsifier_killed,
    "CHI-BRCE-007" => :falsifier_killed,
    "CHI-BRCE-008" => :falsifier_killed,
    "CHI-BRCE-009" => :falsifier_killed,
    "CHI-BRCE-010" => :falsifier_killed,
    "CHI-BRCE-011" => :falsifier_killed,
    "CHI-BRCE-012" => :positive_control_passed,
    "CHI-BRCE-013" => :positive_control_passed,
    "CHI-BRCE-014" => :positive_control_passed,
    "CHI-BRCE-015" => :positive_control_passed
  }

  describe "CHI-BRCE end to end over the real SUT" do
    @tag timeout: 300_000
    @tag :graphlaw_engine
    test "every falsifier reaches its verdict and every pass is corroborated by the independent OCEL consumer",
         %{tmp_dir: dir} do
      assert {:ok, run} = Runner.run(courts: [Brce], profile: :do, evidence_dir: dir)

      by_id = Map.new(run.results, &{&1.falsifier_id, &1})
      assert Enum.sort(Map.keys(by_id)) == Enum.sort(Map.keys(@expected))

      for {id, verdict} <- @expected do
        result = by_id[id]
        assert result.verdict == verdict, "#{id}: #{inspect(result, pretty: true)}"
        assert result.attempt_observed? == true, "#{id}: #{inspect(result, pretty: true)}"
        assert result.ocel_corroborated? == true, "#{id}: #{result.ocel_detail}"
      end

      assert run.ocel.dropped == 0

      receipt = JSON.decode!(File.read!(Path.join(dir, "standing_receipt.json")))
      assert Enum.find(receipt["gates"], &(&1["gate"] == 7))["status"] == "PASSED"
      refute receipt["standing"] == "NONCONFORMANT"
    end

    test "the independent consumer answers the Gate 7 questions from the durable artifact alone",
         %{tmp_dir: dir} do
      {:ok, run} = Runner.run(courts: [Brce], profile: :do, evidence_dir: dir)
      assert {:ok, index} = Query.load(Path.join(dir, "ocel.json"), run.ocel.sha256)

      # The direct-dispatch attack reached the dispatcher, which decided to
      # refuse, and nothing actuated.
      assert {true, _} = Query.eval(index, "CHI-BRCE-001", {:observed, "dispatch.start"})

      assert {true, _} =
               Query.eval(
                 index,
                 "CHI-BRCE-001",
                 {:observed, "dispatch.brce_gate", %{"outcome" => "refused"}}
               )

      assert {false, _} = Query.eval(index, "CHI-BRCE-001", {:observed, "dispatch.actuate"})

      # The storage-failure attack: preparation failed, so DO never began.
      assert {true, _} =
               Query.eval(
                 index,
                 "CHI-BRCE-003",
                 {:observed, "brce.prepare", %{"outcome" => "failed"}}
               )

      assert {false, _} = Query.eval(index, "CHI-BRCE-003", {:observed, "brce.actuate.start"})

      # The lawful DO: durable preparation precedes both actuation points on
      # the same command and the same receipt, and commit follows.
      for predicate <- [
            {:precedes, "brce.prepare", "brce.actuate.start", "command"},
            {:precedes, "brce.prepare", "dispatch.actuate", "receipt"},
            {:precedes, "brce.actuate.start", "brce.commit", "command"}
          ] do
        assert {true, _} = Query.eval(index, "CHI-BRCE-012", predicate)
      end
    end
  end

  describe "court declaration (§11, discovery)" do
    test "CHI-BRCE is a discoverable gate 7 SA2A-DO court with fully declared falsifiers" do
      assert Brce in Chicago.courts_for(:do)
      refute Brce in Chicago.courts_for(:plan)
      assert Brce.gate() == 7

      falsifiers = Brce.falsifiers()
      assert Enum.map(falsifiers, & &1.id) == Enum.sort(Map.keys(@expected))

      for f <- falsifiers do
        assert f.court_id == "CHI-BRCE"
        assert f.attempt_predicate != nil, f.id
        assert f.outcome_predicate != nil, f.id
        assert :ok = Query.validate_predicate(f.attempt_predicate)
        assert :ok = Query.validate_predicate(f.outcome_predicate)
      end

      kinds = Enum.frequencies_by(falsifiers, & &1.kind)
      assert kinds == %{negative: 11, positive_control: 4}
    end

    test "the fence's refusal code is classified without editing the Refusal table" do
      assert Refusal.classify(:brce_prepared_receipt_required) == :refused_receipt
    end
  end

  describe "AshA2A.BrceAnchor.admit/2 over real capability-index skills" do
    setup do
      {:ok, record} = AshA2A.Info.skill(Ledger, :record)
      {:ok, transmit} = AshA2A.Info.skill(Ledger, :transmit)
      {:ok, entries} = AshA2A.Info.skill(Ledger, :entries)
      %{record: record, transmit: transmit, entries: entries}
    end

    test ":observe needs no receipt", %{entries: entries} do
      assert {:ok, nil} = BrceAnchor.admit(entries, nil)
    end

    test "consequence-bearing and :unknown skills without an anchor are refused", %{
      record: record,
      transmit: transmit
    } do
      for skill <- [record, transmit, %{record | consequence: :unknown}] do
        assert {:error, %{code: :brce_prepared_receipt_required, reason: :no_prepared_receipt}} =
                 BrceAnchor.admit(skill, nil)
      end
    end

    test "a pending anchor admits only its own capability and consequence class", %{
      record: record,
      transmit: transmit
    } do
      by_id = pending_anchor(record.id, :change)
      by_name = pending_anchor("record", :change)

      assert {:ok, ^by_id} = BrceAnchor.admit(record, by_id)
      assert {:ok, ^by_name} = BrceAnchor.admit(record, by_name)

      assert {:error, %{reason: :capability_mismatch}} = BrceAnchor.admit(transmit, by_id)

      assert {:error, %{reason: :consequence_mismatch}} =
               BrceAnchor.admit(record, pending_anchor(record.id, :external_do))

      finalized = Receipt.finalize(by_id, {:reply, []})
      assert {:error, %{reason: :anchor_not_pending}} = BrceAnchor.admit(record, finalized)
    end

    test "take/0 is single use" do
      anchor = pending_anchor("record", :change)
      :ok = BrceAnchor.put(anchor)
      assert BrceAnchor.take() == anchor
      assert BrceAnchor.take() == nil
    end
  end

  describe "the fence on the real dispatcher" do
    test "direct dispatch of a :change skill is refused before the Ash action runs" do
      label = "brce-unit-direct-#{System.unique_integer([:positive])}"

      assert {:error, {:brce_gate, %{code: :brce_prepared_receipt_required}}} =
               Dispatcher.dispatch(:record, message(label), Ledger)

      refute label in Fx.ledger_labels()
    end

    test "a durably prepared anchor actuates exactly one dispatch; the next is refused" do
      {:ok, skill} = AshA2A.Info.skill(Ledger, :record)
      label = "brce-unit-anchored-#{System.unique_integer([:positive])}"
      anchor = pending_anchor(skill.id, :change)
      assert :ok = ReceiptOutbox.append(anchor)
      assert ReceiptOutbox.anchored?(anchor)

      :ok = BrceAnchor.put(anchor)
      assert {:reply, _} = Dispatcher.dispatch(:record, message(label), Ledger)
      assert Enum.count(Fx.ledger_labels(), &(&1 == label)) == 1

      assert {:error, {:brce_gate, %{reason: :no_prepared_receipt}}} =
               Dispatcher.dispatch(:record, message(label), Ledger)

      assert Enum.count(Fx.ledger_labels(), &(&1 == label)) == 1
      :ok = ReceiptOutbox.remove(anchor)
    end

    test "an anchor for one capability cannot actuate another" do
      {:ok, record} = AshA2A.Info.skill(Ledger, :record)
      label = "brce-unit-mismatch-#{System.unique_integer([:positive])}"
      :ok = BrceAnchor.put(pending_anchor(record.id, :change))

      assert {:error, {:brce_gate, %{reason: :capability_mismatch}}} =
               Dispatcher.dispatch(:transmit, message(label), Ledger)

      refute label in Fx.effect_labels()
      assert BrceAnchor.take() == nil
    end

    test "CommandBus anchors its own dispatch and leaves no anchor behind" do
      name = Module.concat(__MODULE__, "Store#{System.unique_integer([:positive])}")
      start_supervised!({ReceiptStore.Memory, name: name})
      {:ok, skill} = AshA2A.Info.skill(Ledger, :transmit)
      label = "brce-unit-bus-#{System.unique_integer([:positive])}"

      assert {:ok, %Receipt{status: :completed}} =
               CommandBus.run(command(skill.id, label), message(label), Ledger,
                 store_opts: [name: name]
               )

      assert Enum.count(Fx.effect_labels(), &(&1 == label)) == 1
      assert BrceAnchor.take() == nil
    end
  end

  defp principal, do: Identity.principal("brce-gate7-test")

  defp command(capability_id, label) do
    Command.new(capability_id,
      command_id: "brce-gate7-test-" <> Ash.UUIDv7.generate(),
      agent_id: "brce-gate7-test-agent",
      principal_id: principal(),
      authority: Authority.new(principal(), capability_id),
      input: %{"label" => label}
    )
  end

  defp pending_anchor(capability_id, consequence) do
    command = command(capability_id, "anchor")
    Receipt.pending(command, Identity.execution(Ash.UUIDv7.generate()), consequence)
  end

  defp message(label), do: A2A.Message.new_user([A2A.Part.Data.new(%{"label" => label})])
end
