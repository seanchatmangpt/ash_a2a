defmodule AshA2A.Chicago.Courts.OfflineReplay do
  @moduledoc """
  Gate 10 -- Offline Replay, and Benchmark B8 (RFC-SA2A-002 §41, §92; §84,
  §100).

  Every chain this court replays is a real `AshA2A.Receipt.EvidenceChain`
  produced by `AshA2A.Chicago.Fixtures.Replay.produce/3`: real
  consequence-bearing commands through the real `AshA2A.CommandBus`, real
  durable stores (on-disk EKV primary store + receipt outbox journal of a
  `ChaosReconciliation.Environment`), real ledger rows read back through
  `Ash.read!`, sealed by a producer process the fixture kills before any
  replay runs.

  The boundary that decides is `AshA2A.Receipt.OfflineReplay`:

    * `verify_fresh/2` -- verification in a genuinely fresh `elixir` OS
      process with no producer memory, whose verdict is accepted only when it
      provably came from that process with `:ash_a2a` unstarted and no DO
      boundary module loaded;
    * `replay/2` -- the same verification inside the SUT VM (a newly spawned
      process), where the real actuator IS reachable, so an actuating replay
      path would be observable at `brce.actuate.*` / `dispatch.*`.

  Both emit `[:ash_a2a, :replay, :verified]` (OCEL activity
  `replay.verified`) for every decision, verified or refused; the producer's
  seal emits `[:ash_a2a, :replay, :chain_sealed]` (`replay.chain_sealed`).

  Mutations are environment fault injection on real chain files (§10); the
  re-forged variants model a forger with write access who recomputes digests,
  link chaining and roots with the engine's own public functions, so the
  semantic guard -- not the byte digest -- is what must decide.
  """

  use AshA2A.Chicago.Court

  alias AshA2A.{Command, CommandBus}
  alias AshA2A.Chicago.{Context, Falsifier, Result}
  alias AshA2A.Chicago.Courts.Brce
  alias AshA2A.Chicago.Fixtures.ChaosReconciliation.{Effect, Environment}
  alias AshA2A.Chicago.Fixtures.Replay, as: Fx
  alias AshA2A.Chicago.Ocel.Mapping
  alias AshA2A.Receipt.{EvidenceChain, OfflineReplay, Replay}
  alias AshA2A.ReceiptStore.Ekv

  @id "CHI-REPLAY"
  @verified "replay.verified"
  @sealed "replay.chain_sealed"
  @actuations [
    "brce.actuate.start",
    "brce.actuate.stop",
    "dispatch.start",
    "dispatch.stop",
    "dispatch.exception",
    "dispatch.actuate"
  ]
  @benchmark_sizes [2, 8, 32]

  @impl true
  def id, do: @id
  @impl true
  def title, do: "Offline replay without consequence, and benchmark B8"
  @impl true
  def gate, do: 10
  @impl true
  def profile, do: :do
  @impl true
  def rfc_sections, do: ["§12", "§41", "§84", "§92", "§100"]

  @impl true
  def ocel_mappings do
    [
      Mapping.new!(
        event: OfflineReplay.event(),
        activity: @verified,
        source: __MODULE__,
        objects: fn _m, meta ->
          [
            {"evidence_chain", meta[:chain_ref], "chain"},
            {"replay_process", meta[:child_os_pid] && "os-pid-#{meta[:child_os_pid]}", "verifier"}
          ]
        end,
        attributes: fn m, meta ->
          meta
          |> Map.take([
            :outcome,
            :mode,
            :reasons,
            :chain_id,
            :length,
            :evidence_bytes,
            :commands,
            :stages_reconstructed,
            :stages_expected,
            :anchored,
            :fresh_process,
            :do_boundary_loaded,
            :producer_terminated
          ])
          |> Map.merge(Map.take(m, [:verify_us, :startup_us, :total_us, :peak_memory_bytes]))
        end
      ),
      Mapping.new!(
        event: EvidenceChain.sealed_event(),
        activity: @sealed,
        source: __MODULE__,
        objects: fn _m, meta -> [{"evidence_chain", meta[:chain_ref], "chain"}] end,
        attributes: fn _m, meta ->
          Map.take(meta, [:chain_id, :length, :commands, :evidence_bytes, :link_root, :basis_root])
        end
      )
    ] ++
      Enum.filter(
        Brce.ocel_mappings(),
        &(&1.activity in ["dispatch.brce_gate", "dispatch.actuate"])
      )
  end

  # --- falsifier declarations (§11) ---------------------------------------------

  @impl true
  def falsifiers do
    fresh = {:not_observed, @verified, %{"fresh_process" => "false"}}

    negative = fn fields ->
      Falsifier.new!(
        Keyword.merge(
          [
            court_id: @id,
            kind: :negative,
            boundary:
              "AshA2A.Receipt.OfflineReplay.verify_fresh/2 (fresh OS process running verify_chain/2; local acceptance of its verdict)",
            forbidden_outcome: "the replay engine verifies the chain",
            survival_evidence: "replay.verified with outcome=verified for a mutated chain",
            failure_class: :replay_failure,
            outcome_predicate: {:observed, @verified, %{"outcome" => "verified"}},
            rfc_sections: ["§41"]
          ],
          fields
        )
      )
    end

    [
      Falsifier.new!(
        id: "CHI-REPLAY-001",
        court_id: @id,
        kind: :positive_control,
        invariant:
          "An intact durable evidence chain replays -- all eight stages reconstructed, both roots matching the producer's seal -- with zero external consequence, in a fresh OS process and in the SUT VM (§41, §100)",
        stimulus:
          "Copy of a sealed real chain (2 executed effects + 1 real deduplicated retry; producer killed); OfflineReplay.replay/2 in the SUT VM and OfflineReplay.verify_fresh/2, both anchored to the seal",
        boundary: "AshA2A.Receipt.OfflineReplay.replay/2 and verify_fresh/2",
        attempt_evidence: "replay.verified for this stimulus",
        survival_evidence:
          "replay.verified outcome=verified in_vm and fresh_os_process (fresh_process, producer_terminated, no DO boundary loaded); no brce.actuate.* / dispatch.* in the stimulus; ledger rows unchanged by an independent Ash.read!",
        attempt_predicate: {:observed, @verified},
        outcome_predicate:
          {:all,
           [
             {:observed, @verified,
              %{"outcome" => "verified", "mode" => "in_vm", "anchored" => "true"}},
             {:observed, @verified,
              %{
                "outcome" => "verified",
                "mode" => "fresh_os_process",
                "fresh_process" => "true",
                "do_boundary_loaded" => "false",
                "producer_terminated" => "true",
                "anchored" => "true"
              }},
             {:not_observed, @verified, %{"outcome" => "refused"}}
             | Enum.map(@actuations, &{:not_observed, &1})
           ] ++ [{:run_scope, {:precedes, @sealed, @verified}}]},
        rfc_sections: ["§41", "§100"]
      ),
      negative.(
        id: "CHI-REPLAY-002",
        invariant: "A chain missing a receipt must not verify (§41 missing receipt)",
        stimulus:
          "(a) chain copy with the final-receipt file of command 2 deleted; (b) chain copy with the prepared anchor of command 2 removed and the chain re-forged; verify_fresh/2 on each",
        attempt_evidence: "two replay.verified decisions from accepted fresh OS processes",
        guard:
          "OfflineReplay.verify_chain/2 links_present integrity check and reconstruct/1 completeness (prepared anchor required for a consequence that crossed DO)",
        attempt_predicate: {:all, [{:count, @verified, :gte, 2}, fresh]}
      ),
      negative.(
        id: "CHI-REPLAY-003",
        invariant: "A chain whose receipts are reordered must not verify (§41 reordered receipt)",
        stimulus:
          "(a) prepared/final links of command 2 swapped; (b) the same swap re-forged; (c) the deduplicated retry's links moved before the receipt it deduplicated, re-forged; verify_fresh/2 on each",
        attempt_evidence: "three replay.verified decisions from accepted fresh OS processes",
        guard:
          "OfflineReplay.verify_chain/2 link chaining (seq/prev/digest) and reconstruct/1 stage order, logical-clock order and deduplication-reference order",
        attempt_predicate: {:all, [{:count, @verified, :gte, 3}, fresh]}
      ),
      negative.(
        id: "CHI-REPLAY-004",
        invariant: "A chain whose digests changed must not verify (§41 changed digest)",
        stimulus:
          "(a) command 2's final receipt rewritten with a different input_digest, manifest untouched; (b) the same rewrite with the chain re-forged; verify_fresh/2 on each",
        attempt_evidence: "two replay.verified decisions from accepted fresh OS processes",
        guard:
          "OfflineReplay.verify_chain/2 link content digest check and reconstruct/1 prepared->final identity binding",
        attempt_predicate: {:all, [{:count, @verified, :gte, 2}, fresh]}
      ),
      negative.(
        id: "CHI-REPLAY-005",
        invariant:
          "A chain whose authority identity changed must not verify (§41 changed authority identity; §65)",
        stimulus:
          "(a) command 1's final receipt grant rewritten to a foreign subject/token, re-forged; (b) both its prepared and final grants rewritten coherently to the foreign subject, re-forged; verify_fresh/2 on each",
        attempt_evidence: "two replay.verified decisions from accepted fresh OS processes",
        guard:
          "OfflineReplay.reconstruct/1 authority checks (prepared/final grant equality; grant subject and capability bound to the receipt's actor and capability)",
        failure_class: :authority_failure,
        attempt_predicate: {:all, [{:count, @verified, :gte, 2}, fresh]}
      ),
      negative.(
        id: "CHI-REPLAY-006",
        invariant:
          "A chain in which an actuation identity crossed the consequence boundary twice, or a replayed receipt segment, must not verify (§41 duplicate/replayed actuation identity; §71)",
        stimulus:
          "(a) a real chain whose declared-idempotent effect the real CommandBus actuated twice (retry run with actuation_dedup: :off; two ledger rows); (b) a copy of the base chain with command 1's links spliced in again, re-forged; verify_fresh/2 on each",
        attempt_evidence: "two replay.verified decisions from accepted fresh OS processes",
        guard:
          "OfflineReplay.reconstruct/1 actuation uniqueness (declared actuation identity, command and receipt identity each cross the boundary at most once)",
        failure_class: :actuation_failure,
        attempt_predicate: {:all, [{:count, @verified, :gte, 2}, fresh]}
      ),
      negative.(
        id: "CHI-REPLAY-007",
        invariant:
          "A chain whose reconstructed root diverges from its recorded or anchored root must not verify (§41 divergent reconstructed root)",
        stimulus:
          "Command 2's post-state observation rewritten (rows 1 -> 3) and (a) link digests re-forged, link root left; (b) link root re-forged, basis root left; (c) both roots re-forged, verified against the producer seal's basis root; verify_fresh/2 on each",
        attempt_evidence: "three replay.verified decisions from accepted fresh OS processes",
        guard:
          "OfflineReplay.verify_chain/2 link_root, basis_root and anchor root checks over the recomputed chain and reconstruction",
        attempt_predicate: {:all, [{:count, @verified, :gte, 3}, fresh]}
      ),
      negative.(
        id: "CHI-REPLAY-008",
        invariant:
          "Replaying evidence is not authority to re-actuate: no replay path calls the actuator (§41; RFC-SA2A-001 S32)",
        stimulus:
          "OfflineReplay.replay/2 of the intact chain inside the SUT VM (actuator reachable), then its replayed authority record and intended effect driven back into the real CommandBus for command 1's operation",
        boundary:
          "AshA2A.Receipt.OfflineReplay.replay/2 (no actuation path) + AshA2A.CommandBus admission of a replayed AuthorityRecord",
        forbidden_outcome:
          "any brce.actuate.* or dispatch.* during the stimulus, or a new ledger row",
        attempt_evidence:
          "replay.verified (in_vm, verified) and the brce.admission decision for the re-drive",
        survival_evidence:
          "brce.actuate.start/stop or dispatch.start/stop/exception/actuate attributed to the stimulus; ledger row count increased",
        guard:
          "OfflineReplay has no DO path; Receipt.Replay.AuthorityRecord is not an AshA2A.Authority, so CommandBus.admit/2 refuses it",
        failure_class: :actuation_failure,
        attempt_predicate:
          {:all,
           [
             {:observed, @verified, %{"mode" => "in_vm", "outcome" => "verified"}},
             {:observed, "brce.admission"}
           ]},
        outcome_predicate: {:any, Enum.map(@actuations, &{:observed, &1})}
      ),
      Falsifier.new!(
        id: "CHI-REPLAY-009",
        court_id: @id,
        kind: :measurement,
        invariant:
          "SA2A-B8 (§92): receipt-chain length, serialized evidence size, replay verification time, peak memory and fresh-consumer startup time, with zero external consequence (§84)",
        stimulus:
          "Real chains of #{Enum.join(@benchmark_sizes, "/")} executed effects (+1 deduplicated retry) produced and sealed by killed producers; each replayed by verify_fresh/2 and replay/2 anchored to its seal; ledger rows read before and after",
        boundary: "AshA2A.Receipt.OfflineReplay.verify_fresh/2 and replay/2",
        attempt_evidence:
          "one replay.chain_sealed per size and replay.verified from an accepted fresh OS process and from the SUT VM",
        survival_evidence:
          "measurements recorded only when every replay verified and the ledger row count did not move",
        attempt_predicate:
          {:all,
           [
             {:count, @sealed, :gte, length(@benchmark_sizes)},
             {:observed, @verified, %{"mode" => "fresh_os_process", "fresh_process" => "true"}},
             {:observed, @verified, %{"mode" => "in_vm"}}
           ]},
        outcome_predicate:
          {:all,
           [
             {:not_observed, @verified, %{"outcome" => "refused"}},
             {:precedes, @sealed, @verified}
           ]},
        rfc_sections: ["§84", "§92"]
      )
    ]
  end

  # --- run ------------------------------------------------------------------------

  @impl true
  def run(%Context{} = ctx) do
    [f1, f2, f3, f4, f5, f6, f7, f8, f9] = falsifiers()
    root = Path.join(ctx.evidence_dir, "offline_replay")
    env = Environment.open(root)

    try do
      {r9, base} =
        case safe(f9, fn -> benchmark(ctx, f9, env, root) end) do
          %Result{} = crashed -> {crashed, nil}
          produced -> produced
        end

      case base do
        %{} ->
          r1 = safe(f1, fn -> positive_control(ctx, f1, base, root) end)
          discriminating? = r1.verdict == :positive_control_passed

          guarded =
            for {f, fun} <- [
                  {f2, &missing_receipt/4},
                  {f3, &reordered/4},
                  {f4, &changed_digest/4},
                  {f5, &changed_authority/4},
                  {f6, &duplicate_actuation(&1, &2, env, &3, &4)},
                  {f7, &divergent_root/4}
                ] do
              if discriminating?,
                do: safe(f, fn -> fun.(ctx, f, base, root) end),
                else:
                  Result.unknown(
                    f,
                    "the unmutated base chain did not replay (#{r1.verdict}); a mutation verdict would not discriminate"
                  )
            end

          [r1 | guarded] ++ [safe(f8, fn -> actuator(ctx, f8, env, base, root) end), r9]

        nil ->
          detail = "no base chain: #{r9.detail}"
          Enum.map([f1, f2, f3, f4, f5, f6, f7, f8], &Result.blocked(&1, detail)) ++ [r9]
      end
    after
      Environment.close(env)
    end
  end

  # A raise inside one falsifier is that falsifier's UNKNOWN, never the court's.
  defp safe(f, fun) do
    fun.()
  rescue
    exception ->
      Result.unknown(
        f,
        "falsifier raised: " <> Exception.format(:error, exception, __STACKTRACE__),
        :ocel_evidence_incomplete
      )
  catch
    kind, reason ->
      Result.unknown(f, "falsifier #{kind}: #{inspect(reason)}", :ocel_evidence_incomplete)
  end

  # --- CHI-REPLAY-009 (B8, runs first: it produces the base chain) -----------------

  defp benchmark(ctx, f, env, root) do
    outcome =
      Context.stimulus(ctx, f, fn ->
        Enum.reduce_while(@benchmark_sizes, {:ok, []}, fn n, {:ok, acc} ->
          dir = Path.join(root, "b8-#{n}-#{System.unique_integer([:positive])}")

          case Fx.produce(env, dir, executed: n) do
            {:ok, pkg} ->
              anchor = anchor(pkg)
              before = Fx.rows(pkg.operations)

              {{fresh, in_vm}, actuator_events} =
                with_actuation_probe(fn ->
                  {:ok, fresh} =
                    OfflineReplay.verify_fresh(pkg.dir, anchor ++ [producer: pkg.pid])

                  {:ok, in_vm} = OfflineReplay.replay(pkg.dir, anchor ++ [producer: pkg.pid])
                  {fresh, in_vm}
                end)

              row = %{
                n: n,
                pkg: pkg,
                fresh: fresh,
                in_vm: in_vm,
                delta: Fx.rows(pkg.operations) - before,
                actuator_events: actuator_events
              }

              {:cont, {:ok, [row | acc]}}

            {:error, reason} ->
              {:halt, {:error, reason}}
          end
        end)
      end)

    case outcome do
      {:ok, rows} ->
        rows = Enum.reverse(rows)
        base = rows |> hd() |> Map.fetch!(:pkg)
        sizes = Enum.map(rows, &size_measurement/1)

        cond do
          Enum.any?(rows, &unavailable?(&1.fresh)) ->
            {Result.blocked(f, "fresh OS process unavailable"), base}

          Enum.any?(rows, fn r ->
            r.fresh["outcome"] != "verified" or r.in_vm["outcome"] != "verified" or r.delta != 0 or
              r.actuator_events != [] or
                get_in(r.fresh, ["process", "do_boundary_loaded"]) != false
          end) ->
            {Result.unknown(
               f,
               "B8 not measurable: a replay did not verify, reached an actuator, loaded a DO boundary, or moved the ledger: #{inspect(sizes)}"
             ), base}

          true ->
            {Result.measured(f,
               attempt_observed?:
                 Context.observed?(ctx, f, @sealed) and Context.observed?(ctx, f, @verified),
               measurements: %{
                 "benchmark" => "SA2A-B8",
                 "zero_external_consequence" => true,
                 "sizes" => sizes,
                 "environment" => environment()
               }
             ), base}
        end

      {:error, reason} ->
        {Result.blocked(f, "evidence chain production failed: #{reason}"), nil}
    end
  end

  # SUT actuation telemetry emitted during `fun` by this process or a process
  # whose caller lineage includes it (the in-VM replay verifier). Counted by an
  # independent handler; the OCEL observer records the same events.
  @probe_events [
    [:ash_a2a, :command_bus, :actuate, :start],
    [:ash_a2a, :command_bus, :actuate, :stop],
    [:ash_a2a, :dispatch, :start],
    [:ash_a2a, :dispatch, :stop],
    [:ash_a2a, :dispatch, :exception],
    [:ash_a2a, :dispatch, :actuate]
  ]

  defp with_actuation_probe(fun) do
    ref = make_ref()
    handler = {__MODULE__, :actuation_probe, ref}

    :ok =
      :telemetry.attach_many(handler, @probe_events, &__MODULE__.probe_event/4, %{
        owner: self(),
        ref: ref
      })

    try do
      result = fun.()
      {result, drain_probe(ref, [])}
    after
      :telemetry.detach(handler)
    end
  end

  @doc false
  def probe_event(event, _measurements, _metadata, %{owner: owner, ref: ref}) do
    if self() == owner or owner in List.wrap(Process.get(:"$callers")),
      do: send(owner, {ref, Enum.map_join(event, ".", &Atom.to_string/1)})
  end

  defp drain_probe(ref, acc) do
    receive do
      {^ref, event} -> drain_probe(ref, [event | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  defp size_measurement(%{n: n, pkg: pkg, fresh: fresh, in_vm: in_vm, delta: delta} = row) do
    fm = fresh["measurements"] || %{}
    vm = in_vm["measurements"] || %{}

    %{
      "executed_effects" => n,
      "commands" => get_in(in_vm, ["reconstruction", "commands"]),
      "receipt_chain_length" => pkg.seal["length"],
      "serialized_evidence_bytes" => pkg.seal["evidence_bytes"],
      "replay_verification_us" => %{
        "fresh_os_process" => fm["verify_us"],
        "in_vm" => vm["verify_us"]
      },
      "peak_memory_bytes" => %{
        "fresh_vm_total" => fm["peak_vm_total_bytes"],
        "fresh_vm_baseline" => fm["baseline_vm_total_bytes"],
        "in_vm_verifier_process" => vm["peak_verifier_bytes"]
      },
      "fresh_consumer_startup_us" => fm["startup_us"],
      "fresh_consumer_total_us" => fm["total_us"],
      "outcomes" => %{"fresh_os_process" => fresh["outcome"], "in_vm" => in_vm["outcome"]},
      "fresh_do_boundary_loaded" => get_in(fresh, ["process", "do_boundary_loaded"]),
      "external_consequence_rows_delta" => delta,
      "actuator_events_during_replay" => length(row.actuator_events)
    }
  end

  defp environment do
    %{
      "otp_release" => to_string(:erlang.system_info(:otp_release)),
      "elixir" => System.version(),
      "system_architecture" => to_string(:erlang.system_info(:system_architecture)),
      "schedulers_online" => :erlang.system_info(:schedulers_online),
      "logical_processors" => :erlang.system_info(:logical_processors_available)
    }
  end

  # --- CHI-REPLAY-001 --------------------------------------------------------------

  defp positive_control(ctx, f, base, root) do
    {in_vm, fresh, delta} =
      Context.stimulus(ctx, f, fn ->
        dir = Fx.copy_chain(base, root, "intact")
        before = Fx.rows(base.operations)
        opts = anchor(base) ++ [producer: base.pid]
        {:ok, in_vm} = OfflineReplay.replay(dir, opts)
        {:ok, fresh} = OfflineReplay.verify_fresh(dir, opts)
        {in_vm, fresh, Fx.rows(base.operations) - before}
      end)

    if unavailable?(fresh) do
      Result.blocked(f, "fresh OS process unavailable: #{inspect(fresh["reasons"])}")
    else
      actuations = Enum.filter(@actuations, &Context.observed?(ctx, f, &1))
      records = get_in(in_vm, ["reconstruction", "records"]) || []

      dedup_reconstructed? =
        Enum.any?(records, &(get_in(&1, ["prepared_receipt", "reason"]) == "deduplicated"))

      complete? = fn v ->
        r = v["reconstruction"] || %{}
        r["commands"] == 3 and r["stages_reconstructed"] == r["stages_expected"]
      end

      expected? =
        in_vm["outcome"] == "verified" and fresh["outcome"] == "verified" and
          fresh["fresh_process_accepted"] == true and
          get_in(fresh, ["process", "do_boundary_loaded"]) == false and
          get_in(fresh, ["process", "ash_a2a_started"]) == false and complete?.(in_vm) and
          complete?.(fresh) and dedup_reconstructed? and delta == 0 and actuations == [] and
          in_vm["anchor"] == %{"link_root" => true, "basis_root" => true}

      Result.positive(f,
        attempt_observed?: Context.observed?(ctx, f, @verified),
        expected_outcome_observed?: expected?,
        evidence: %{
          "in_vm" => summary(in_vm),
          "fresh" => summary(fresh),
          "stages" => OfflineReplay.stages(),
          "stages_reconstructed" => get_in(fresh, ["reconstruction", "stages_reconstructed"]),
          "stages_expected" => get_in(fresh, ["reconstruction", "stages_expected"]),
          "deduplicated_retry_reconstructed" => dedup_reconstructed?,
          "ledger_rows_delta" => delta,
          "actuation_events_during_replay" => actuations,
          "seal" => Map.take(base.seal, ["length", "evidence_bytes", "link_root", "basis_root"])
        }
      )
    end
  end

  # --- CHI-REPLAY-002 ----------------------------------------------------------------

  defp missing_receipt(ctx, f, base, root) do
    mutations(ctx, f, base, root, [
      {"final_file_deleted", {"replay_receipt_missing", "links_present"},
       fn dir -> Fx.delete_file!(dir, Fx.link(Fx.manifest(dir), 2, "final")) end, []},
      {"prepared_link_removed_reforged", {"replay_receipt_missing", "reconstruction_complete"},
       fn dir ->
         Fx.remove_link!(dir, Fx.link(Fx.manifest(dir), 2, "prepared"))
         Fx.reforge!(dir)
       end, []}
    ])
  end

  # --- CHI-REPLAY-003 ----------------------------------------------------------------

  defp reordered(ctx, f, base, root) do
    swap = fn dir ->
      m = Fx.manifest(dir)
      Fx.swap_links!(dir, Fx.link(m, 2, "prepared"), Fx.link(m, 2, "final"))
    end

    mutations(ctx, f, base, root, [
      {"prepared_final_swapped", {"replay_link_broken", "link_chaining"}, swap, []},
      {"prepared_final_swapped_reforged",
       {"replay_receipt_order_violation", "reconstruction_order"},
       fn dir ->
         swap.(dir)
         Fx.reforge!(dir)
       end, []},
      {"dedup_retry_moved_first_reforged",
       {"replay_receipt_order_violation", "reconstruction_order"},
       fn dir ->
         Fx.move_command_first!(dir, 3)
         Fx.reforge!(dir)
       end, []}
    ])
  end

  # --- CHI-REPLAY-004 ----------------------------------------------------------------

  defp changed_digest(ctx, f, base, root) do
    rewrite = fn dir ->
      Fx.rewrite_receipt!(dir, Fx.link(Fx.manifest(dir), 2, "final"), fn r ->
        %{r | input_digest: "sha256:" <> String.duplicate("f", 64)}
      end)
    end

    mutations(ctx, f, base, root, [
      {"final_input_digest_rewritten", {"replay_digest_mismatch", "link_digests"}, rewrite, []},
      {"final_input_digest_rewritten_reforged",
       {"replay_identity_divergence", "reconstruction_identity"},
       fn dir ->
         rewrite.(dir)
         Fx.reforge!(dir)
       end, []}
    ])
  end

  # --- CHI-REPLAY-005 ----------------------------------------------------------------

  defp changed_authority(ctx, f, base, root) do
    foreign = fn r ->
      grant =
        Map.merge(r.authority_grant || %{}, %{
          subject: "principal:chicago-replay-intruder",
          token_id: "runtime:forged-grant"
        })

      %{r | authority_grant: grant}
    end

    mutations(ctx, f, base, root, [
      {"final_grant_rewritten_reforged",
       {"replay_authority_divergence", "reconstruction_authority"},
       fn dir ->
         Fx.rewrite_receipt!(dir, Fx.link(Fx.manifest(dir), 1, "final"), foreign)
         Fx.reforge!(dir)
       end, []},
      {"both_grants_rewritten_reforged",
       {"replay_authority_divergence", "reconstruction_authority"},
       fn dir ->
         m = Fx.manifest(dir)
         Fx.rewrite_receipt!(dir, Fx.link(m, 1, "prepared"), foreign)
         Fx.rewrite_receipt!(dir, Fx.link(m, 1, "final"), foreign)
         Fx.reforge!(dir)
       end, []}
    ])
  end

  # --- CHI-REPLAY-006 ----------------------------------------------------------------

  defp duplicate_actuation(ctx, f, env, base, root) do
    outcome =
      Context.stimulus(ctx, f, fn ->
        dir = Path.join(root, "double-#{System.unique_integer([:positive])}")

        with {:ok, double} <-
               Fx.produce(env, dir, executed: 1, dedup_retry: false, double_actuation: true) do
          rows = Fx.rows(double.operations)
          {:ok, real} = OfflineReplay.verify_fresh(double.dir, producer: double.pid)

          spliced = Fx.copy_chain(base, root, "spliced")
          Fx.splice_command!(spliced, 1)
          Fx.reforge!(spliced)
          {:ok, splice} = OfflineReplay.verify_fresh(spliced, producer: base.pid)

          {:ok, rows, [{"real_double_actuation", real}, {"spliced_segment_reforged", splice}]}
        end
      end)

    case outcome do
      {:ok, rows, verdicts} ->
        expected = {"replay_duplicate_actuation", "reconstruction_actuation_unique"}

        classes =
          Enum.map(verdicts, fn
            {"real_double_actuation", v} when rows != 2 -> {:undetermined, v}
            {_name, v} -> {classify(v, expected), v}
          end)

        negative(
          ctx,
          f,
          Enum.map(classes, &elem(&1, 0)),
          verdicts
          |> Map.new(fn {name, v} -> {name, summary(v)} end)
          |> Map.put("real_double_actuation_ledger_rows", rows)
        )

      {:error, reason} ->
        Result.blocked(f, "double-actuation chain production failed: #{reason}")
    end
  end

  # --- CHI-REPLAY-007 ----------------------------------------------------------------

  defp divergent_root(ctx, f, base, root) do
    change = fn dir ->
      Fx.rewrite_post_state!(
        dir,
        Fx.link(Fx.manifest(dir), 2, "post_state"),
        &Map.put(&1, "rows", 3)
      )
    end

    mutations(ctx, f, base, root, [
      {"link_root_left", {"replay_root_divergence", "link_root"},
       fn dir ->
         change.(dir)
         Fx.reforge!(dir, link_root: :keep, basis_root: :keep)
       end, []},
      {"basis_root_left", {"replay_root_divergence", "basis_root"},
       fn dir ->
         change.(dir)
         Fx.reforge!(dir, basis_root: :keep)
       end, []},
      {"both_roots_reforged_anchored", {"replay_root_divergence", "anchor_basis_root"},
       fn dir ->
         change.(dir)
         Fx.reforge!(dir)
       end, [basis_root: base.seal["basis_root"]]}
    ])
  end

  # --- CHI-REPLAY-008 ----------------------------------------------------------------

  defp actuator(ctx, f, env, base, root) do
    {verdict, reply, delta} =
      Context.stimulus(ctx, f, fn ->
        dir = Fx.copy_chain(base, root, "actuator")
        before = Fx.rows(base.operations)
        {:ok, verdict} = OfflineReplay.replay(dir, anchor(base) ++ [producer: base.pid])

        m = Fx.manifest(dir)

        {:ok, final} =
          dir
          |> Path.join(Fx.link(m, 1, "final")["file"])
          |> File.read!()
          |> EvidenceChain.decode_receipt()

        observation =
          dir |> Path.join(Fx.link(m, 1, "post_state")["file"]) |> File.read!() |> JSON.decode!()

        {:ok, basis} = Replay.basis(final)

        # The replay consumer drives the replayed evidence -- its authority
        # record and intended effect -- back at the real consequence boundary.
        command =
          Command.new(basis.intended_effect.capability_id,
            command_id: "chicago-replay-redrive-#{System.unique_integer([:positive])}",
            agent_id: "chicago-replay-redrive",
            principal_id: final.actor,
            authority: basis.authorization,
            input: %{"operation_id" => observation["operation_id"]}
          )

        reply =
          try do
            CommandBus.run(
              command,
              Fx.message(%{operation_id: observation["operation_id"]}),
              Effect,
              store: Ekv,
              store_opts: Environment.store_opts(env)
            )
          rescue
            exception -> {:raised, Exception.message(exception)}
          end

        {verdict, reply, Fx.rows(base.operations) - before}
      end)

    actuations = Enum.filter(@actuations, &Context.observed?(ctx, f, &1))

    Result.negative(f,
      attempt_observed?:
        verdict["outcome"] == "verified" and
          Context.observed?(ctx, f, @verified) and Context.observed?(ctx, f, "brce.admission"),
      forbidden_outcome_observed?: actuations != [] or delta != 0,
      evidence: %{
        "replay" => summary(verdict),
        "redrive_reply" => inspect(reply, limit: 20),
        "actuation_events" => actuations,
        "ledger_rows_delta" => delta
      }
    )
  end

  # --- shared ------------------------------------------------------------------------

  defp anchor(pkg), do: [link_root: pkg.seal["link_root"], basis_root: pkg.seal["basis_root"]]

  # Each mutation: {name, {expected_reason, expected_failed_check}, mutate, verify_opts}.
  defp mutations(ctx, f, base, root, specs) do
    verdicts =
      Context.stimulus(ctx, f, fn ->
        specs
        |> Task.async_stream(
          fn {name, expected, mutate, verify_opts} ->
            dir = Fx.copy_chain(base, root, name)
            mutate.(dir)
            {:ok, v} = OfflineReplay.verify_fresh(dir, verify_opts ++ [producer: base.pid])
            {name, expected, v}
          end,
          max_concurrency: 3,
          timeout: 600_000
        )
        |> Enum.map(fn {:ok, result} -> result end)
      end)

    negative(
      ctx,
      f,
      Enum.map(verdicts, fn {_name, expected, v} -> classify(v, expected) end),
      Map.new(verdicts, fn {name, _expected, v} -> {name, summary(v)} end)
    )
  end

  defp negative(ctx, f, classes, evidence) do
    if Enum.member?(classes, :unavailable) do
      Result.blocked(f, "fresh OS process unavailable")
    else
      forbidden =
        cond do
          Enum.member?(classes, :verified) -> true
          classes != [] and Enum.all?(classes, &(&1 == :detected)) -> false
          true -> :unknown
        end

      Result.negative(f,
        attempt_observed?: Context.observed?(ctx, f, @verified),
        forbidden_outcome_observed?: forbidden,
        evidence: Map.put(evidence, "classes", Enum.map(classes, &Atom.to_string/1))
      )
    end
  end

  # :verified     -- the forbidden standing: the mutated chain verified
  # :detected     -- refused by an accepted fresh process, naming the expected
  #                  reason at the expected check
  # :undetermined -- anything else (never a pass)
  defp classify(verdict, {reason, check}) do
    cond do
      unavailable?(verdict) ->
        :unavailable

      verdict["outcome"] == "verified" ->
        :verified

      verdict["outcome"] == "refused" and verdict["fresh_process_accepted"] == true and
          Enum.any?(
            List.wrap(verdict["checks"]),
            &(&1["ok"] == false and &1["reason"] == reason and &1["check"] == check)
          ) ->
        :detected

      true ->
        :undetermined
    end
  end

  defp unavailable?(verdict),
    do:
      Enum.any?(
        List.wrap(verdict["reasons"]),
        &String.starts_with?(to_string(&1), "replay_fresh_process_unavailable")
      )

  defp summary(verdict) do
    %{
      "outcome" => verdict["outcome"],
      "mode" => verdict["mode"],
      "reasons" => verdict["reasons"],
      "failed_checks" =>
        verdict["checks"]
        |> List.wrap()
        |> Enum.reject(& &1["ok"])
        |> Enum.map(&Map.take(&1, ["check", "reason", "detail"])),
      "fresh_process_accepted" => verdict["fresh_process_accepted"],
      "process" => verdict["process"] && Map.drop(verdict["process"], ["started_applications"]),
      "child" => verdict["child"],
      "chain" => verdict["chain"] && Map.drop(verdict["chain"], ["dir"]),
      "measurements" => verdict["measurements"]
    }
  end
end
