defmodule AshA2A.Chicago.FreshConsumerTest do
  @moduledoc """
  Gate 11 fresh-consumer qualification (RFC-SA2A-002 §42, §74, §19, §139),
  Chicago style: real producer courts over the real CommandBus, real durable
  packages on disk, a real fresh `elixir` OS process as the consumer, real
  file mutations as fault injection, and the independent OCEL consumer
  corroborating every verdict.

  `async: false` -- the observer attributes telemetry emitted between a
  stimulus start and stop to that falsifier.
  """

  use ExUnit.Case, async: false

  @moduletag :serial
  @moduletag :serial_shard
  import ExUnit.CaptureIO

  alias AshA2A.Chicago.{FreshConsumer, Result, Runner, StandingReceipt, Subject}
  alias AshA2A.Chicago.Courts.FreshConsumer, as: Court
  alias AshA2A.Chicago.Fixtures.FreshConsumer, as: F

  @moduletag :tmp_dir
  @moduletag timeout: 1_200_000

  describe "CHI-FRESH court, end to end" do
    test "every falsifier reaches its verdict and every pass is OCEL-corroborated", %{
      tmp_dir: dir
    } do
      assert {:ok, run} = Runner.run(courts: [Court], profile: :do, evidence_dir: dir)
      by_id = Map.new(run.results, &{&1.falsifier_id, &1})

      assert Enum.sort(Map.keys(by_id)) ==
               ~w(CHI-FRESH-001 CHI-FRESH-002 CHI-FRESH-003 CHI-FRESH-004 CHI-FRESH-005 CHI-FRESH-006)

      assert by_id["CHI-FRESH-001"].verdict == :positive_control_passed,
             inspect(by_id["CHI-FRESH-001"], pretty: true, limit: :infinity)

      for id <- ~w(CHI-FRESH-002 CHI-FRESH-003 CHI-FRESH-004 CHI-FRESH-005 CHI-FRESH-006) do
        assert by_id[id].verdict == :falsifier_killed,
               "#{id}: " <> inspect(by_id[id], pretty: true, limit: :infinity)
      end

      for result <- run.results do
        assert result.ocel_corroborated? == true, "#{result.falsifier_id}: #{result.ocel_detail}"
        assert Result.counts_as_pass?(result)
      end

      positive = by_id["CHI-FRESH-001"].evidence
      assert positive["outcome"] == "reproduced"
      assert positive["producer_observer_handlers_after_kill"] == 0
      assert positive["independent_reader_allowed_present"] == true
      assert positive["independent_reader_denied_absent"] == true
      assert positive["question_status"]["replayable_without_do"] == "ANSWERED"
      assert positive["question_status"]["plan"] == "UNKNOWN"

      # The fresh OS process is the load-bearing guard: in the producer VM,
      # where the hidden state still lives, the same package reproduces.
      hidden = by_id["CHI-FRESH-002"].evidence
      assert hidden["in_process_outcome"] == "reproduced"
      assert hidden["verdict"]["outcome"] == "diverged"
      assert "falsifier_corpus_digest_mismatch" in hidden["verdict"]["reasons"]

      deleted = by_id["CHI-FRESH-003"].evidence

      for file <- FreshConsumer.package_files() do
        assert deleted[file]["outcome"] == "refused"
        assert ("package_file_missing:" <> file) in deleted[file]["reasons"]
      end

      assert by_id["CHI-FRESH-005"].evidence["untampered_misaimed_control_outcome"] ==
               "reproduced"

      forged = by_id["CHI-FRESH-006"].evidence["forged"]
      assert forged["forged_digests_hold"] == true
      assert forged["reasons"] == ["ocel_run_mismatch"]

      assert Enum.find(run.receipt["gates"], &(&1["gate"] == 11))["status"] == "PASSED"
      assert run.receipt["evidence"]["fresh_consumer"] == "PASS"
      assert run.receipt["results"]["survived_ids"] == []

      # Self-application: this court's own qualification package reproduces
      # in a fresh consumer, and the verdict is observable at the boundary.
      :ok = attach(self())
      assert {:ok, verdict} = FreshConsumer.verify(dir)
      detach(self())
      assert verdict["outcome"] == "reproduced", inspect(verdict["checks"], pretty: true)
      assert verdict["standing"]["reconstructed"] == run.receipt["standing"]
      assert_received {:verified, %{outcome: :reproduced, fresh_process: true}}
    end
  end

  describe "StandingReceipt.recompute/1" do
    test "reproduces exactly what build/1 issued for a real run", %{tmp_dir: dir} do
      {:ok, run} = Runner.run(courts: [F.ProducerCourt], profile: :core, evidence_dir: dir)

      computed =
        StandingReceipt.recompute(%{
          profile: :core,
          courts: [%{id: F.ProducerCourt.id(), gate: F.ProducerCourt.gate()}],
          results: run.results,
          ocel_validation_status: run.ocel_validation.status,
          ocel_dropped: run.ocel.dropped,
          source_revision: run.subject.source_revision,
          court_revision: run.receipt["court"]["revision"]
        })

      assert computed.tallies == run.receipt["results"]
      assert computed.gate_rows == run.receipt["gates"]
      assert AshA2A.Chicago.FailureClass.wire(computed.standing) == run.receipt["standing"]
      assert computed.claim == run.receipt["claim"]
      assert computed.gate_evidence["fresh_consumer"] == run.receipt["evidence"]["fresh_consumer"]
      assert run.receipt["standing"] == "PARTIAL_ALIVE"
    end

    # Merge reconciliation with CHI-ID (§32): build/1 can issue REFUSED for a
    # claimed subject that does not verify, so recompute/1 -- and therefore a
    # fresh consumer -- must reproduce that standing, not re-derive one the
    # producer never issued.
    test "reproduces a §32 REFUSED standing; dropping the verification does not", %{
      tmp_dir: dir
    } do
      pkg = Path.join(dir, "refused")

      stale_claim =
        Subject.capture() |> Subject.to_map() |> Map.put("identity", String.duplicate("0", 64))

      {:ok, run} =
        Runner.run(
          courts: [F.ProducerCourt],
          profile: :core,
          claimed_subject: stale_claim,
          evidence_dir: pkg
        )

      assert run.receipt["standing"] == "REFUSED"
      assert run.receipt["subject"]["verification"]["outcome"] == "mismatch"

      facts = %{
        profile: :core,
        courts: [%{id: F.ProducerCourt.id(), gate: F.ProducerCourt.gate()}],
        results: run.results,
        ocel_validation_status: run.ocel_validation.status,
        ocel_dropped: run.ocel.dropped,
        ocel_gaps: run.receipt["evidence"]["ocel_gaps"],
        source_revision: run.subject.source_revision,
        court_revision: run.receipt["court"]["revision"]
      }

      verification =
        StandingReceipt.verification_from_map(run.receipt["subject"]["verification"])

      assert {:mismatch, nil, ["claimed_subject"]} = verification

      computed = StandingReceipt.recompute(Map.put(facts, :subject_verification, verification))

      assert AshA2A.Chicago.FailureClass.wire(computed.standing) == "REFUSED"
      assert computed.claim == run.receipt["claim"]
      assert computed.tallies == run.receipt["results"]
      assert computed.gate_rows == run.receipt["gates"]

      unverified = StandingReceipt.recompute(facts)
      refute AshA2A.Chicago.FailureClass.wire(unverified.standing) == "REFUSED"
      refute unverified.claim == run.receipt["claim"]

      verdict = FreshConsumer.verify_package(pkg)
      assert verdict["outcome"] == "reproduced", inspect(verdict["checks"], pretty: true)
      assert verdict["standing"]["recorded"] == "REFUSED"
      assert verdict["standing"]["reconstructed"] == "REFUSED"
    end

    test "a malformed receipt verification decodes fail-closed to :not_claimed" do
      assert StandingReceipt.verification_from_map(nil) == :not_claimed
      assert StandingReceipt.verification_from_map(%{"outcome" => "not_claimed"}) == :not_claimed

      assert StandingReceipt.verification_from_map(%{
               "outcome" => "mismatch",
               "claimed_identity" => 5,
               "fields" => ["tag"]
             }) == :not_claimed

      assert StandingReceipt.verification_from_map(%{
               "outcome" => "mismatch",
               "claimed_identity" => "abc",
               "fields" => [1]
             }) == :not_claimed

      assert StandingReceipt.verification_from_map(%{
               "outcome" => "match",
               "claimed_identity" => "abc",
               "fields" => []
             }) == {:match, "abc"}
    end
  end

  describe "FreshConsumer.verify_package/1 (pure, in-process)" do
    setup %{tmp_dir: dir} do
      pkg = Path.join(dir, "pkg")
      {:ok, run} = Runner.run(courts: [F.ProducerCourt], profile: :core, evidence_dir: pkg)
      %{pkg: pkg, run: run}
    end

    test "an intact package reproduces and answers the §74 questions from disk", %{
      pkg: pkg,
      run: run
    } do
      verdict = FreshConsumer.verify_package(pkg)

      assert verdict["outcome"] == "reproduced", inspect(verdict["checks"], pretty: true)
      assert verdict["reasons"] == []
      assert verdict["package"]["run_id"] == run.run_id
      assert verdict["standing"]["reconstructed"] == "PARTIAL_ALIVE"

      q = verdict["questions"]
      assert q["semantic_object"]["status"] == "ANSWERED"
      assert q["semantic_object"]["answer"]["capabilities"] == ["capability:" <> F.capability()]
      assert [_record] = q["semantic_object"]["answer"]["acted_on"]
      assert q["prepared_before_actuation"]["answer"] == true
      assert q["plan"]["status"] == "UNKNOWN"
      assert q["authority_grant"]["status"] == "UNKNOWN"
      assert q["independent_consequence"]["status"] == "UNKNOWN"
      # In the producer VM :ash_a2a is started, so DO-free replay is not shown.
      assert q["replayable_without_do"]["status"] == "UNKNOWN"
    end

    test "a missing file is refused with no standing inferred", %{pkg: pkg} do
      File.rm!(Path.join(pkg, "subject.json"))
      verdict = FreshConsumer.verify_package(pkg)

      assert verdict["outcome"] == "refused"
      assert verdict["reasons"] == ["package_file_missing:subject.json"]
      assert verdict["standing"]["reconstructed"] == nil
      assert Enum.all?(verdict["questions"], fn {_q, a} -> a["status"] == "UNKNOWN" end)
    end

    test "a rewritten verdict diverges on the recorded standing", %{pkg: pkg} do
      path = Path.join(pkg, "results.json")

      results =
        path
        |> File.read!()
        |> JSON.decode!()
        |> Enum.map(fn
          %{"verdict" => "POSITIVE_CONTROL_PASSED"} = r ->
            %{r | "verdict" => "POSITIVE_CONTROL_FAILED"}

          r ->
            r
        end)

      File.write!(path, AshA2A.Chicago.Json.canonical(results))
      verdict = FreshConsumer.verify_package(pkg)

      assert verdict["outcome"] == "diverged"
      assert verdict["standing"]["recorded"] == "NONCONFORMANT"
      assert Enum.any?(verdict["reasons"], &(&1 =~ ~r/^recorded_projection_mismatch:.*standing/))
    end

    test "an undecodable verdict is refused", %{pkg: pkg} do
      path = Path.join(pkg, "results.json")

      results =
        path |> File.read!() |> JSON.decode!() |> Enum.map(&Map.put(&1, "verdict", "PASSED"))

      File.write!(path, AshA2A.Chicago.Json.canonical(results))
      verdict = FreshConsumer.verify_package(pkg)

      assert verdict["outcome"] == "refused"
      assert verdict["reasons"] == ["results_undecodable"]
    end

    test "main/1 prints exactly one parseable verdict line", %{pkg: pkg} do
      output = capture_io(fn -> FreshConsumer.main([pkg]) end)
      assert [line] = String.split(output, "\n", trim: true)
      assert "SA2A-FRESH-CONSUMER-VERDICT " <> json = line
      assert %{"outcome" => "reproduced", "schema" => schema} = JSON.decode!(json)
      assert schema == FreshConsumer.schema()

      output = capture_io(fn -> FreshConsumer.main([]) end)
      assert output =~ ~s("outcome":"refused")
    end
  end

  describe "FreshConsumer.verify/2 local acceptance boundary" do
    setup do
      test_pid = self()
      :ok = attach(test_pid)
      on_exit(fn -> detach(test_pid) end)
    end

    test "a genuinely fresh OS process reproduces a package whose producer is dead", %{
      tmp_dir: dir
    } do
      pkg = Path.join(dir, "pkg")
      parent = self()

      producer =
        spawn(fn ->
          send(parent, {:produced, Runner.run(courts: [F.ProducerCourt], evidence_dir: pkg)})
        end)

      assert_receive {:produced, {:ok, _run}}, 120_000
      ref = Process.monitor(producer)
      assert_receive {:DOWN, ^ref, :process, ^producer, _}

      assert {:ok, verdict} = FreshConsumer.verify(pkg, producer: producer)
      assert verdict["outcome"] == "reproduced", inspect(verdict, pretty: true)
      assert verdict["fresh_process_accepted"] == true
      assert verdict["producer_terminated"] == true
      assert verdict["child"]["os_pid"] != nil
      assert verdict["fresh_process"]["os_pid"] != System.pid()
      assert verdict["fresh_process"]["ash_a2a_started"] == false
      assert verdict["fresh_process"]["do_boundary_loaded"] == false
      assert verdict["questions"]["replayable_without_do"]["answer"] == true

      assert_received {:verified,
                       %{outcome: :reproduced, fresh_process: true, producer_terminated: true}}
    end

    test "a consumer that exits without a verdict is refused", %{tmp_dir: dir} do
      assert {:ok, verdict} = FreshConsumer.verify(dir, elixir: System.find_executable("false"))
      assert verdict["outcome"] == "refused"
      assert verdict["reasons"] == ["fresh_consumer_no_verdict"]
      assert_received {:verified, %{outcome: :refused, fresh_process: false}}
    end

    test "a verdict not provably from the spawned fresh process is refused", %{tmp_dir: dir} do
      # A lying consumer executable: claims `reproduced` from the producer's
      # own OS pid with the application started.
      liar = Path.join(dir, "lying_consumer.sh")

      verdict =
        JSON.encode!(%{
          "schema" => FreshConsumer.schema(),
          "outcome" => "reproduced",
          "reasons" => [],
          "fresh_process" => %{"os_pid" => System.pid(), "ash_a2a_started" => true}
        })

      File.write!(liar, "#!/bin/sh\nprintf '%s\\n' 'SA2A-FRESH-CONSUMER-VERDICT #{verdict}'\n")
      File.chmod!(liar, 0o755)

      assert {:ok, accepted} = FreshConsumer.verify(dir, elixir: liar)
      assert accepted["outcome"] == "refused"
      assert "not_a_fresh_process:producer_os_pid" in accepted["reasons"]
      assert "not_a_fresh_process:os_pid_unbound" in accepted["reasons"]
      assert "not_a_fresh_process:ash_a2a_started" in accepted["reasons"]
      assert_received {:verified, %{outcome: :refused}}
    end
  end

  defp attach(pid) do
    :telemetry.attach(
      {__MODULE__, pid},
      FreshConsumer.event(),
      &__MODULE__.forward_verified/4,
      pid
    )
  end

  defp detach(pid), do: :telemetry.detach({__MODULE__, pid})

  @doc false
  def forward_verified(_event, _measurements, metadata, test_pid),
    do: send(test_pid, {:verified, metadata})
end
