defmodule AshA2A.Chicago.StandingReceipt do
  @moduledoc """
  Machine-readable Chicago standing receipt (RFC-SA2A-002 §115, §116,
  Appendix D).

  Standing is computed, never asserted:

    * a `:claimed_subject` that does not verify against the executed subject
      -> `REFUSED` (§32), whatever the results
    * any `:build_broken` result -> `BUILD_BROKEN`
    * any survived falsifier or failed positive control -> `NONCONFORMANT`
    * every applicable result corroborated as passed, every required gate of
      the claimed profile covered and passed (§31, §145), the OCEL artifact
      independently validated with zero dropped records and zero observer
      restart gaps (§106, §138) ->
      `CONFORMANT`
    * at least one corroborated pass otherwise -> `PARTIAL_ALIVE`
    * nothing corroborated -> `UNKNOWN`

  `:unknown`, `:blocked`, uncorroborated passes, an unvalidated OCEL artifact,
  and missing gates all block `CONFORMANT` (§130: unknown required predicate
  implies not conformant). `:unsupported` and `:not_applicable` results are
  listed as exclusions and neither pass nor fail.

  The receipt binds the court revision, court version, falsifier-corpus
  digest, query-set digest, OCEL mapping digest, OCEL validator identity and
  standing-schema identity (§137), and is itself content-addressed
  (`receipt_digest`, computed over the receipt without that field).

  ## Court meta-admission (§136, §137)

  `:court_admission` (`AshA2A.Chicago.CourtManifest.admission/3`, computed by
  the runner before any court runs) is bound under `court.manifest`. When the
  running court machinery drifted from the admitted court manifest, standing
  that would otherwise be `CONFORMANT` is issued as `PARTIAL_ALIVE` and the
  claim names the drift: evidence from unadmitted court machinery is kept,
  never crowned. Absent (a receipt built outside the runner) it is
  `:not_evaluated` and blocks nothing.
  """

  alias AshA2A.Chicago.{CourtManifest, FailureClass, Falsifier, Profile, Query, Result, Subject}

  @specification "RFC-SA2A-002-v26.9.16"
  @schema "ash_a2a.chicago.standing_receipt/1"

  @spec specification() :: String.t()
  def specification, do: @specification

  @doc "Standing receipt schema identity (§137)."
  @spec schema() :: String.t()
  def schema, do: @schema

  @spec build(map()) :: map()
  def build(
        %{
          profile: profile,
          subject: subject,
          courts: courts,
          falsifiers: falsifiers,
          results: results
        } = run
      ) do
    verification = Map.get(run, :subject_verification, :not_claimed)
    court_admission = Map.get(run, :court_admission, :not_evaluated)
    subject_digest = Subject.digest(subject)
    court_revision = court_revision(courts)

    computed =
      recompute(%{
        profile: profile,
        courts: Enum.map(courts, &%{id: &1.id(), gate: &1.gate()}),
        results: results,
        ocel_validation_status: run.ocel_validation.status,
        ocel_dropped: run.ocel.dropped,
        ocel_gaps: Map.get(run.ocel, :gaps, 0),
        subject_verification: verification,
        court_admission: court_admission,
        source_revision: subject.source_revision,
        court_revision: court_revision
      })

    receipt = %{
      "specification" => @specification,
      "standing_schema" => @schema,
      "run_id" => run.run_id,
      "subject" =>
        subject
        |> Subject.to_map()
        |> Map.delete("repo")
        |> Map.merge(%{
          "identity" => subject_digest,
          "claimed_profile" => Profile.name(profile),
          "verification" => verification_map(verification)
        }),
      "court" => %{
        "revision" => court_revision,
        "version" => CourtManifest.version(),
        "manifest" => CourtManifest.to_map(court_admission),
        "ocel_validator_identity" => Map.get(run.ocel_validation, :identity),
        "courts" =>
          courts
          |> Enum.map(
            &%{
              "id" => &1.id(),
              "gate" => &1.gate(),
              "profile" => Profile.name(&1.profile()),
              "module" => inspect(&1)
            }
          )
          |> Enum.sort_by(& &1["id"]),
        "falsifier_corpus_digest" => corpus_digest(falsifiers),
        "query_set_digest" => query_set_digest(falsifiers),
        "ocel_mapping_digest" => run.ocel.mapping_digest
      },
      "results" => computed.tallies,
      "gates" => computed.gate_rows,
      "evidence" =>
        %{
          "ocel_digest" => run.ocel.sha256,
          "ocel_bytes" => run.ocel.bytes,
          "ocel_events" => run.ocel.events,
          "ocel_objects" => run.ocel.objects,
          "ocel_dropped_records" => run.ocel.dropped,
          "ocel_gaps" => Map.get(run.ocel, :gaps, 0),
          "ocel_late_records" => Map.get(run.ocel, :late, 0),
          "ocel_unmapped_events" => Map.get(run.ocel, :unmapped, 0),
          "ocel_rejected_refs" => Map.get(run.ocel, :rejected_refs, 0),
          "ocel_valid" => run.ocel_validation.status == :valid,
          "ocel_validation" => Atom.to_string(run.ocel_validation.status),
          "ocel_validator" => run.ocel_validation.validator,
          "evidence_classes_observed" => ["local_execution"]
        }
        |> Map.merge(computed.gate_evidence),
      "excluded" =>
        results
        |> Enum.filter(&(&1.verdict in [:unsupported, :not_applicable]))
        |> Enum.map(
          &%{
            "falsifier_id" => &1.falsifier_id,
            "verdict" => FailureClass.wire(&1.verdict),
            "detail" => &1.detail
          }
        ),
      "standing" => FailureClass.wire(computed.standing),
      "claim" => computed.claim
    }

    Map.put(receipt, "receipt_digest", digest(receipt))
  end

  @doc """
  Pure standing recomputation: the gate table, tallies, standing, per-gate
  evidence verdicts and claim, derived only from court descriptors
  (`%{id, gate}`), results and OCEL facts -- no court module is invoked.

  `build/1` issues standing through this function and fresh consumers
  (`AshA2A.Chicago.FreshConsumer`, Gate 11 §42) reconstruct it through the
  same function, so a reproduced standing is computed by exactly the logic
  that issued it -- every standing `build/1` can issue, including `REFUSED`
  (§32, from `:subject_verification`) and the observer-restart-gap bar on
  `CONFORMANT` (§138, from `:ocel_gaps`). Both keys are optional:
  `:subject_verification` defaults to `:not_claimed`, `:ocel_gaps` to `0`.
  """
  @spec recompute(%{
          required(:profile) => Profile.t(),
          required(:courts) => [%{id: String.t(), gate: 1..12 | nil}],
          required(:results) => [Result.t()],
          required(:ocel_validation_status) => atom() | String.t(),
          required(:ocel_dropped) => non_neg_integer() | nil,
          optional(:ocel_gaps) => non_neg_integer() | nil,
          optional(:subject_verification) => subject_verification(),
          optional(:court_admission) => CourtManifest.admission(),
          required(:source_revision) => String.t() | nil,
          required(:court_revision) => String.t()
        }) :: %{
          gates: [{pos_integer(), map()}],
          gate_rows: [map()],
          tallies: map(),
          standing: atom(),
          gate_evidence: %{String.t() => String.t()},
          claim: String.t()
        }
  def recompute(%{profile: profile, courts: courts, results: results} = facts) do
    gates = gate_table(profile, courts, results)
    validation = facts.ocel_validation_status
    verification = Map.get(facts, :subject_verification, :not_claimed)

    ocel_admitted? =
      validation == :valid and facts.ocel_dropped == 0 and Map.get(facts, :ocel_gaps, 0) == 0

    court_admission = Map.get(facts, :court_admission, :not_evaluated)

    # §32: a claimed subject that does not verify never receives standing.
    # §137: evidence from court machinery that is not the admitted court
    # manifest is never crowned CONFORMANT.
    standing =
      if match?({:mismatch, _, _}, verification),
        do: :refused,
        else: standing(results, gates, ocel_admitted?)

    {standing, court_blocked?} =
      if standing == :conformant and match?({:drift, _, _}, court_admission),
        do: {:partial_alive, true},
        else: {standing, false}

    %{
      gates: gates,
      gate_rows: Enum.map(gates, fn {gate, info} -> Map.put(info, "gate", gate) end),
      tallies: tallies(results, gates),
      standing: standing,
      gate_evidence: %{
        "independent_postcondition" => gate_evidence(gates, 8),
        "receipt_binding" => gate_evidence(gates, 9),
        "replay" => gate_evidence(gates, 10),
        "fresh_consumer" => gate_evidence(gates, 11)
      },
      claim:
        if court_blocked? do
          {:drift, _, fields} = court_admission

          "#{Profile.name(profile)} PARTIAL_ALIVE for subject " <>
            "#{facts.source_revision || "unknown-revision"}: court machinery not admitted " <>
            "(court manifest drift: #{Enum.join(fields, ", ")})"
        else
          claim(
            standing,
            profile,
            facts.source_revision,
            facts.court_revision,
            results,
            gates,
            validation,
            verification
          )
        end
    }
  end

  @typedoc "Outcome of `AshA2A.Chicago.Subject.verify_claim/2` (§32)."
  @type subject_verification ::
          :not_claimed
          | {:match, String.t() | nil}
          | {:mismatch, String.t() | nil, [atom() | String.t()]}

  @doc """
  Decodes a receipt's `subject.verification` object back into the
  `t:subject_verification/0` term `recompute/1` consumes -- the inverse of the
  wire form `build/1` writes. Absent (pre-§32 receipt) -> `:not_claimed`. A
  malformed object decodes to `:not_claimed` as well, so a receipt whose
  recorded standing depended on it cannot be reproduced (fail closed).
  """
  @spec verification_from_map(term()) :: subject_verification()
  def verification_from_map(%{"outcome" => "mismatch", "claimed_identity" => c, "fields" => fs})
      when (is_binary(c) or is_nil(c)) and is_list(fs) do
    if Enum.all?(fs, &is_binary/1), do: {:mismatch, c, fs}, else: :not_claimed
  end

  def verification_from_map(%{"outcome" => "match", "claimed_identity" => c})
      when is_binary(c) or is_nil(c),
      do: {:match, c}

  def verification_from_map(_), do: :not_claimed

  @doc "sha256 over the canonical JSON of the receipt without `receipt_digest`."
  @spec digest(map()) :: String.t()
  def digest(receipt) do
    receipt
    |> Map.delete("receipt_digest")
    |> Subject.canonical_json()
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end

  @doc "Re-verifies a receipt's content digest (for fresh consumers)."
  @spec verify_digest(map()) :: :ok | {:error, :receipt_digest_mismatch}
  def verify_digest(%{"receipt_digest" => d} = receipt),
    do: if(digest(receipt) == d, do: :ok, else: {:error, :receipt_digest_mismatch})

  @spec court_revision([module()]) :: String.t()
  def court_revision(courts) do
    foundation = [
      AshA2A.Chicago.Runner,
      AshA2A.Chicago.Result,
      AshA2A.Chicago.Query,
      AshA2A.Chicago.Observer,
      AshA2A.Chicago.StandingReceipt,
      AshA2A.Chicago.Ocel.Log
    ]

    (foundation ++ courts)
    |> Enum.uniq()
    |> Enum.map(fn m -> [inspect(m), Base.encode16(m.module_info(:md5), case: :lower)] end)
    |> Enum.sort()
    |> then(&[@specification | &1])
    |> JSON.encode!()
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end

  @doc "Falsifier-corpus digest bound by the receipt (§137)."
  @spec corpus_digest([Falsifier.t()]) :: String.t()
  def corpus_digest(falsifiers) do
    falsifiers
    |> Enum.sort_by(& &1.id)
    |> Enum.map(&Falsifier.to_map/1)
    |> Subject.canonical_json()
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end

  @doc "Conformance query-set digest bound by the receipt (§21, §137)."
  @spec query_set_digest([Falsifier.t()]) :: String.t()
  def query_set_digest(falsifiers) do
    falsifiers
    |> Enum.sort_by(& &1.id)
    |> Enum.map(fn f ->
      [
        f.id,
        f.attempt_predicate && Query.predicate_to_json(f.attempt_predicate),
        f.outcome_predicate && Query.predicate_to_json(f.outcome_predicate)
      ]
    end)
    |> JSON.encode!()
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end

  # --- gates & standing ------------------------------------------------------

  defp gate_table(profile, courts, results) do
    required = Profile.required_gates(profile)
    present = courts |> Enum.map(& &1.gate) |> Enum.reject(&is_nil/1)

    (required ++ present)
    |> Enum.uniq()
    |> Enum.sort()
    |> Map.new(fn gate ->
      gate_results = Enum.filter(results, &(&1.gate == gate))
      counted = Enum.reject(gate_results, &(&1.verdict in [:unsupported, :not_applicable]))

      status =
        cond do
          gate_results == [] -> "MISSING"
          Enum.any?(counted, &(Result.failed?(&1) or &1.verdict == :build_broken)) -> "FAILED"
          counted != [] and Enum.all?(counted, &Result.counts_as_pass?/1) -> "PASSED"
          true -> "OPEN"
        end

      {gate,
       %{
         "required" => gate in required,
         "status" => status,
         "attempted" => Enum.any?(gate_results, &(&1.attempt_observed? == true)),
         "courts" => courts |> Enum.filter(&(&1.gate == gate)) |> Enum.map(& &1.id) |> Enum.sort()
       }}
    end)
    |> Enum.sort_by(&elem(&1, 0))
  end

  defp standing(results, gates, ocel_admitted?) do
    counted = Enum.reject(results, &(&1.verdict in [:unsupported, :not_applicable]))

    required_passed =
      gates
      |> Enum.filter(fn {_g, info} -> info["required"] end)
      |> Enum.all?(fn {_g, info} -> info["status"] == "PASSED" end)

    cond do
      Enum.any?(counted, &(&1.verdict == :build_broken)) ->
        :build_broken

      Enum.any?(counted, &Result.failed?/1) ->
        :nonconformant

      counted != [] and Enum.all?(counted, &Result.counts_as_pass?/1) and required_passed and
          ocel_admitted? ->
        :conformant

      Enum.any?(counted, &Result.counts_as_pass?/1) ->
        :partial_alive

      true ->
        :unknown
    end
  end

  defp tallies(results, gates) do
    count = fn pred -> Enum.count(results, pred) end
    required = Enum.filter(gates, fn {_g, i} -> i["required"] end)

    %{
      "gates_required" => length(required),
      "gates_attempted" => Enum.count(gates, fn {_g, i} -> i["attempted"] end),
      "gates_passed" => Enum.count(required, fn {_g, i} -> i["status"] == "PASSED" end),
      "gates_failed" => Enum.count(required, fn {_g, i} -> i["status"] == "FAILED" end),
      "gates_open" => Enum.count(required, fn {_g, i} -> i["status"] == "OPEN" end),
      "gates_missing" => Enum.count(required, fn {_g, i} -> i["status"] == "MISSING" end),
      "falsifiers_total" => length(results),
      "falsifiers_killed" =>
        count.(&(&1.verdict == :falsifier_killed and Result.counts_as_pass?(&1))),
      "falsifiers_survived" => count.(&(&1.verdict == :falsifier_survived)),
      "positive_controls_passed" =>
        count.(&(&1.verdict == :positive_control_passed and Result.counts_as_pass?(&1))),
      "positive_controls_failed" => count.(&(&1.verdict == :positive_control_failed)),
      "measured" => count.(&(&1.verdict == :measured and Result.counts_as_pass?(&1))),
      "uncorroborated" =>
        count.(&(Result.passing_verdict?(&1) and not Result.counts_as_pass?(&1))),
      "unknown" => count.(&(&1.verdict == :unknown)),
      "blocked" => count.(&(&1.verdict == :blocked)),
      "build_broken" => count.(&(&1.verdict == :build_broken)),
      "unsupported" => count.(&(&1.verdict == :unsupported)),
      "not_applicable" => count.(&(&1.verdict == :not_applicable)),
      "survived_ids" =>
        results |> Enum.filter(&Result.failed?/1) |> Enum.map(& &1.falsifier_id) |> Enum.sort(),
      "unresolved_ids" =>
        results
        |> Enum.filter(
          &(&1.verdict in [:unknown, :blocked] or
              (Result.passing_verdict?(&1) and not Result.counts_as_pass?(&1)))
        )
        |> Enum.map(& &1.falsifier_id)
        |> Enum.sort()
    }
  end

  defp verification_map(:not_claimed), do: %{"outcome" => "not_claimed"}

  defp verification_map({:match, claimed}),
    do: %{"outcome" => "match", "claimed_identity" => claimed, "fields" => []}

  defp verification_map({:mismatch, claimed, fields}),
    do: %{
      "outcome" => "mismatch",
      "claimed_identity" => claimed,
      "fields" => Enum.map(fields, &Atom.to_string/1),
      "failure_class" => "IDENTITY_FAILURE"
    }

  defp gate_evidence(gates, gate) do
    case List.keyfind(gates, gate, 0) do
      nil -> "NOT_OBSERVED"
      {_, %{"status" => "PASSED"}} -> "PASS"
      {_, %{"status" => "FAILED"}} -> "FAIL"
      {_, %{"status" => "MISSING"}} -> "NOT_OBSERVED"
      {_, _} -> "OPEN"
    end
  end

  defp claim(
         standing,
         profile,
         source_revision,
         court_revision,
         results,
         gates,
         validation,
         verification
       ) do
    name = Profile.name(profile)
    rev = source_revision || "unknown-revision"
    court = String.slice(court_revision, 0, 12)

    case standing do
      :refused ->
        {:mismatch, claimed, fields} = verification

        "#{name} REFUSED: claimed subject #{String.slice(claimed || "unreadable", 0, 12)} " <>
          "does not verify against executed subject #{rev} (#{Enum.join(fields, ", ")})"

      :conformant ->
        "#{name} CONFORMANT for exact subject #{rev} under court revision #{court}"

      :nonconformant ->
        ids = results |> Enum.filter(&Result.failed?/1) |> Enum.map_join(", ", & &1.falsifier_id)
        "#{name} NONCONFORMANT: #{ids} survived"

      :build_broken ->
        "#{name} BUILD_BROKEN for subject #{rev}"

      other ->
        open =
          gates
          |> Enum.filter(fn {_g, i} -> i["required"] and i["status"] != "PASSED" end)
          |> Enum.map_join(", ", fn {g, i} -> "gate #{g} #{i["status"]}" end)

        ocel = if validation == :valid, do: "", else: "; OCEL validation #{validation}"

        "#{name} #{FailureClass.wire(other)} for subject #{rev}: #{Enum.count(results, &Result.counts_as_pass?/1)}/#{length(results)} corroborated passes" <>
          if(open == "", do: "", else: "; open: " <> open) <> ocel
    end
  end
end
