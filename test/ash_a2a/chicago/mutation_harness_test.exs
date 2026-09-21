defmodule AshA2A.Chicago.MutationHarnessTest do
  @moduledoc """
  Qualifies the RFC-SA2A-002 §22/§97 mutation harness Chicago style: real
  BEAM debug_info, real `:compile.forms/2`, real hot code loading into this
  VM, real courts over the real `AshA2A.CommandBus`, real telemetry, and
  verdicts read back from the durable conformance packages on disk.

  `async: false`: a live mutant changes code for the whole node, and the
  observer attributes telemetry by stimulus bracket. Every test module
  touched is forced back to its on-disk BEAM in `on_exit`, even on failure.
  """

  use ExUnit.Case, async: false

  @moduletag :serial
  @moduletag :serial_shard
  alias AshA2A.{Authority, CommandBus, Identity}
  alias AshA2A.Authority.Broker
  alias AshA2A.Chicago.{Mutation, Runner}
  alias AshA2A.Chicago.Courts.MutationCourt
  alias AshA2A.Chicago.Fixtures.MutationHarness.GuardCourt
  alias AshA2A.Chicago.Mutation.{Catalog, Verdict}
  alias AshA2A.Semantic.Refusal
  alias AshA2A.Test.ChicagoSelfTest

  @moduletag :tmp_dir

  @touched [
    CommandBus,
    Authority,
    Broker.InMemory,
    AshA2A.Authority.Decision,
    AshA2A.Semantic.Envelope,
    AshA2A.Semantic.AdmissionPipeline,
    AshA2A.Semantic.FalsifierSuite,
    AshA2A.Chicago.Runner
  ]

  setup do
    on_exit(fn ->
      for module <- @touched, do: Mutation.restore!(module)
    end)

    for module <- @touched do
      assert Mutation.pristine?(module), "#{inspect(module)} entered the test mutated"
    end

    :ok
  end

  defp capture_mutation_events do
    test = self()
    handler = {__MODULE__, make_ref()}

    :ok =
      :telemetry.attach_many(
        handler,
        Mutation.events(),
        fn event, _m, meta, _ ->
          send(test, {:mutation_event, List.last(event), meta})
        end,
        nil
      )

    on_exit(fn -> :telemetry.detach(handler) end)
  end

  defp expired_authority do
    principal = Identity.principal("mutation-test")

    Authority.new(principal, "cap", expires_at: DateTime.add(DateTime.utc_now(), -60, :second))
  end

  describe "engine: build, load, always restore" do
    test "every §97 catalog target is a real function in this subject or blocked with a reason" do
      resolution = Map.new(Catalog.resolution(), &{&1.id, &1})
      assert map_size(resolution) == length(Catalog.entries())

      for id <- [
            "authority_check_true",
            "authority_admits_true",
            "ignore_expiry",
            "ignore_revocation",
            "remove_receipt_preparation",
            "accept_unsupported_profile",
            "trust_sender_standing",
            "skip_shacl",
            "skip_graph_global_falsifiers",
            "skip_graph_global_falsifier_gate",
            "caller_controlled_consequence",
            "caller_controlled_consequence_decision",
            "root_manifest_component_drift",
            "replay_calls_actuator"
          ] do
        assert %{status: :resolvable, clauses_mutated: n} = resolution[id].target_status
        assert n >= 1
      end

      # Clause selectors hit exactly the named stage, not the whole function.
      assert resolution["skip_shacl"].target_status.clauses_mutated == 1
      assert resolution["skip_graph_global_falsifiers"].target_status.clauses_mutated == 1

      # RFC-SA2A-001 S20 root manifest is compiled in this subject; its drift
      # guard has a compiled killer family (Gate 1 exact identity).
      assert "CHI-ID" in resolution["root_manifest_component_drift"].killers.resolved

      # The reference court always resolves as a killer for the BRCE/authority guards.
      for id <- ~w(authority_check_true authority_admits_true ignore_expiry ignore_revocation
                   remove_receipt_preparation caller_controlled_consequence replay_calls_actuator) do
        assert "CHI-MUTGUARD" in resolution[id].killers.resolved
      end
    end

    test "a live mutant changes the real function; restoration returns the on-disk BEAM" do
      capture_mutation_events()
      authority = expired_authority()
      assert Authority.expired?(authority)

      mutation = Catalog.fetch!("ignore_expiry")

      assert {:ok, during, %{applied: applied, restored: restored}} =
               Mutation.with_mutant(mutation, fn applied ->
                 refute Mutation.pristine?(Authority)
                 assert applied.loaded_md5 == applied.mutant_md5
                 Authority.expired?(authority)
               end)

      assert during == false
      assert Authority.expired?(authority)
      assert Mutation.pristine?(Authority)
      assert applied.original_md5 != applied.mutant_md5
      assert restored.pristine == true
      assert restored.restored_md5 == applied.original_md5
      assert restored.trigger == :owner
      assert restored.mutant_calls >= 1

      assert_received {:mutation_event, :requested, %{mutation_id: "ignore_expiry"}}
      assert_received {:mutation_event, :applied, %{mutation_id: "ignore_expiry"}}

      assert_received {:mutation_event, :restored,
                       %{mutation_id: "ignore_expiry", pristine: true}}
    end

    test "a private function can be mutated (CommandBus.prepare_receipt_anchor/4)" do
      mutation = Catalog.fetch!("remove_receipt_preparation")
      assert {:ok, plan} = Mutation.prepare(mutation)
      assert plan.clauses_mutated == 2
      refute function_exported?(CommandBus, :prepare_receipt_anchor, 4)

      assert {:ok, :loaded, %{restored: %{pristine: true}}} =
               Mutation.with_mutant(mutation, fn _ -> :loaded end)

      assert Mutation.pristine?(CommandBus)
    end

    test "a raise inside the stimulus is re-raised after restoration" do
      assert_raise RuntimeError, "stimulus exploded", fn ->
        Mutation.with_mutant(Catalog.fetch!("ignore_expiry"), fn _ ->
          refute Mutation.pristine?(Authority)
          raise "stimulus exploded"
        end)
      end

      assert Mutation.pristine?(Authority)
      assert Authority.expired?(expired_authority())
    end

    test "killing the owner with :kill still restores the module (guardian)" do
      capture_mutation_events()
      test = self()
      mutation = %{Catalog.fetch!("ignore_expiry") | id: "owner_killed_probe"}

      {owner, owner_ref} =
        spawn_monitor(fn ->
          Mutation.with_mutant(mutation, fn applied ->
            send(test, {:live, applied.guardian})
            Process.sleep(:infinity)
          end)
        end)

      assert_receive {:live, guardian}, 10_000
      refute Mutation.pristine?(Authority)
      assert Authority.expired?(expired_authority()) == false

      guardian_ref = Process.monitor(guardian)
      Process.exit(owner, :kill)
      assert_receive {:DOWN, ^owner_ref, :process, ^owner, :killed}, 5_000
      assert_receive {:DOWN, ^guardian_ref, :process, ^guardian, :normal}, 15_000

      assert Mutation.pristine?(Authority)
      assert Authority.expired?(expired_authority())

      assert_receive {:mutation_event, :restored,
                      %{mutation_id: "owner_killed_probe", pristine: true, trigger: :owner_down}}
    end

    test "only one mutant may be live in the node" do
      test = self()
      first = %{Catalog.fetch!("ignore_expiry") | id: "lock_holder"}

      holder =
        Task.async(fn ->
          Mutation.with_mutant(first, fn _ ->
            send(test, :holding)

            receive do
              :release -> :released
            end
          end)
        end)

      assert_receive :holding, 10_000

      # A different module: refused by the engine lock, nothing loaded.
      assert {:error, %{code: :mutation_in_progress}} =
               Mutation.with_mutant(Catalog.fetch!("authority_check_true"), fn _ ->
                 flunk("a second live mutant must never run")
               end)

      assert Mutation.pristine?(CommandBus)

      # The same module: its loaded code is no longer its on-disk BEAM.
      assert {:error, %{code: :mutation_target_not_pristine}} =
               Mutation.with_mutant(Catalog.fetch!("authority_admits_true"), fn _ ->
                 flunk("a mutant over a mutant must never run")
               end)

      assert Mutation.pristine?(Authority) == false
      send(holder.pid, :release)
      assert {:ok, :released, %{restored: %{pristine: true}}} = Task.await(holder, 15_000)
      assert Mutation.pristine?(Authority)
    end

    test "refusals are typed and nothing is loaded" do
      base = %Mutation{
        id: "refusal_probe",
        module: Authority,
        function: :expired?,
        arity: 1,
        operator: {:replace_body, "false."}
      }

      assert {:error, %{code: :mutation_target_protected}} =
               Mutation.prepare(%{base | module: AshA2A.Chicago.Runner, function: :run})

      assert {:error, %{code: :mutation_target_protected}} =
               Mutation.prepare(%{base | module: Mutation, function: :prepare})

      assert {:error, %{code: :mutation_target_foreign}} =
               Mutation.prepare(%{base | module: Enum, function: :count})

      assert {:error, %{code: :mutation_target_not_compiled}} =
               Mutation.prepare(%{base | module: AshA2A.Semantic.NotCompiledInThisSubject})

      assert {:error, %{code: :mutation_function_not_found}} =
               Mutation.prepare(%{base | function: :no_such_function})

      assert {:error, %{code: :mutation_clause_not_matched}} =
               Mutation.prepare(%{
                 base
                 | module: AshA2A.Semantic.AdmissionPipeline,
                   function: :run_stage,
                   arity: 4,
                   clauses: {:arg_literal, 1, :no_such_stage}
               })

      assert {:error, %{code: :mutation_body_invalid}} =
               Mutation.prepare(%{base | operator: {:replace_body, "false"}})

      assert {:error, %{code: :mutation_compile_failed}} =
               Mutation.prepare(%{base | operator: {:replace_body, "UnboundVariable."}})

      assert {:error, %{code: :mutation_target_protected}} =
               Mutation.with_mutant(
                 %{base | module: AshA2A.Chicago.Runner, function: :run},
                 fn _ ->
                   flunk("a protected mutant must never run")
                 end
               )

      assert Mutation.pristine?(AshA2A.Chicago.Runner)
      assert Mutation.pristine?(Authority)
    end

    test "a court with a recorded open defect kills only through a baseline-corroborated pass" do
      court = ChicagoSelfTest.Court
      id = court.id()
      restored = %{pristine: true, mutant_calls: 1}
      m = Catalog.fetch!("ignore_expiry")

      summary = fn failed, passed, unresolved ->
        {:ok,
         %{
           dir: "unused",
           standing: "NONCONFORMANT",
           receipt_digest: nil,
           ocel_digest: nil,
           by_court: %{id => %{failed: failed, passed: passed, unresolved: unresolved}}
         }}
      end

      baseline = summary.(["#{id}-017"], ["#{id}-001", "#{id}-020"], [])

      # 020 passed (corroborated) in the baseline and fails under the mutant.
      killed =
        Mutation.judge(
          m,
          [court],
          [],
          baseline,
          summary.(["#{id}-017", "#{id}-020"], ["#{id}-001"], []),
          %{},
          restored
        )

      assert killed.verdict == :mutant_killed
      assert killed.killed_by == ["#{id}-020"]
      assert killed.court_verdicts == %{id => :killed}

      # Only the pre-existing defect fails: never survived, never killed.
      unchanged =
        Mutation.judge(
          m,
          [court],
          [],
          baseline,
          summary.(["#{id}-017"], ["#{id}-001", "#{id}-020"], []),
          %{},
          restored
        )

      assert unchanged.verdict == :unknown
      assert unchanged.court_verdicts == %{id => :unknown}

      # A new failure of a falsifier that never passed in the baseline is not attributable.
      unattributable =
        Mutation.judge(
          m,
          [court],
          [],
          summary.(["#{id}-017"], ["#{id}-001"], ["#{id}-030"]),
          summary.(["#{id}-017", "#{id}-030"], ["#{id}-001"], []),
          %{},
          restored
        )

      assert unattributable.verdict == :unknown
    end

    test "the engine's refusal codes classify without editing the Refusal table" do
      for {code, class} <- Mutation.__sa2a_refusal_codes__() do
        assert Refusal.classify(code) == class
      end

      assert Refusal.classify(:mutation_target_protected) == :refused_authority
    end
  end

  describe "proof: CommandBus.admit/2 -> :ok against the self-test court" do
    test "CHI-SELFTEST-001 survives under the mutant and is killed again after restore", %{
      tmp_dir: dir
    } do
      mutation = %{Catalog.fetch!("authority_check_true") | killers: ["CHI-SELFTEST"]}

      # Direct: the real Runner inside the live mutant.
      assert {:ok, {:ok, mutated_run}, %{restored: %{pristine: true} = restored}} =
               Mutation.with_mutant(mutation, fn _ ->
                 Runner.run(
                   profile: :core,
                   courts: [ChicagoSelfTest.Court],
                   evidence_dir: Path.join(dir, "direct-mutant")
                 )
               end)

      mutated = Map.new(mutated_run.results, &{&1.falsifier_id, &1})
      assert mutated["CHI-SELFTEST-001"].verdict == :falsifier_survived
      assert mutated["CHI-SELFTEST-001"].failure_class == :authority_failure
      assert mutated_run.receipt["standing"] == "NONCONFORMANT"
      assert restored.mutant_calls >= 2

      assert Mutation.pristine?(CommandBus)

      {:ok, restored_run} =
        Runner.run(
          profile: :core,
          courts: [ChicagoSelfTest.Court],
          evidence_dir: Path.join(dir, "direct-restored")
        )

      after_restore = Map.new(restored_run.results, &{&1.falsifier_id, &1})
      assert after_restore["CHI-SELFTEST-001"].verdict == :falsifier_killed
      assert after_restore["CHI-SELFTEST-001"].ocel_corroborated? == true

      # Through qualify/2: judged from the durable packages, not memory.
      assert %Verdict{verdict: :mutant_killed} =
               verdict =
               Mutation.qualify(mutation,
                 courts: [ChicagoSelfTest.Court],
                 evidence_dir: Path.join(dir, "qualify")
               )

      assert verdict.court_verdicts == %{"CHI-SELFTEST" => :killed}
      assert "CHI-SELFTEST-001" in verdict.killed_by
      assert verdict.baseline.standing == "PARTIAL_ALIVE"
      assert verdict.mutant.standing == "NONCONFORMANT"

      mutant_results =
        Path.join(verdict.mutant.dir, "results.json") |> File.read!() |> JSON.decode!()

      assert %{"verdict" => "FALSIFIER_SURVIVED"} =
               Enum.find(mutant_results, &(&1["falsifier_id"] == "CHI-SELFTEST-001"))

      assert Mutation.pristine?(CommandBus)
    end

    test "a vacuous court for the guard is reported as mutant_survived", %{tmp_dir: dir} do
      # The self-test court never drives a replay, so removing the replay
      # guard cannot make it fail: the harness must say so.
      mutation = %{Catalog.fetch!("replay_calls_actuator") | killers: ["CHI-SELFTEST"]}

      assert %Verdict{verdict: :mutant_survived, court_verdicts: %{"CHI-SELFTEST" => :survived}} =
               Mutation.qualify(mutation, courts: [ChicagoSelfTest.Court], evidence_dir: dir)

      assert Mutation.pristine?(CommandBus)
    end

    test "CHI-SELFTEST-REPLAY-001 closes that vacuity: killed at baseline, survives under the mutant that lets replay re-actuate, killed again after restore",
         %{tmp_dir: dir} do
      # Baseline: the real replay guard is intact, so the falsifier is killed
      # and corroborated by the independent OCEL consumer.
      assert {:ok, baseline_run} =
               Runner.run(
                 profile: :core,
                 courts: [ChicagoSelfTest.ReplayCourt],
                 evidence_dir: Path.join(dir, "direct-baseline")
               )

      baseline_result =
        Enum.find(baseline_run.results, &(&1.falsifier_id == "CHI-SELFTEST-REPLAY-001"))

      assert baseline_result.verdict == :falsifier_killed
      assert baseline_result.ocel_corroborated? == true

      mutation = %{Catalog.fetch!("replay_calls_actuator") | killers: ["CHI-SELFTEST-REPLAY"]}

      # Direct: inside the live mutant, the second (replay) submission now
      # re-actuates -- the falsifier survives.
      assert {:ok, {:ok, mutated_run}, %{restored: %{pristine: true} = restored}} =
               Mutation.with_mutant(mutation, fn _ ->
                 Runner.run(
                   profile: :core,
                   courts: [ChicagoSelfTest.ReplayCourt],
                   evidence_dir: Path.join(dir, "direct-mutant")
                 )
               end)

      mutated_result =
        Enum.find(mutated_run.results, &(&1.falsifier_id == "CHI-SELFTEST-REPLAY-001"))

      assert mutated_result.verdict == :falsifier_survived
      assert mutated_result.failure_class == :replay_failure
      assert restored.mutant_calls >= 2
      assert Mutation.pristine?(CommandBus)

      # Through qualify/2: judged from the durable packages on disk, not memory.
      assert %Verdict{verdict: :mutant_killed} =
               verdict =
               Mutation.qualify(mutation,
                 courts: [ChicagoSelfTest.ReplayCourt],
                 evidence_dir: Path.join(dir, "qualify")
               )

      assert verdict.court_verdicts == %{"CHI-SELFTEST-REPLAY" => :killed}
      assert "CHI-SELFTEST-REPLAY-001" in verdict.killed_by

      mutant_results =
        Path.join(verdict.mutant.dir, "results.json") |> File.read!() |> JSON.decode!()

      assert %{"verdict" => "FALSIFIER_SURVIVED"} =
               Enum.find(mutant_results, &(&1["falsifier_id"] == "CHI-SELFTEST-REPLAY-001"))

      assert Mutation.pristine?(CommandBus)

      # Restore is real (Mutation.with_mutant always restores, even here where
      # the mutant ran only inside qualify/2's own with_mutant call): a fresh
      # run against the pristine module is killed again, not left degraded.
      assert {:ok, restored_run} =
               Runner.run(
                 profile: :core,
                 courts: [ChicagoSelfTest.ReplayCourt],
                 evidence_dir: Path.join(dir, "direct-restored")
               )

      restored_result =
        Enum.find(restored_run.results, &(&1.falsifier_id == "CHI-SELFTEST-REPLAY-001"))

      assert restored_result.verdict == :falsifier_killed
      assert restored_result.ocel_corroborated? == true
    end
  end

  describe "SA2A-MUTATION court end to end" do
    # Every resolved killer court (SA2A-AUTH, SA2A-ENV, SA2A-SHACL, CHI-ID, ...)
    # runs once as a baseline and once per mutant under the real Runner.
    @tag timeout: 1_800_000
    test "every falsifier's verdict, corroborated by the independent OCEL consumer", %{
      tmp_dir: dir
    } do
      assert {:ok, run} = Runner.run(courts: [MutationCourt], profile: :strict, evidence_dir: dir)

      by_id = Map.new(run.results, &{&1.falsifier_id, &1})

      assert Enum.sort(Map.keys(by_id)) ==
               Enum.sort(Enum.map(MutationCourt.falsifiers(), & &1.id))

      resolution = Map.new(Catalog.resolution(), &{&1.id, &1})

      expected_kills = %{
        "authority_check_true" =>
          ~w(CHI-MUTGUARD-001 CHI-MUTGUARD-002 CHI-MUTGUARD-003 CHI-MUTGUARD-004 CHI-MUTGUARD-006),
        "authority_admits_true" => ~w(CHI-MUTGUARD-002 CHI-MUTGUARD-003),
        "ignore_expiry" => ~w(CHI-MUTGUARD-003),
        "ignore_revocation" => ~w(CHI-MUTGUARD-004),
        # Without a prepared anchor the sole-DO dispatcher (CHI-BRCE Gate 7)
        # refuses actuation, so the granted-commit control (009) fails too.
        "remove_receipt_preparation" => ~w(CHI-MUTGUARD-005 CHI-MUTGUARD-008 CHI-MUTGUARD-009),
        "caller_controlled_consequence" => ~w(CHI-MUTGUARD-006),
        "replay_calls_actuator" => ~w(CHI-MUTGUARD-007 CHI-MUTGUARD-010)
      }

      for {fid, m} <- Catalog.numbered() do
        result = Map.fetch!(by_id, fid)
        entry = resolution[m.id]

        cond do
          Map.has_key?(expected_kills, m.id) ->
            assert result.verdict == :falsifier_killed, "#{fid} #{m.id}: #{inspect(result)}"
            assert result.ocel_corroborated? == true, "#{fid}: #{result.ocel_detail}"
            assert result.evidence["verdict"] == "mutant_killed"
            assert result.evidence["court_verdicts"]["CHI-MUTGUARD"] == "killed"

            mutguard_kills =
              Enum.filter(result.evidence["killed_by"], &String.starts_with?(&1, "CHI-MUTGUARD-"))

            assert mutguard_kills == expected_kills[m.id],
                   "#{m.id} killed by #{inspect(mutguard_kills)}"

            assert result.evidence["mutant_calls"] > 0
            assert result.evidence["restored"]["pristine"] == true

          entry.target_status.status == :blocked ->
            assert result.verdict == :blocked
            assert result.detail =~ to_string(entry.target_status.code)

          entry.killers.resolved == [] ->
            assert result.verdict == :blocked, "#{fid} #{m.id}: #{inspect(result)}"
            assert result.detail =~ "mutation_killer_courts_missing"

          true ->
            # A killer court landed from another slice: it must not be vacuous.
            assert result.verdict == :falsifier_killed, "#{fid} #{m.id}: #{inspect(result)}"
            assert result.ocel_corroborated? == true
        end
      end

      assert resolution["root_manifest_component_drift"].target_status.status == :resolvable

      equivalent = by_id["SA2A-MUTATION-101"]
      assert equivalent.verdict == :positive_control_passed, inspect(equivalent)
      assert equivalent.ocel_corroborated? == true, equivalent.ocel_detail
      assert equivalent.evidence["verdict"] == "mutant_survived"

      exit_safety = by_id["SA2A-MUTATION-102"]
      assert exit_safety.verdict == :falsifier_killed, inspect(exit_safety)
      assert exit_safety.ocel_corroborated? == true, exit_safety.ocel_detail

      protected = by_id["SA2A-MUTATION-103"]
      assert protected.verdict == :falsifier_killed, inspect(protected)
      assert protected.ocel_corroborated? == true, protected.ocel_detail

      for r <- run.results, AshA2A.Chicago.Result.passing_verdict?(r) do
        assert r.ocel_corroborated? == true, "#{r.falsifier_id}: #{r.ocel_detail}"
      end

      receipt = JSON.decode!(File.read!(Path.join(dir, "standing_receipt.json")))
      assert :ok = AshA2A.Chicago.StandingReceipt.verify_digest(receipt)
      assert receipt["results"]["falsifiers_survived"] == 0
      assert receipt["results"]["positive_controls_failed"] == 0
      assert "SA2A-MUTATION" in Enum.map(receipt["court"]["courts"], & &1["id"])

      # The independent consumer reads the mutation evidence from disk.
      {:ok, index} = AshA2A.Chicago.Query.load(Path.join(dir, "ocel.json"), run.ocel.sha256)

      assert {true, _} =
               AshA2A.Chicago.Query.eval(
                 index,
                 "SA2A-MUTATION-001",
                 {:observed, "chicago.mutation.verdict", %{"verdict" => "mutant_killed"}}
               )

      for module <- @touched, do: assert(Mutation.pristine?(module))
    end

    test "the reference court is clean on the unmutated subject", %{tmp_dir: dir} do
      assert {:ok, run} = Runner.run(courts: [GuardCourt], profile: :core, evidence_dir: dir)

      for r <- run.results do
        assert r.verdict in [:falsifier_killed, :positive_control_passed], inspect(r)
        assert r.ocel_corroborated? == true, "#{r.falsifier_id}: #{r.ocel_detail}"
      end

      assert length(run.results) == 10
      refute GuardCourt in AshA2A.Chicago.courts()
      assert MutationCourt in AshA2A.Chicago.courts()
    end
  end
end
