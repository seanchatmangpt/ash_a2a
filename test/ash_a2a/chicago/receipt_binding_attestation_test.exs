defmodule AshA2A.Chicago.ReceiptBindingAttestationTest do
  @moduledoc """
  Gate 9 complete receipt identity binding (`CHI-RECEIPT`, RFC-SA2A-002 §40,
  §128) and the attestation court (`SA2A-ATTEST`, §24, §72), Chicago style:
  the real `AshA2A.CommandBus`, the real ETS Gate 8 ledger, real
  `AshA2A.ReceiptStore.Memory` / `AshA2A.ReceiptOutbox` on disk, real
  telemetry, and the durable OCEL artifact read back by the independent
  consumer. The binding key is application configuration set and restored
  around the stimulus -- environment, not a double.

  `async: false` -- the Chicago observer attributes every telemetry event
  emitted inside a stimulus, and the key / outbox directory are global env.
  """

  use ExUnit.Case, async: false

  @moduletag :serial
  @moduletag :serial_shard
  alias AshA2A.{Receipt, ReceiptOutbox}
  alias AshA2A.Chicago
  alias AshA2A.Chicago.{Query, Runner}
  alias AshA2A.Chicago.Courts.{Attestation, ReceiptBinding}
  alias AshA2A.Chicago.Fixtures.ReceiptBindingAttestation, as: Fx
  alias AshA2A.Evidence.{Class, HostedCI, LocalTest, Merge, Production, Publication, RuntimeAlive}
  alias AshA2A.Receipt.{Binding, Replay}
  alias AshA2A.Semantic.{Envelope, Refusal, Standing}
  alias AshA2A.Semantic.Attestation, as: SemanticAttestation

  @moduletag :tmp_dir

  @receipt_expected Map.new(1..30, fn n ->
                      id = "CHI-RECEIPT-" <> String.pad_leading("#{n}", 3, "0")

                      {id,
                       if(n in [26, 27, 28, 30],
                         do: :positive_control_passed,
                         else: :falsifier_killed
                       )}
                    end)

  @attest_expected Map.new(1..14, fn n ->
                     id = "SA2A-ATTEST-" <> String.pad_leading("#{n}", 3, "0")

                     {id,
                      if(n in [13, 14], do: :positive_control_passed, else: :falsifier_killed)}
                   end)

  describe "CHI-RECEIPT + SA2A-ATTEST end to end (Runner, profile :do)" do
    test "every falsifier reaches its verdict and every pass is OCEL-corroborated", %{
      tmp_dir: dir
    } do
      assert {:ok, run} =
               Runner.run(courts: [ReceiptBinding, Attestation], profile: :do, evidence_dir: dir)

      by_id = Map.new(run.results, &{&1.falsifier_id, &1})
      expected = Map.merge(@receipt_expected, @attest_expected)
      assert Enum.sort(Map.keys(by_id)) == Enum.sort(Map.keys(expected))

      for {id, verdict} <- expected do
        result = by_id[id]
        assert result.verdict == verdict, "#{id}: #{inspect(result, pretty: true)}"
        assert result.attempt_observed? == true, id
        assert result.ocel_corroborated? == true, "#{id}: #{result.ocel_detail}"
        assert AshA2A.Chicago.Result.counts_as_pass?(result), id
      end

      assert run.ocel.dropped == 0

      receipt = JSON.decode!(File.read!(Path.join(dir, "standing_receipt.json")))
      assert receipt["results"]["falsifiers_killed"] == 38
      assert receipt["results"]["positive_controls_passed"] == 6
      assert Enum.find(receipt["gates"], &(&1["gate"] == 9))["status"] == "PASSED"
      assert receipt["evidence"]["receipt_binding"] == "PASS"
    end

    test "the independent consumer reads the binding, standing and attestation decisions from disk",
         %{tmp_dir: dir} do
      {:ok, run} =
        Runner.run(courts: [ReceiptBinding, Attestation], profile: :do, evidence_dir: dir)

      assert {:ok, index} = Query.load(Path.join(dir, "ocel.json"), run.ocel.sha256)

      # Each tampered field is refused and named.
      for {n, field} <- [{"001", "actor"}, {"007", "authority_grant"}, {"010", "result_identity"}] do
        assert {true, _} =
                 Query.eval(
                   index,
                   "CHI-RECEIPT-" <> n,
                   {:observed, "receipt.binding.verify",
                    %{
                      "outcome" => "refused",
                      "code" => "receipt_binding_field_mismatch",
                      "fields" => field
                    }}
                 )
      end

      # Key posture refusals are typed, not collapsed.
      for {n, code} <- [
            {"023", "receipt_binding_downgraded"},
            {"024", "receipt_binding_keyed_claim_unbacked"},
            {"025", "receipt_binding_key_mismatch"},
            {"029", "receipt_binding_result_unbound"}
          ] do
        assert {true, _} =
                 Query.eval(
                   index,
                   "CHI-RECEIPT-" <> n,
                   {:observed, "receipt.binding.verify", %{"code" => code}}
                 )
      end

      # §128 alternate encodings of llm_output refuse as inferred standing.
      for n <- ["018", "019", "020", "021"] do
        assert {true, _} =
                 Query.eval(
                   index,
                   "CHI-RECEIPT-" <> n,
                   {:observed, "semantic.standing.transition",
                    %{
                      "code" => "standing_inferred",
                      "forbidden_inference_sources" => "llm_output"
                    }}
                 )
      end

      # An evidence class earned elsewhere does not attest these receipts.
      assert {true, _} =
               Query.eval(
                 index,
                 "SA2A-ATTEST-009",
                 {:observed, "attestation.verify",
                  %{
                    "code" => "attestation_claims_unobserved_evidence",
                    "field" => "evidence_class"
                  }}
               )
    end

    test "both courts are discoverable for SA2A-DO with complete §11 declarations" do
      for court <- [ReceiptBinding, Attestation] do
        assert court in Chicago.courts_for(:do)
        refute court in Chicago.courts_for(:plan)
        assert Enum.all?(court.falsifiers(), &(&1.attempt_predicate && &1.outcome_predicate))
      end

      assert ReceiptBinding.gate() == 9
      assert length(ReceiptBinding.falsifiers()) == 30
      assert length(Attestation.falsifiers()) == 14
    end

    test "new refusal codes carry an S42 class" do
      for {code, class} <-
            Map.put(
              Binding.refusal_codes(),
              :attestation_receipt_binding_refused,
              :refused_receipt
            ) do
        assert Refusal.classify(code) == class, "#{code}"
      end
    end
  end

  describe "AshA2A.Receipt.Binding over real CommandBus receipts" do
    setup %{tmp_dir: dir} do
      previous_key = Application.fetch_env(:ash_a2a, :receipt_binding_key)
      previous_outbox = Application.fetch_env(:ash_a2a, :receipt_outbox_dir)
      Application.delete_env(:ash_a2a, :receipt_binding_key)
      Application.put_env(:ash_a2a, :receipt_outbox_dir, Path.join(dir, "outbox"))

      name = Module.concat(__MODULE__, "Store#{System.unique_integer([:positive])}")
      {:ok, pid} = AshA2A.ReceiptStore.Memory.start_link(name: name)

      on_exit(fn ->
        if Process.alive?(pid), do: GenServer.stop(pid)
        restore(:receipt_binding_key, previous_key)
        restore(:receipt_outbox_dir, previous_outbox)
      end)

      %{store_opts: [name: name]}
    end

    test "a committed receipt is bound prepared -> final -> postcondition and survives ETF on disk",
         %{store_opts: store_opts, tmp_dir: dir} do
      %{receipt: receipt} = Fx.execute("unit-honest", :honest_write, store_opts)

      assert %{keyed: false, algorithm: "sha256", key_id: nil, links: links} = receipt.binding
      assert Enum.map(links, & &1.stage) == [:prepared, :final, :postcondition]
      assert [nil, a, b] = Enum.map(links, & &1.predecessor)
      assert a == Enum.at(links, 0).digest and b == Enum.at(links, 1).digest

      from_disk = dir |> Fx.persist!("unit-honest", receipt) |> Fx.read_back!()
      assert {:ok, %{stage: :postcondition, keyed: false, links: 3}} = Binding.verify(from_disk)
      assert {:ok, %Replay.Basis{}} = Replay.basis(from_disk)
    end

    test "tampered and unbound receipts lose replay standing; a contradicted result cannot be laundered",
         %{store_opts: store_opts} do
      %{receipt: honest} = Fx.execute("unit-replay", :honest_write, store_opts)
      %{receipt: contradicted} = Fx.execute("unit-lie", :lying_write, store_opts)

      assert contradicted.status == :postcondition_contradicted
      assert {:ok, %{stage: :postcondition}} = Binding.verify(contradicted)

      laundered = %{contradicted | status: :completed}

      assert {:error,
              %{code: :receipt_binding_field_mismatch, detail: %{fields: [:result_identity]}}} =
               Binding.verify(laundered)

      assert {:error, %{code: :receipt_binding_field_mismatch}} =
               Replay.basis(%{honest | actor: AshA2A.Identity.principal("mallory")})

      assert {:error, %{code: :receipt_unbound}} = Replay.basis(%{honest | binding: nil})
    end

    test "the real outbox drain reseals an intact receipt and never a tampered one", %{
      store_opts: store_opts
    } do
      %{receipt: intact} = Fx.execute("unit-outbox", :honest_write, store_opts)
      %{receipt: other} = Fx.execute("unit-outbox-tamper", :honest_write, store_opts)
      target = Module.concat(__MODULE__, "Drain#{System.unique_integer([:positive])}")
      {:ok, pid} = AshA2A.ReceiptStore.Memory.start_link(name: target)
      on_exit(fn -> if Process.alive?(pid), do: GenServer.stop(pid) end)

      tampered = %{other | plan_digest: Fx.sha("forged-plan")}
      assert :ok = ReceiptOutbox.append(intact)
      assert :ok = ReceiptOutbox.append(tampered)

      assert {:ok, %{committed: 2}} =
               ReceiptOutbox.reconcile(AshA2A.ReceiptStore.Memory, name: target)

      assert {:ok, %Receipt{terminal_status: :reconciled} = drained} =
               AshA2A.ReceiptStore.Memory.fetch(intact.command_id, name: target)

      assert {:ok, %{stage: :reconciled}} = Binding.verify(drained)

      assert {:ok, %Receipt{terminal_status: :reconciled} = drained_tampered} =
               AshA2A.ReceiptStore.Memory.fetch(tampered.command_id, name: target)

      assert {:error, %{code: :receipt_binding_field_mismatch}} = Binding.verify(drained_tampered)
    end

    test "keyed MAC: the key is never recorded and verification is fail-closed on key posture", %{
      store_opts: store_opts
    } do
      key = "unit-receipt-binding-key"

      keyed =
        Fx.with_key(key, fn -> Fx.execute("unit-keyed", :honest_write, store_opts).receipt end)

      assert %{keyed: true, algorithm: "hmac-sha256", key_id: key_id, links: links} =
               keyed.binding

      assert key_id == Binding.key_id(key)
      refute inspect(keyed.binding) =~ key
      assert Enum.all?(links, &String.starts_with?(&1.digest, "hmac-sha256:"))

      assert {:ok, %{keyed: true}} = Binding.verify(keyed, key: key)
      assert {:error, %{code: :receipt_binding_key_unavailable}} = Binding.verify(keyed, key: nil)

      assert {:error, %{code: :receipt_binding_key_mismatch}} =
               Binding.verify(keyed, key: "other")

      %{receipt: unkeyed} = Fx.execute("unit-unkeyed", :honest_write, store_opts)
      assert {:ok, %{keyed: false}} = Binding.verify(unkeyed, key: nil)
      assert {:error, %{code: :receipt_binding_downgraded}} = Binding.verify(unkeyed, key: key)
    end

    test "a duplicate actuation through the real bus is receipted with a verifying :deduplicated link",
         %{store_opts: store_opts} do
      key = "unit-dedup-#{System.unique_integer([:positive])}"
      capability = AshA2A.Chicago.Fixtures.Postcondition.capability(:honest_write)
      principal = AshA2A.Identity.principal("chicago-receipt-subject")

      command = fn suffix ->
        AshA2A.Command.new(capability,
          command_id: "chicago-receipt-dedup-#{suffix}-#{key}",
          agent_id: "chicago-receipt-agent",
          principal_id: principal,
          authority: AshA2A.Authority.new(principal, capability, token_id: "tok-" <> key),
          input: %{key: key, value: "X"}
        )
      end

      message = A2A.Message.new_user([A2A.Part.Data.new(%{"key" => key, "value" => "X"})])
      opts = [store_opts: store_opts, actuation_dedup: :strict]
      ledger = AshA2A.Chicago.Fixtures.Postcondition.Ledger

      assert {:ok, %Receipt{status: :completed} = first} =
               AshA2A.CommandBus.run(command.("first"), message, ledger, opts)

      assert {:ok, %Receipt{metadata: %{outcome: :deduplicated}} = second} =
               AshA2A.CommandBus.run(command.("second"), message, ledger, opts)

      assert first.actuation_id == second.actuation_id
      assert List.last(second.binding.links).stage == :deduplicated
      assert {:ok, %{stage: :deduplicated}} = Binding.verify(second)
      assert AshA2A.Chicago.Fixtures.Postcondition.stored_values(key) == ["X"]
    end
  end

  describe "AshA2A.Semantic.Standing §128 laundering resistance" do
    test "alternate encodings of llm_output refuse with the canonical key and full path" do
      base = %{transport: "https", received_at: "2026-09-16T00:00:00Z"}

      for {evidence, path} <- [
            {Map.put(base, :bundle, llm_output: "x"), ["bundle", 0, "llm_output"]},
            {Map.put(base, :bundle, [{"llm_output", "x"}]), ["bundle", 0, "llm_output"]},
            {Map.put(base, :tagged, {:llm_output, "x"}), ["tagged", "llm_output"]},
            {Map.put(base, "llmOutput", "x"), ["llmOutput"]},
            {Map.put(base, :bundle, %{"LLM-Output" => "x"}), ["bundle", "LLM-Output"]},
            {Map.put(base, :bundle, ok: [confidence: 0.99]), ["bundle", 0, "ok", 0, "confidence"]}
          ] do
        envelope =
          Envelope.new!(%{
            envelope_id: "urn:unit:#{System.unique_integer([:positive])}",
            kind: "sa2a:Request"
          })

        assert {:error, %Refusal{code: :standing_inferred, detail: detail}} =
                 Standing.transition(envelope, :received, evidence)

        assert detail.forbidden_inference_paths == [path], inspect(evidence)
        assert Enum.all?(detail.forbidden_inference_sources, &is_atom/1)
      end
    end

    test "clean evidence with keyword lists and pair tuples still transitions" do
      envelope = Envelope.new!(%{envelope_id: "urn:unit:clean", kind: "sa2a:Request"})

      evidence = %{
        transport: "https",
        received_at: "2026-09-16T00:00:00Z",
        bundle: [source: "bytes", status: {:ok, "fine"}],
        pairs: [{"digest", Fx.sha("clean")}]
      }

      assert {:ok, %Envelope{standing: :received}} =
               Standing.transition(envelope, :received, evidence)
    end
  end

  describe "AshA2A.Semantic.Attestation evidence class backing (§72)" do
    test "an earned class from an unrelated chain does not attest a local_test receipt", %{
      tmp_dir: _dir
    } do
      name = Module.concat(__MODULE__, "AttestStore#{System.unique_integer([:positive])}")
      {:ok, pid} = AshA2A.ReceiptStore.Memory.start_link(name: name)
      on_exit(fn -> if Process.alive?(pid), do: GenServer.stop(pid) end)

      %{receipt: receipt} = Fx.execute("unit-attest", :honest_write, name: name)
      assert {:ok, honest} = SemanticAttestation.from_receipts([receipt])
      assert %LocalTest{} = honest.evidence_class
      assert %{keyed: false, digests: [_]} = honest.receipt_binding
      assert :ok = SemanticAttestation.verify(honest, [receipt])

      merge =
        Enum.reduce(
          [
            {HostedCI, %{job: 1}},
            {Production, %{d: 1}},
            {RuntimeAlive, %{p: 1}},
            {Publication, %{r: 1}},
            {Merge, %{pr: 1}}
          ],
          LocalTest.new(%{suite: "elsewhere"}),
          fn {target, basis}, current ->
            {:ok, next} = Class.promote(current, target, basis)
            next
          end
        )

      assert :ok = Class.verify_chain(merge)

      assert {:error, %{code: :attestation_claims_unobserved_evidence, detail: :evidence_class}} =
               SemanticAttestation.verify(%{honest | evidence_class: merge}, [receipt])
    end
  end

  defp restore(key, {:ok, value}), do: Application.put_env(:ash_a2a, key, value)
  defp restore(key, :error), do: Application.delete_env(:ash_a2a, key)
end
