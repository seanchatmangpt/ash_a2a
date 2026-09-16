defmodule AshA2A.Chicago.Courts.FreshConsumer do
  @moduledoc """
  Gate 11 -- Fresh-Consumer Proof, and the Fresh Consumer and Durable Evidence
  Court (RFC-SA2A-002 §42, §74; durability §19, §139).

  Every package this court verifies is a real conformance package written by
  `AshA2A.Chicago.Runner` for a real producer court
  (`AshA2A.Chicago.Fixtures.FreshConsumer.*`) driving the real CommandBus, in
  a producer process the court terminates (`Process.exit(pid, :kill)`) before
  verification. The boundary that decides is
  `AshA2A.Chicago.FreshConsumer.verify/2`: it runs the package verification
  in a genuinely fresh `elixir` OS process with no producer memory and emits
  `[:ash_a2a, :chicago, :fresh_consumer, :verified]`, mapped here to the OCEL
  activity `fresh_consumer.verified`.

  Mutations are environment fault injection on real package files (§10): a
  deleted file, a flipped `receipt_digest`, a rewritten verdict, a swapped
  `ocel.json` (plain and with re-forged digests). The hidden-state falsifier
  uses mutable singleton state (`:persistent_term`) the producer VM holds and
  no package file records -- the fresh OS process is the load-bearing guard,
  and the court records that an in-process verification of the same package
  reproduces (the vacuity demonstration, §22).
  """

  use AshA2A.Chicago.Court

  alias AshA2A.Chicago.{Context, Falsifier, FreshConsumer, Result, Runner, StandingReceipt}
  alias AshA2A.Chicago.Fixtures.FreshConsumer, as: F
  alias AshA2A.Chicago.Ocel.Mapping

  @verified "fresh_consumer.verified"
  @id "CHI-FRESH"

  @impl true
  def id, do: @id
  @impl true
  def title, do: "Fresh-consumer proof and durable evidence"
  @impl true
  def gate, do: 11
  @impl true
  def profile, do: :do
  @impl true
  def rfc_sections, do: ["§19", "§42", "§74", "§100", "§139"]

  @impl true
  def ocel_mappings do
    [
      Mapping.new!(
        event: FreshConsumer.event(),
        activity: @verified,
        source: __MODULE__,
        objects: fn _m, meta ->
          [
            {"evidence_package", meta[:package_ref], "package"},
            {"fresh_consumer_process", meta[:child_os_pid] && "os-pid-#{meta[:child_os_pid]}",
             "verifier"}
          ]
        end,
        attributes: fn _m, meta ->
          Map.take(meta, [
            :outcome,
            :reasons,
            :package_run_id,
            :claimed_standing,
            :recorded_standing,
            :reconstructed_standing,
            :fresh_process,
            :producer_terminated,
            :questions_unknown
          ])
        end
      )
    ]
  end

  @impl true
  def falsifiers do
    fresh = {:not_observed, @verified, %{"fresh_process" => "false"}}
    reproduced = {:observed, @verified, %{"outcome" => "reproduced"}}

    negative = fn fields ->
      Falsifier.new!(
        Keyword.merge(
          [
            court_id: @id,
            kind: :negative,
            boundary:
              "AshA2A.Chicago.FreshConsumer.verify/2 (fresh OS process running verify_package/1; local acceptance of its verdict)",
            forbidden_outcome: "the fresh consumer reports the standing reproduced",
            survival_evidence: "fresh_consumer.verified with outcome=reproduced",
            failure_class: :fresh_consumer_failure,
            outcome_predicate: reproduced,
            rfc_sections: ["§42", "§74"]
          ],
          fields
        )
      )
    end

    [
      Falsifier.new!(
        id: "CHI-FRESH-001",
        court_id: @id,
        kind: :positive_control,
        invariant:
          "Standing reproduces from the durable package alone after the producer process and its observer have terminated (§42, §19, §139)",
        stimulus:
          "Real producer court (CommandBus refusal + authorized create) run by Runner in a producer process; the court kills the producer, then FreshConsumer.verify/2 in a fresh `elixir` OS process",
        boundary: "AshA2A.Chicago.FreshConsumer.verify/2",
        attempt_evidence:
          "fresh_consumer.verified with producer_terminated=true and fresh_process=true",
        survival_evidence:
          "outcome=reproduced; the producer's brce.commit precedes the verification; the §74 standing basis and DO-free replay answered; the committed row is visible to an independent Ash.read!",
        attempt_predicate:
          {:observed, @verified, %{"producer_terminated" => "true", "fresh_process" => "true"}},
        outcome_predicate:
          {:all,
           [
             {:observed, @verified,
              %{
                "outcome" => "reproduced",
                "producer_terminated" => "true",
                "fresh_process" => "true"
              }},
             {:not_observed, @verified, %{"outcome" => "diverged"}},
             {:not_observed, @verified, %{"outcome" => "refused"}},
             {:precedes, "brce.commit", @verified}
           ]},
        rfc_sections: ["§19", "§42", "§100", "§139"]
      ),
      negative.(
        id: "CHI-FRESH-002",
        invariant:
          "If standing depends on hidden producer state (mutable singleton state no package file records), a fresh consumer must fail to reproduce it and say so (§42)",
        stimulus:
          "Producer run of HiddenStateCourt, whose attempt predicate reads :persistent_term set only in the producer VM; producer killed; FreshConsumer.verify/2 in a fresh OS process",
        attempt_evidence: "fresh_consumer.verified from an accepted fresh OS process",
        guard:
          "FreshConsumer.verify/2 spawning a fresh OS process (no producer memory) + verify_package/1 corpus-digest, re-corroboration and StandingReceipt.recompute/1 checks",
        attempt_predicate: {:observed, @verified, %{"fresh_process" => "true"}}
      ),
      negative.(
        id: "CHI-FRESH-003",
        invariant:
          "A package missing any durable file (receipt, results, OCEL, OCEL validation, subject) must not yield standing (§19, §74)",
        stimulus:
          "Five copies of a reproducing package, each with one of the five package files deleted; FreshConsumer.verify/2 on each",
        attempt_evidence: "five fresh_consumer.verified events, none from an unaccepted process",
        guard: "FreshConsumer.verify_package/1 load_files admission (package_file_missing)",
        attempt_predicate: {:all, [{:count, @verified, :gte, 5}, fresh]}
      ),
      negative.(
        id: "CHI-FRESH-004",
        invariant:
          "A standing receipt whose receipt_digest does not match its content is refused (§115)",
        stimulus:
          "Copy of a reproducing package with one hex digit of receipt_digest flipped; FreshConsumer.verify/2",
        attempt_evidence: "fresh_consumer.verified from an accepted fresh OS process",
        guard:
          "FreshConsumer.verify_package/1 receipt_digest admission (StandingReceipt.verify_digest/1)",
        attempt_predicate: {:observed, @verified, %{"fresh_process" => "true"}}
      ),
      negative.(
        id: "CHI-FRESH-005",
        invariant:
          "A verdict rewritten in results.json (demoting or promoting) is detected as a standing mismatch, not trusted (§42)",
        stimulus:
          "(a) reproducing package with FALSIFIER_KILLED rewritten to FALSIFIER_SURVIVED; (b) a real UNKNOWN package (misaimed court) with UNKNOWN rewritten to a corroborated FALSIFIER_KILLED; FreshConsumer.verify/2 on each",
        attempt_evidence: "two fresh_consumer.verified events from accepted fresh OS processes",
        guard:
          "FreshConsumer.verify_package/1 recorded-projection check (StandingReceipt.recompute/1 vs receipt) and OCEL re-corroboration",
        attempt_predicate: {:all, [{:count, @verified, :gte, 2}, fresh]}
      ),
      negative.(
        id: "CHI-FRESH-006",
        invariant:
          "ocel.json from another run cannot stand in for this run's process evidence (§19, §21)",
        stimulus:
          "(a) reproducing package with ocel.json replaced by a second real run's; (b) the same swap with the receipt's OCEL digest/counts, the validation receipt and receipt_digest re-forged; FreshConsumer.verify/2 on each",
        attempt_evidence: "two fresh_consumer.verified events from accepted fresh OS processes",
        guard:
          "FreshConsumer.verify_package/1 OCEL content-digest and chicago_run run/mapping binding admission",
        attempt_predicate: {:all, [{:count, @verified, :gte, 2}, fresh]}
      )
    ]
  end

  @impl true
  def run(%Context{} = ctx) do
    [f1, f2, f3, f4, f5, f6] = falsifiers()

    {r1, base} = positive_control(ctx, f1)
    r2 = hidden_state(ctx, f2)

    mutations =
      case {r1.verdict, base} do
        {:positive_control_passed, %{} = pkg} ->
          [
            deleted_files(ctx, f3, pkg),
            tampered_receipt_digest(ctx, f4, pkg),
            tampered_verdict(ctx, f5, pkg),
            swapped_ocel(ctx, f6, pkg)
          ]

        _ ->
          detail =
            "the unmutated base package did not reproduce (#{r1.verdict}); a mutation verdict would not discriminate"

          Enum.map([f3, f4, f5, f6], &Result.unknown(&1, detail))
      end

    [r1, r2 | mutations]
  end

  # --- CHI-FRESH-001 ----------------------------------------------------------

  defp positive_control(ctx, f) do
    outcome =
      Context.stimulus(ctx, f, fn ->
        with {:ok, pkg} <- produce(ctx, "clean", F.ProducerCourt) do
          {:ok, verdict} = FreshConsumer.verify(pkg.dir, producer: pkg.pid)
          {:ok, pkg, verdict}
        end
      end)

    case outcome do
      {:ok, pkg, verdict} ->
        if unavailable?(verdict) do
          {Result.blocked(f, "fresh OS process unavailable: #{inspect(verdict["reasons"])}"), nil}
        else
          {denied, allowed} = producer_labels(pkg.dir)
          labels = F.labels()
          questions = verdict["questions"] || %{}

          expected? =
            verdict["outcome"] == "reproduced" and verdict["producer_terminated"] == true and
              verdict["fresh_process_accepted"] == true and pkg.observer_handlers == 0 and
              get_in(questions, ["standing_basis", "status"]) == "ANSWERED" and
              get_in(questions, ["replayable_without_do", "answer"]) == true and
              is_binary(allowed) and allowed in labels and is_binary(denied) and
              denied not in labels

          result =
            Result.positive(f,
              attempt_observed?: Context.observed?(ctx, f, @verified),
              expected_outcome_observed?: expected?,
              evidence:
                verdict
                |> summary()
                |> Map.merge(%{
                  "producer_standing" => pkg.standing,
                  "producer_observer_handlers_after_kill" => pkg.observer_handlers,
                  "independent_reader_allowed_present" => allowed in labels,
                  "independent_reader_denied_absent" => denied not in labels,
                  "question_status" => Map.new(questions, fn {q, a} -> {q, a["status"]} end)
                })
            )

          {result, pkg}
        end

      {:error, reason} ->
        {Result.blocked(f, "producer package unavailable: #{reason}"), nil}
    end
  end

  # The durable results.json names the labels the producer acted on; the
  # independent Ash reader confirms the committed one exists and the refused
  # one does not.
  defp producer_labels(dir) do
    results = dir |> Path.join("results.json") |> File.read!() |> JSON.decode!()

    label = fn id ->
      Enum.find_value(results, fn r ->
        r["falsifier_id"] == id && get_in(r, ["evidence", "label"])
      end)
    end

    {label.("CHI-FRESHFIX-PRODUCER-001"), label.("CHI-FRESHFIX-PRODUCER-002")}
  end

  # --- CHI-FRESH-002 ----------------------------------------------------------

  defp hidden_state(ctx, f) do
    outcome =
      Context.stimulus(ctx, f, fn ->
        F.put_hidden_state("authority_required")

        try do
          with {:ok, pkg} <- produce(ctx, "hidden", F.HiddenStateCourt) do
            # Vacuity demonstration: in the producer VM (hidden state present)
            # the same package reproduces.
            in_process = FreshConsumer.verify_package(pkg.dir)
            {:ok, verdict} = FreshConsumer.verify(pkg.dir, producer: pkg.pid)
            {:ok, pkg, verdict, in_process}
          end
        after
          F.erase_hidden_state()
        end
      end)

    case outcome do
      {:ok, pkg, verdict, in_process} ->
        class =
          cond do
            unavailable?(verdict) ->
              :unavailable

            pkg.standing != "PARTIAL_ALIVE" ->
              :undetermined

            true ->
              classify(
                verdict,
                ["diverged"],
                &String.starts_with?(&1, "standing_not_reproduced:")
              )
          end

        negative(ctx, f, [class], %{
          "verdict" => summary(verdict),
          "producer_standing" => pkg.standing,
          "in_process_outcome" => in_process["outcome"],
          "in_process_reasons" => in_process["reasons"]
        })

      {:error, reason} ->
        Result.blocked(f, "producer package unavailable: #{reason}")
    end
  end

  # --- CHI-FRESH-003 ----------------------------------------------------------

  defp deleted_files(ctx, f, pkg) do
    verdicts =
      Context.stimulus(ctx, f, fn ->
        FreshConsumer.package_files()
        |> Task.async_stream(
          fn file ->
            dir = copy_package(ctx, pkg, "deleted-" <> Path.rootname(file))
            File.rm!(Path.join(dir, file))
            {:ok, verdict} = FreshConsumer.verify(dir, producer: pkg.pid)
            {file, verdict}
          end,
          max_concurrency: 3,
          timeout: 600_000
        )
        |> Enum.map(fn {:ok, file_verdict} -> file_verdict end)
      end)

    classes =
      Enum.map(verdicts, fn {file, verdict} ->
        classify(verdict, ["refused"], &(&1 == "package_file_missing:" <> file))
      end)

    negative(ctx, f, classes, Map.new(verdicts, fn {file, v} -> {file, summary(v)} end))
  end

  # --- CHI-FRESH-004 ----------------------------------------------------------

  defp tampered_receipt_digest(ctx, f, pkg) do
    verdict =
      Context.stimulus(ctx, f, fn ->
        dir = copy_package(ctx, pkg, "tampered-receipt-digest")

        rewrite_json!(Path.join(dir, "standing_receipt.json"), fn receipt ->
          Map.update!(receipt, "receipt_digest", &flip_hex/1)
        end)

        {:ok, verdict} = FreshConsumer.verify(dir, producer: pkg.pid)
        verdict
      end)

    class = classify(verdict, ["refused"], &(&1 == "receipt_digest_mismatch"))
    negative(ctx, f, [class], %{"verdict" => summary(verdict)})
  end

  # --- CHI-FRESH-005 ----------------------------------------------------------

  defp tampered_verdict(ctx, f, pkg) do
    outcome =
      Context.stimulus(ctx, f, fn ->
        demoted = copy_package(ctx, pkg, "tampered-verdict-demoted")

        demoted_applied? =
          rewrite_result!(demoted, "CHI-FRESHFIX-PRODUCER-001", "FALSIFIER_KILLED", fn r ->
            %{r | "verdict" => "FALSIFIER_SURVIVED", "failure_class" => "AUTHORITY_FAILURE"}
          end)

        {:ok, demoted_verdict} = FreshConsumer.verify(demoted, producer: pkg.pid)

        with {:ok, misaimed} <- produce(ctx, "misaimed", F.MisaimedCourt) do
          # Control: the untampered UNKNOWN package reproduces (in-process,
          # no telemetry), so a divergence below is caused by the tamper.
          control = FreshConsumer.verify_package(misaimed.dir)
          promoted = copy_package(ctx, misaimed, "tampered-verdict-promoted")

          promoted_applied? =
            rewrite_result!(promoted, "CHI-FRESHFIX-MISAIMED-001", "UNKNOWN", fn r ->
              %{
                r
                | "verdict" => "FALSIFIER_KILLED",
                  "failure_class" => nil,
                  "ocel_corroborated" => true
              }
            end)

          {:ok, promoted_verdict} = FreshConsumer.verify(promoted, producer: misaimed.pid)

          {:ok,
           [
             {"demoted", demoted_applied?, demoted_verdict},
             {"promoted", promoted_applied? and control["outcome"] == "reproduced",
              promoted_verdict}
           ], control}
        end
      end)

    case outcome do
      {:ok, mutations, control} ->
        standing_mismatch? =
          &(String.starts_with?(&1, "recorded_projection_mismatch:") and
              String.contains?(&1, "standing"))

        classes =
          Enum.map(mutations, fn {_name, applied?, verdict} ->
            if applied?,
              do: classify(verdict, ["diverged"], standing_mismatch?),
              else: :undetermined
          end)

        negative(
          ctx,
          f,
          classes,
          mutations
          |> Map.new(fn {name, applied?, v} ->
            {name, Map.put(summary(v), "mutation_applied", applied?)}
          end)
          |> Map.put("untampered_misaimed_control_outcome", control["outcome"])
        )

      {:error, reason} ->
        Result.blocked(f, "misaimed producer package unavailable: #{reason}")
    end
  end

  # --- CHI-FRESH-006 ----------------------------------------------------------

  defp swapped_ocel(ctx, f, pkg) do
    outcome =
      Context.stimulus(ctx, f, fn ->
        with {:ok, other} <- produce(ctx, "other-run", F.ProducerCourt) do
          other_ocel = Path.join(other.dir, "ocel.json")

          swapped = copy_package(ctx, pkg, "swapped-ocel")
          File.cp!(other_ocel, Path.join(swapped, "ocel.json"))
          {:ok, swapped_verdict} = FreshConsumer.verify(swapped, producer: [pkg.pid, other.pid])

          forged = copy_package(ctx, pkg, "swapped-ocel-forged")
          File.cp!(other_ocel, Path.join(forged, "ocel.json"))
          forge_ocel_binding!(forged)
          {:ok, forged_verdict} = FreshConsumer.verify(forged, producer: [pkg.pid, other.pid])

          {:ok, other, swapped_verdict, forged_verdict}
        end
      end)

    case outcome do
      {:ok, other, swapped_verdict, forged_verdict} ->
        distinct_run? = other.run_id != pkg.run_id

        forged_digests_hold? =
          not Enum.any?(
            List.wrap(forged_verdict["reasons"]),
            &(&1 in [
                "receipt_digest_mismatch",
                "ocel_digest_mismatch",
                "ocel_validation_digest_mismatch"
              ])
          )

        classes = [
          if(distinct_run?,
            do: classify(swapped_verdict, ["refused"], &(&1 == "ocel_digest_mismatch")),
            else: :undetermined
          ),
          if(distinct_run? and forged_digests_hold?,
            do: classify(forged_verdict, ["refused"], &(&1 == "ocel_run_mismatch")),
            else: :undetermined
          )
        ]

        negative(ctx, f, classes, %{
          "other_run_id" => other.run_id,
          "swapped" => summary(swapped_verdict),
          "forged" =>
            Map.put(summary(forged_verdict), "forged_digests_hold", forged_digests_hold?)
        })

      {:error, reason} ->
        Result.blocked(f, "second producer package unavailable: #{reason}")
    end
  end

  # --- verdict helpers ----------------------------------------------------------

  defp negative(ctx, f, classes, evidence) do
    if Enum.member?(classes, :unavailable) do
      Result.blocked(f, "fresh OS process unavailable")
    else
      forbidden =
        cond do
          Enum.member?(classes, :reproduced) -> true
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

  # :reproduced -- the forbidden standing was reconstructed
  # :detected   -- the expected outcome, naming the expected reason
  # :undetermined -- anything else (never a pass)
  defp classify(verdict, outcomes, reason?) do
    cond do
      unavailable?(verdict) ->
        :unavailable

      verdict["outcome"] == "reproduced" ->
        :reproduced

      verdict["outcome"] in outcomes and Enum.any?(List.wrap(verdict["reasons"]), reason?) ->
        :detected

      true ->
        :undetermined
    end
  end

  defp unavailable?(verdict),
    do:
      Enum.any?(
        List.wrap(verdict["reasons"]),
        &String.starts_with?(to_string(&1), "fresh_process_unavailable")
      )

  defp summary(verdict) do
    %{
      "outcome" => verdict["outcome"],
      "reasons" => verdict["reasons"],
      "standing" => verdict["standing"],
      "fresh_process_accepted" => verdict["fresh_process_accepted"],
      "child" => verdict["child"],
      "package_run_id" => get_in(verdict, ["package", "run_id"])
    }
  end

  # --- producer ------------------------------------------------------------------

  # Runs `court` through the real Runner in a separate producer process, waits
  # for its durable package, then kills the producer (and with it every
  # in-memory structure it held) before anyone verifies the package.
  defp produce(ctx, name, court) do
    unique = System.unique_integer([:positive])
    dir = Path.join([ctx.evidence_dir, "fresh_consumer", "#{name}-#{unique}"])
    run_id = "fresh-producer-#{name}-#{unique}"
    parent = self()
    ref = make_ref()

    {pid, monitor} =
      spawn_monitor(fn ->
        reply =
          case Runner.run(
                 profile: :core,
                 courts: [court],
                 evidence_dir: dir,
                 run_id: run_id,
                 court_timeout_ms: 300_000
               ) do
            {:ok, run} -> {:ok, run.receipt["standing"]}
            {:error, reason} -> {:error, inspect(reason)}
          end

        send(parent, {ref, reply})

        receive do
          :never -> :ok
        after
          900_000 -> :ok
        end
      end)

    receive do
      {^ref, {:ok, standing}} ->
        Process.exit(pid, :kill)

        receive do
          {:DOWN, ^monitor, :process, ^pid, _reason} -> :ok
        after
          10_000 -> :ok
        end

        {:ok,
         %{
           dir: dir,
           pid: pid,
           run_id: run_id,
           standing: standing,
           observer_handlers: observer_handlers(run_id)
         }}

      {^ref, {:error, reason}} ->
        Process.exit(pid, :kill)
        {:error, reason}

      {:DOWN, ^monitor, :process, ^pid, reason} ->
        {:error, "producer exited: #{inspect(reason)}"}
    after
      600_000 ->
        Process.exit(pid, :kill)
        {:error, "producer timed out"}
    end
  end

  defp observer_handlers(run_id) do
    Enum.count(:telemetry.list_handlers([]), fn %{id: id} ->
      match?({AshA2A.Chicago.Observer, ^run_id, _}, id)
    end)
  end

  # --- package mutation (environment fault injection on real files) -------------

  defp copy_package(ctx, pkg, name) do
    dir =
      Path.join([
        ctx.evidence_dir,
        "fresh_consumer",
        "#{name}-#{System.unique_integer([:positive])}"
      ])

    File.mkdir_p!(dir)
    File.cp_r!(pkg.dir, dir)
    dir
  end

  defp rewrite_json!(path, fun) do
    path
    |> File.read!()
    |> JSON.decode!()
    |> fun.()
    |> AshA2A.Chicago.Json.canonical()
    |> then(&File.write!(path, &1))
  end

  # Rewrites the result for `falsifier_id` when its recorded verdict is
  # `expected`; returns whether the mutation was applied.
  defp rewrite_result!(dir, falsifier_id, expected, fun) do
    path = Path.join(dir, "results.json")
    results = path |> File.read!() |> JSON.decode!()

    applied? =
      Enum.any?(results, &(&1["falsifier_id"] == falsifier_id and &1["verdict"] == expected))

    if applied? do
      rewrite_json!(path, fn results ->
        Enum.map(results, fn r ->
          if r["falsifier_id"] == falsifier_id, do: fun.(r), else: r
        end)
      end)
    end

    applied?
  end

  # A forger with write access re-binds the receipt and validation receipt to
  # the swapped OCEL bytes and recomputes the unkeyed receipt_digest.
  defp forge_ocel_binding!(dir) do
    bytes = File.read!(Path.join(dir, "ocel.json"))
    doc = JSON.decode!(bytes)
    sha = :crypto.hash(:sha256, bytes) |> Base.encode16(case: :lower)

    rewrite_json!(Path.join(dir, "ocel_validation.json"), &Map.put(&1, "ocel_sha256", sha))

    rewrite_json!(Path.join(dir, "standing_receipt.json"), fn receipt ->
      receipt =
        update_in(receipt, ["evidence"], fn evidence ->
          Map.merge(evidence, %{
            "ocel_digest" => sha,
            "ocel_bytes" => byte_size(bytes),
            "ocel_events" => length(doc["events"]),
            "ocel_objects" => length(doc["objects"])
          })
        end)

      Map.put(receipt, "receipt_digest", StandingReceipt.digest(receipt))
    end)
  end

  defp flip_hex(<<head::binary-size(1), rest::binary>>),
    do: if(head == "0", do: "1", else: "0") <> rest
end
