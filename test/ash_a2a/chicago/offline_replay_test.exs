defmodule AshA2A.Chicago.OfflineReplayTest do
  @moduledoc """
  Gate 10 offline replay + benchmark B8 qualification (RFC-SA2A-002 §41,
  §92), Chicago style: real consequence-bearing commands through the real
  CommandBus into real durable stores (on-disk EKV + receipt outbox journal),
  real sealed evidence chains on disk, a real fresh `elixir` OS process as the
  replay consumer, real file mutations as fault injection, real ledger rows
  read back through `Ash.read!`, and the independent OCEL consumer
  corroborating every verdict.

  `async: false` -- the observer attributes telemetry emitted between a
  stimulus start and stop to that falsifier, and the environment swaps the
  global receipt outbox directory.
  """

  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  alias AshA2A.Chicago.{Result, Runner}
  alias AshA2A.Chicago.Courts.OfflineReplay, as: Court
  alias AshA2A.Chicago.Fixtures.ChaosReconciliation.Environment
  alias AshA2A.Chicago.Fixtures.Replay, as: Fx
  alias AshA2A.Receipt.{EvidenceChain, OfflineReplay}

  @moduletag :tmp_dir
  @moduletag timeout: 1_200_000

  @ids for n <- 1..9, do: "CHI-REPLAY-00#{n}"

  describe "CHI-REPLAY court, end to end" do
    test "every falsifier reaches its verdict and every pass is OCEL-corroborated", %{
      tmp_dir: dir
    } do
      assert {:ok, run} = Runner.run(courts: [Court], profile: :do, evidence_dir: dir)
      by_id = Map.new(run.results, &{&1.falsifier_id, &1})

      assert Enum.sort(Map.keys(by_id)) == @ids

      assert by_id["CHI-REPLAY-001"].verdict == :positive_control_passed,
             inspect(by_id["CHI-REPLAY-001"], pretty: true, limit: :infinity)

      for id <-
            ~w(CHI-REPLAY-002 CHI-REPLAY-003 CHI-REPLAY-004 CHI-REPLAY-005 CHI-REPLAY-006 CHI-REPLAY-007 CHI-REPLAY-008) do
        assert by_id[id].verdict == :falsifier_killed,
               "#{id}: " <> inspect(by_id[id], pretty: true, limit: :infinity)

        assert Enum.all?(by_id[id].evidence["classes"] || ["detected"], &(&1 == "detected"))
      end

      assert by_id["CHI-REPLAY-009"].verdict == :measured,
             inspect(by_id["CHI-REPLAY-009"], pretty: true, limit: :infinity)

      for result <- run.results do
        assert result.ocel_corroborated? == true, "#{result.falsifier_id}: #{result.ocel_detail}"
        assert Result.counts_as_pass?(result)
      end

      positive = by_id["CHI-REPLAY-001"].evidence
      assert positive["ledger_rows_delta"] == 0
      assert positive["actuation_events_during_replay"] == []
      assert positive["deduplicated_retry_reconstructed"] == true
      assert positive["stages_reconstructed"] == positive["stages_expected"]
      assert positive["stages_expected"] == 3 * 8
      assert positive["fresh"]["process"]["do_boundary_loaded"] == false
      assert positive["fresh"]["process"]["ash_a2a_started"] == false

      # Each mutation was refused by the guard it targets, not by accident.
      expected_checks = %{
        "CHI-REPLAY-002" => %{
          "final_file_deleted" => "links_present",
          "prepared_link_removed_reforged" => "reconstruction_complete"
        },
        "CHI-REPLAY-003" => %{
          "prepared_final_swapped" => "link_chaining",
          "prepared_final_swapped_reforged" => "reconstruction_order",
          "dedup_retry_moved_first_reforged" => "reconstruction_order"
        },
        "CHI-REPLAY-004" => %{
          "final_input_digest_rewritten" => "link_digests",
          "final_input_digest_rewritten_reforged" => "reconstruction_identity"
        },
        "CHI-REPLAY-005" => %{
          "final_grant_rewritten_reforged" => "reconstruction_authority",
          "both_grants_rewritten_reforged" => "reconstruction_authority"
        },
        "CHI-REPLAY-006" => %{
          "real_double_actuation" => "reconstruction_actuation_unique",
          "spliced_segment_reforged" => "reconstruction_actuation_unique"
        },
        "CHI-REPLAY-007" => %{
          "link_root_left" => "link_root",
          "basis_root_left" => "basis_root",
          "both_roots_reforged_anchored" => "anchor_basis_root"
        }
      }

      for {id, mutations} <- expected_checks, {name, check} <- mutations do
        verdict = by_id[id].evidence[name]
        assert verdict["outcome"] == "refused", "#{id}/#{name}: #{inspect(verdict)}"
        assert verdict["fresh_process_accepted"] == true
        assert check in Enum.map(verdict["failed_checks"], & &1["check"]), "#{id}/#{name}"
      end

      assert by_id["CHI-REPLAY-006"].evidence["real_double_actuation_ledger_rows"] == 2

      actuator = by_id["CHI-REPLAY-008"].evidence
      assert actuator["replay"]["outcome"] == "verified"
      assert actuator["actuation_events"] == []
      assert actuator["ledger_rows_delta"] == 0
      assert actuator["redrive_reply"] =~ "authority_required"

      b8 = by_id["CHI-REPLAY-009"].measurements
      assert b8["benchmark"] == "SA2A-B8"
      assert b8["zero_external_consequence"] == true
      assert Enum.map(b8["sizes"], & &1["executed_effects"]) == [2, 8, 32]

      for size <- b8["sizes"] do
        assert size["receipt_chain_length"] == 3 * size["executed_effects"] + 2
        assert size["serialized_evidence_bytes"] > 0
        assert size["replay_verification_us"]["fresh_os_process"] > 0
        assert size["replay_verification_us"]["in_vm"] > 0
        assert size["peak_memory_bytes"]["fresh_vm_total"] > 0
        assert size["peak_memory_bytes"]["in_vm_verifier_process"] > 0
        assert size["fresh_consumer_startup_us"] > 0
        assert size["external_consequence_rows_delta"] == 0
        assert size["actuator_events_during_replay"] == 0
        assert size["fresh_do_boundary_loaded"] == false
      end

      assert Enum.find(run.receipt["gates"], &(&1["gate"] == 10))["status"] == "PASSED"
      assert run.receipt["evidence"]["replay"] == "PASS"
      assert run.receipt["results"]["survived_ids"] == []
    end
  end

  describe "OfflineReplay over a real sealed chain" do
    setup %{tmp_dir: dir} do
      env = Environment.open(Path.join(dir, "env"))
      on_exit(fn -> Environment.close(env) end)
      {:ok, pkg} = Fx.produce(env, Path.join(dir, "chain"))
      %{env: env, pkg: pkg}
    end

    test "an intact chain verifies from disk and reconstructs every stage", %{pkg: pkg} do
      refute Process.alive?(pkg.pid)
      assert pkg.seal["length"] == 8
      assert pkg.seal["reconstruction_failures"] == []

      verdict =
        OfflineReplay.verify_chain(pkg.dir,
          link_root: pkg.seal["link_root"],
          basis_root: pkg.seal["basis_root"]
        )

      assert verdict["outcome"] == "verified", inspect(verdict["checks"], pretty: true)
      assert verdict["chain"]["reconstructed_basis_root"] == pkg.seal["basis_root"]
      assert verdict["chain"]["reconstructed_link_root"] == pkg.seal["link_root"]

      assert [c1, c2, retry] = verdict["reconstruction"]["records"]

      for record <- [c1, c2, retry], stage <- OfflineReplay.stages() do
        assert record[stage] != nil, "#{record["command_id"]} lacks #{stage}"
      end

      assert c1["prepared_receipt"]["status"] == "pending"
      assert c1["final_receipt"]["terminal_status"] == "executed"
      assert c1["final_receipt"]["actuated_by_replay"] == false
      assert c1["authority_decision"]["decision"] == "admitted"
      assert c1["observed_post_state"]["rows"] == 1
      assert c2["intended_effect"]["actuation_id"] != c1["intended_effect"]["actuation_id"]

      assert retry["prepared_receipt"]["reason"] == "deduplicated"
      assert retry["intended_effect"]["actuation_id"] == c1["intended_effect"]["actuation_id"]
      assert retry["observed_post_state"]["rows"] == 1
    end

    test "a verdict is refused with the targeted reason, and no reconstruction on bad bytes", %{
      pkg: pkg,
      tmp_dir: dir
    } do
      deleted = Fx.copy_chain(pkg, dir, "deleted")
      Fx.delete_file!(deleted, Fx.link(Fx.manifest(deleted), 1, "prepared"))
      verdict = OfflineReplay.verify_chain(deleted)
      assert verdict["outcome"] == "refused"
      assert verdict["reasons"] == ["replay_receipt_missing"]
      assert verdict["reconstruction"] == nil

      wrong_anchor = OfflineReplay.verify_chain(pkg.dir, basis_root: String.duplicate("a", 64))
      assert wrong_anchor["reasons"] == ["replay_root_divergence"]

      no_manifest = Fx.copy_chain(pkg, dir, "no-manifest")
      File.rm!(Path.join(no_manifest, EvidenceChain.manifest_file()))
      assert OfflineReplay.verify_chain(no_manifest)["reasons"] == ["replay_manifest_invalid"]
    end

    test "replay/2 runs in the SUT VM, emits its decision, and never actuates", %{pkg: pkg} do
      test_pid = self()
      handler = {__MODULE__, test_pid}

      :ok =
        :telemetry.attach_many(
          handler,
          [
            OfflineReplay.event(),
            [:ash_a2a, :command_bus, :actuate, :start],
            [:ash_a2a, :dispatch, :start]
          ],
          &__MODULE__.forward/4,
          test_pid
        )

      try do
        before = Fx.rows(pkg.operations)
        assert {:ok, verdict} = OfflineReplay.replay(pkg.dir, producer: pkg.pid)
        assert verdict["outcome"] == "verified"
        assert verdict["mode"] == "in_vm"
        assert verdict["measurements"]["peak_verifier_bytes"] > 0
        assert Fx.rows(pkg.operations) == before

        assert_received {:telemetry, [:ash_a2a, :replay, :verified],
                         %{outcome: :verified, mode: :in_vm, producer_terminated: true}}

        refute_received {:telemetry, [:ash_a2a, :command_bus, :actuate, :start], _}
        refute_received {:telemetry, [:ash_a2a, :dispatch, :start], _}
      after
        :telemetry.detach(handler)
      end
    end

    test "verify_fresh/2 accepts only a verdict from a fresh OS process", %{
      pkg: pkg,
      tmp_dir: dir
    } do
      assert {:ok, verdict} = OfflineReplay.verify_fresh(pkg.dir, producer: pkg.pid)
      assert verdict["outcome"] == "verified", inspect(verdict, pretty: true)
      assert verdict["fresh_process_accepted"] == true
      assert verdict["process"]["os_pid"] != System.pid()
      assert verdict["process"]["ash_a2a_started"] == false
      assert verdict["process"]["do_boundary_loaded"] == false
      assert verdict["measurements"]["startup_us"] > 0

      liar = Path.join(dir, "lying_replay.sh")

      lie =
        JSON.encode!(%{
          "schema" => OfflineReplay.schema(),
          "outcome" => "verified",
          "reasons" => [],
          "process" => %{
            "os_pid" => System.pid(),
            "ash_a2a_started" => true,
            "do_boundary_loaded" => true
          }
        })

      File.write!(liar, "#!/bin/sh\nprintf '%s\\n' 'SA2A-OFFLINE-REPLAY-VERDICT #{lie}'\n")
      File.chmod!(liar, 0o755)

      assert {:ok, refused} = OfflineReplay.verify_fresh(pkg.dir, elixir: liar)
      assert refused["outcome"] == "refused"
      assert "replay_process_not_fresh:producer_os_pid" in refused["reasons"]
      assert "replay_process_not_fresh:os_pid_unbound" in refused["reasons"]
      assert "replay_process_not_fresh:ash_a2a_started" in refused["reasons"]
      assert "replay_consequence_boundary_loaded" in refused["reasons"]

      assert {:ok, silent} =
               OfflineReplay.verify_fresh(pkg.dir, elixir: System.find_executable("false"))

      assert silent["reasons"] == ["replay_crashed:no_verdict"]
    end

    test "main/1 prints exactly one parseable verdict line", %{pkg: pkg} do
      output = capture_io(fn -> OfflineReplay.main([pkg.dir, "-", "-"]) end)
      assert [line] = String.split(output, "\n", trim: true)
      assert "SA2A-OFFLINE-REPLAY-VERDICT " <> json = line
      assert %{"outcome" => "verified", "schema" => schema} = JSON.decode!(json)
      assert schema == OfflineReplay.schema()

      assert capture_io(fn -> OfflineReplay.main([]) end) =~ ~s("outcome":"refused")
    end
  end

  # Defect D1 guard (found by CHI-REPLAY-001): replay basis digests must not
  # depend on the verifying VM's atom table. Two fresh VMs create the same
  # atoms in opposite orders; plain term_to_binary/1 disagrees between them,
  # AshA2A.Actuation.digest/1 must not.
  test "Actuation.digest/1 is independent of the VM atom table" do
    paths = Path.wildcard(Path.join(Mix.Project.build_path(), "lib/*/ebin"))

    run = fn order ->
      script = """
      keys = Enum.map(#{inspect(order)}, &String.to_atom/1)
      term = %{basis: Map.new(keys, &{&1, Atom.to_string(&1)})}
      plain = :crypto.hash(:sha256, :erlang.term_to_binary(term)) |> Base.encode16(case: :lower)
      IO.puts(plain <> " " <> AshA2A.Actuation.digest(term))
      """

      {out, 0} = System.cmd("elixir", Enum.flat_map(paths, &["-pa", &1]) ++ ["-e", script])
      out |> String.trim() |> String.split(" ")
    end

    [plain_a, digest_a] = run.(["replay_guard_zeta", "replay_guard_alpha"])
    [plain_b, digest_b] = run.(["replay_guard_alpha", "replay_guard_zeta"])

    assert plain_a != plain_b
    assert digest_a == digest_b
  end

  test "every replay refusal code is classified" do
    for {code, class} <- OfflineReplay.__sa2a_refusal_codes__() do
      assert AshA2A.Semantic.Refusal.classify(code) == class
    end
  end

  @doc false
  def forward(event, _measurements, metadata, test_pid),
    do: send(test_pid, {:telemetry, event, metadata})
end
