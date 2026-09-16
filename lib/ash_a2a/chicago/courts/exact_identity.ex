defmodule AshA2A.Chicago.Courts.ExactIdentity do
  @moduledoc """
  Gate 1 -- Exact Identity Fenced (RFC-SA2A-002 §5, §6, §32, §119, §120, §126).

  Evidence question (§32): did the execution that produced the claimed
  standing remain bound to one exact admitted subject identity?

  Every attack runs against real environments built by
  `AshA2A.Chicago.Fixtures.Identity`: real scratch git repositories with real
  commits, a real mutable branch and a real annotated final tag, real
  executable wasm bytes, a real N-Triples root manifest, and a real SHACL/N3
  rule set in its own git repository.

    * CHI-ID-001..005 -- a subject claim captured before the mutation is
      presented to the real `AshA2A.Chicago.Runner` (`:claimed_subject`)
      while the real environment has moved (branch, executable artifact,
      root manifest, validator rule set, final tag). Killed only when
      `AshA2A.Chicago.Subject.verify/2` names the mismatched identity field
      BEFORE the runner issues standing, and the issued standing is REFUSED.
    * CHI-ID-006..007 -- two views of one runtime presented to the real
      `AshA2A.SA2A.Conformance` as heterogeneous hosts: a whitespace-padded
      host label, and fully different labels over the same executing engine.
      Killed only when the court refuses the run as degenerate before judging.
    * CHI-ID-010..011 -- a durable prior standing receipt (read back from
      disk) offered to `AshA2A.Chicago.Requalification.decide/3` for a newer
      CalVer on the same commit, and for a changed validator rule set.
    * CHI-ID-008, 009, 012 -- positive controls (§100): an unchanged subject
      verifies and gets non-REFUSED standing; genuinely heterogeneous runtimes
      (in-BEAM Wasmtime vs out-of-BEAM JavaScript engine) are admitted on
      observed executable identity and judged; an unchanged subject reuses its
      prior standing.

  Attempt evidence always comes from telemetry the deciding boundary emits
  (`[:ash_a2a, :chicago, :subject, :verified]`,
  `[:ash_a2a, :chicago, :run, :stop]` (`AshA2A.Chicago.Runner.stop_event/0`),
  `[:ash_a2a, :sa2a, :conformance, :runtime_identity | :judged]`,
  `[:ash_a2a, :chicago, :requalification, :decided]`), never from this court.
  """

  use AshA2A.Chicago.Court

  alias AshA2A.Chicago.{Context, Falsifier, Requalification, Result, Runner, Subject}
  alias AshA2A.Chicago.Fixtures.Identity, as: Fx
  alias AshA2A.Chicago.Ocel.Mapping
  alias AshA2A.GraphLaw.{RuntimeB, WasmexSession}
  alias AshA2A.SA2A.Conformance

  @court "CHI-ID"

  @identity_boundary "AshA2A.Chicago.Subject.verify/2 driven by AshA2A.Chicago.Runner :claimed_subject, " <>
                       "before AshA2A.Chicago.StandingReceipt issues standing"

  @runtime_boundary "AshA2A.SA2A.Conformance degenerate-run refusal (runtime identity)"
  @requalification_boundary "AshA2A.Chicago.Requalification.decide/3"

  @impl true
  def id, do: @court

  @impl true
  def title, do: "Gate 1 -- exact identity fenced"

  @impl true
  def gate, do: 1

  @impl true
  def profile, do: :core

  @impl true
  def rfc_sections, do: ["§5", "§6", "§32", "§100", "§119", "§120", "§126"]

  # --- declarations (§11) ------------------------------------------------------

  @impl true
  def falsifiers do
    [
      claimed_subject_attack(
        1,
        "source_revision",
        "A mutable branch name confers nothing: execution at a moved branch must not carry " <>
          "the standing of an earlier claimed SHA (§5)",
        "claim captured at qualification@c1; a real commit c2 moves the branch; " <>
          "Runner.run(claimed_subject: claim) over the moved checkout",
        "Subject.verify/2 source_revision comparison + Runner claimed-subject refusal"
      ),
      claimed_subject_attack(
        2,
        "artifact_digests",
        "Substituting the executable artifact while the source revision is unchanged is a " <>
          "different subject (§5 executable artifact digest)",
        "claim captured; dist/graphlaw.wasm replaced by still-valid wasm bytes (extra custom " <>
          "section), source revision untouched; Runner.run(claimed_subject: claim)",
        "Subject.verify/2 artifact_digests comparison + Runner claimed-subject refusal"
      ),
      claimed_subject_attack(
        3,
        "root_manifest_digest",
        "An altered root manifest is a different subject (§5 root-manifest digest, §53)",
        "claim captured; one triple of dist/root_manifest.nt altered; " <>
          "Runner.run(claimed_subject: claim)",
        "Subject.capture/1 :root_manifest digest + verify/2 comparison + Runner refusal"
      ),
      claimed_subject_attack(
        4,
        "validator_digests",
        "A different validator / rule-set revision is a different subject (§5 validator " <>
          "identities)",
        "claim captured; rules repo commits r2 relaxing sh:minCount; " <>
          "Runner.run(claimed_subject: claim)",
        "Subject.capture/1 :validators digests + verify/2 comparison + Runner refusal"
      ),
      claimed_subject_attack(
        5,
        "tag_commit",
        "TagCommit = VerifiedCommit: a final tag resolving to a different commit confers " <>
          "no release identity (§5, §6)",
        "claim captured at tag v26.9.16 -> c1; the tag is force-moved to c2 on another " <>
          "branch while the checkout stays at c1; Runner.run(claimed_subject: claim)",
        "Subject.capture/1 refs/tags/<tag>^{commit} resolution + verify/2 TagCommit check"
      ),
      runtime_attack(
        6,
        "Changing only a whitespace-normalized host label is not evidence of heterogeneity " <>
          "(§126)",
        "Conformance.run(runtime_a: WasmexSession, runtime_b: PaddedHostRuntime) where the " <>
          "padded runtime is WasmexSession with host_id \"BEAM/Wasmex \"",
        "Conformance.refuse_identical/2 normalized label comparison (RuntimeIdentity.label_key/1), " <>
          "backed by the observed-executable identity check; survives only with both removed"
      ),
      runtime_attack(
        7,
        "Runtime identity is established from independently observable executable " <>
          "information, not caller-controlled labels (§126)",
        "Conformance.run(runtime_a: WasmexSession, runtime_b: RelabelledHostRuntime) where the " <>
          "relabelled runtime reports WASI/StandaloneHost + wasm3 but executes in the same " <>
          "in-BEAM Wasmtime engine",
        "Conformance observed-executable identity check (RuntimeIdentity.observe_session/1)"
      ),
      Falsifier.new!(
        id: "CHI-ID-008",
        court_id: @court,
        kind: :positive_control,
        invariant:
          "An unchanged exact subject verifies and receives non-REFUSED standing: the " <>
            "identity boundary discriminates rather than refusing every claim (§100)",
        stimulus:
          "claim captured from a fully bound release (branch, tag, artifact, manifest, rule " <>
            "set); nothing mutated; Runner.run(claimed_subject: claim)",
        boundary: @identity_boundary,
        attempt_evidence: "chicago.subject.verified observed for the stimulus",
        survival_evidence:
          "verified outcome=match; chicago.run.stop with verification match and a " <>
            "standing other than REFUSED, issued after verification of the same subject",
        rfc_sections: ["§32", "§100"],
        attempt_predicate: {:observed, "chicago.subject.verified"},
        outcome_predicate:
          {:all,
           [
             {:observed, "chicago.subject.verified", %{"outcome" => "match"}},
             {:observed, "chicago.run.stop", %{"subject_verification" => "match"}},
             {:not_observed, "chicago.run.stop", %{"standing" => "REFUSED"}},
             {:precedes, "chicago.subject.verified", "chicago.run.stop", "subject"}
           ]}
      ),
      Falsifier.new!(
        id: "CHI-ID-009",
        court_id: @court,
        kind: :positive_control,
        invariant:
          "Genuinely heterogeneous runtimes are admitted on observed executable identity and " <>
            "judged: the degenerate-run refusal discriminates (§100, §126)",
        stimulus:
          "Conformance.run(runtime_a: WasmexSession, runtime_b: RuntimeB) over a one-vector " <>
            "copy of the real corpus",
        boundary: @runtime_boundary,
        attempt_evidence: "sa2a.conformance.runtime_identity observed for the stimulus",
        survival_evidence:
          "runtime_identity outcome=distinct basis=observed_executable, then " <>
            "sa2a.conformance.judged",
        rfc_sections: ["§100", "§126"],
        attempt_predicate: {:observed, "sa2a.conformance.runtime_identity"},
        outcome_predicate:
          {:all,
           [
             {:observed, "sa2a.conformance.runtime_identity",
              %{"outcome" => "distinct", "basis" => "observed_executable"}},
             {:observed, "sa2a.conformance.judged"},
             {:precedes, "sa2a.conformance.runtime_identity", "sa2a.conformance.judged",
              "runtime"}
           ]}
      ),
      Falsifier.new!(
        id: "CHI-ID-010",
        court_id: @court,
        kind: :negative,
        invariant:
          "A newer CalVer must not inherit conformance merely because its version number is " <>
            "greater (§120)",
        stimulus:
          "prior standing receipt issued for tag v26.9.16 at c1 and read back from disk; tag " <>
            "v26.9.17 added at the same commit; Requalification.decide(prior, subject@v26.9.17)",
        boundary: @requalification_boundary,
        forbidden_outcome: "prior standing reused for the newer version",
        attempt_evidence:
          "chicago.requalification.decided with prior_version 26.9.16 and new_version 26.9.17",
        survival_evidence:
          "decision outcome=reuse, or gate 1 absent from the requalification set",
        guard:
          "Requalification.changed_fields/2 compares version/tag for equality (never order) + " <>
            "gates_for_fields/1",
        failure_class: :identity_failure,
        rfc_sections: ["§6", "§120"],
        attempt_predicate:
          {:observed, "chicago.requalification.decided",
           %{"prior_version" => "26.9.16", "new_version" => "26.9.17"}},
        outcome_predicate:
          {:any,
           [
             {:observed, "chicago.requalification.decided", %{"outcome" => "reuse"}},
             {:not_observed, "chicago.requalification.decided", %{"gate.1" => "true"}}
           ]}
      ),
      Falsifier.new!(
        id: "CHI-ID-011",
        court_id: @court,
        kind: :negative,
        invariant:
          "A changed validator/rule revision triggers requalification of the dependent " <>
            "admission gate; prior standing is not reused (§119)",
        stimulus:
          "prior standing receipt read back from disk; rules repo commits r2; " <>
            "Requalification.decide(prior, recaptured subject)",
        boundary: @requalification_boundary,
        forbidden_outcome:
          "prior standing reused, or validator change not mapped to gate 2 requalification",
        attempt_evidence: "chicago.requalification.decided observed for the stimulus",
        survival_evidence:
          "decision outcome=reuse, or no decision naming validator_digests with gate 2",
        guard: "Requalification field->gate map (validator_digests -> 1, 2, 5, 12)",
        failure_class: :validator_failure,
        rfc_sections: ["§119"],
        attempt_predicate: {:observed, "chicago.requalification.decided"},
        outcome_predicate:
          {:any,
           [
             {:observed, "chicago.requalification.decided", %{"outcome" => "reuse"}},
             {:not_observed, "chicago.requalification.decided",
              %{"field.validator_digests" => "true", "gate.2" => "true"}}
           ]}
      ),
      Falsifier.new!(
        id: "CHI-ID-012",
        court_id: @court,
        kind: :positive_control,
        invariant:
          "A prior standing MAY be reused when every relevant identity is unchanged: the " <>
            "requalification boundary discriminates (§100, §119)",
        stimulus:
          "prior standing receipt read back from disk; subject recaptured with nothing " <>
            "changed; Requalification.decide(prior, subject)",
        boundary: @requalification_boundary,
        attempt_evidence: "chicago.requalification.decided observed for the stimulus",
        survival_evidence: "decision outcome=reuse with no changed fields",
        rfc_sections: ["§100", "§119"],
        attempt_predicate: {:observed, "chicago.requalification.decided"},
        outcome_predicate:
          {:observed, "chicago.requalification.decided", %{"outcome" => "reuse", "fields" => ""}}
      )
    ]
  end

  defp claimed_subject_attack(n, field, invariant, stimulus, guard) do
    Falsifier.new!(
      id: "CHI-ID-00#{n}",
      court_id: @court,
      kind: :negative,
      invariant: invariant,
      stimulus: stimulus,
      boundary: @identity_boundary,
      forbidden_outcome:
        "standing issued for the claimed subject without an identity refusal naming #{field}",
      attempt_evidence:
        "chicago.subject.verified observed for the stimulus (the claim reached the identity boundary)",
      survival_evidence:
        "no chicago.subject.verified mismatch naming #{field}; or no REFUSED " <>
          "chicago.run.stop; or standing issued with verification match; or standing " <>
          "issued before verification",
      guard: guard,
      failure_class: :identity_failure,
      rfc_sections: ["§5", "§6", "§32"],
      attempt_predicate: {:observed, "chicago.subject.verified"},
      outcome_predicate:
        {:any,
         [
           {:not_observed, "chicago.subject.verified",
            %{"outcome" => "mismatch", "mismatch.#{field}" => "true"}},
           {:not_observed, "chicago.run.stop",
            %{"standing" => "REFUSED", "subject_verification" => "mismatch"}},
           {:observed, "chicago.run.stop", %{"subject_verification" => "match"}},
           {:not, {:precedes, "chicago.subject.verified", "chicago.run.stop", "subject"}}
         ]}
    )
  end

  defp runtime_attack(n, invariant, stimulus, guard) do
    Falsifier.new!(
      id: "CHI-ID-00#{n}",
      court_id: @court,
      kind: :negative,
      invariant: invariant,
      stimulus: stimulus,
      boundary: @runtime_boundary,
      forbidden_outcome:
        "the two views of one runtime are admitted as distinct hosts and a cross-runtime " <>
          "result is judged",
      attempt_evidence: "sa2a.conformance.runtime_identity decision observed for the stimulus",
      survival_evidence:
        "sa2a.conformance.runtime_identity outcome=distinct, or sa2a.conformance.judged observed",
      guard: guard,
      failure_class: :identity_failure,
      rfc_sections: ["§76", "§126"],
      attempt_predicate: {:observed, "sa2a.conformance.runtime_identity"},
      outcome_predicate:
        {:any,
         [
           {:observed, "sa2a.conformance.runtime_identity", %{"outcome" => "distinct"}},
           {:observed, "sa2a.conformance.judged"}
         ]}
    )
  end

  # --- OCEL mappings (§17) -----------------------------------------------------

  @impl true
  def ocel_mappings do
    [
      Mapping.new!(
        event: Subject.verified_event(),
        activity: "chicago.subject.verified",
        source: __MODULE__,
        objects: fn _m, meta ->
          uniq_refs([
            {"subject", meta[:observed_identity], "observed_subject"},
            {"subject", meta[:claimed_identity], "claimed_subject"},
            {"revision", meta[:source_revision], "observed_revision"},
            {"revision", meta[:claimed_source_revision], "claimed_revision"}
          ])
        end,
        attributes: fn _m, meta ->
          fields = Enum.map(List.wrap(meta[:fields]), &to_string/1)

          Map.merge(
            %{"outcome" => meta[:outcome], "fields" => Enum.join(fields, ",")},
            Map.new(fields, &{"mismatch." <> &1, true})
          )
        end
      ),
      # The runner's one standing-issued event, shared with the observer
      # court (SA2A-OCEL-OBSERVER); the runner admits the mapping once.
      Runner.stop_mapping(),
      Mapping.new!(
        event: [:ash_a2a, :sa2a, :conformance, :runtime_identity],
        activity: "sa2a.conformance.runtime_identity",
        source: __MODULE__,
        objects: &runtime_refs/2,
        attributes: fn _m, meta -> Map.take(meta, [:outcome, :basis, :code]) end
      ),
      Mapping.new!(
        event: [:ash_a2a, :sa2a, :conformance, :judged],
        activity: "sa2a.conformance.judged",
        source: __MODULE__,
        objects: &runtime_refs/2,
        attributes: fn _m, meta -> Map.take(meta, [:result]) end
      ),
      Mapping.new!(
        event: Requalification.decided_event(),
        activity: "chicago.requalification.decided",
        source: __MODULE__,
        objects: fn _m, meta ->
          uniq_refs([
            {"subject", meta[:prior_identity], "prior_subject"},
            {"subject", meta[:new_identity], "new_subject"},
            {"standing_receipt", meta[:prior_receipt_digest], "prior_receipt"}
          ])
        end,
        attributes: fn _m, meta ->
          fields = Enum.map(List.wrap(meta[:fields]), &to_string/1)
          gates = List.wrap(meta[:gates])

          %{
            "outcome" => meta[:outcome],
            "fields" => Enum.join(fields, ","),
            "gates" => Enum.join(gates, ","),
            "prior_version" => meta[:prior_version],
            "new_version" => meta[:new_version],
            "prior_standing" => meta[:prior_standing]
          }
          |> Map.merge(Map.new(fields, &{"field." <> &1, true}))
          |> Map.merge(Map.new(gates, &{"gate.#{&1}", true}))
        end
      )
    ]
  end

  defp runtime_refs(_m, meta) do
    uniq_refs([
      {"runtime", meta[:runtime_a], "runtime_a"},
      {"runtime", meta[:runtime_b], "runtime_b"},
      {"runtime_executable", meta[:observed_a], "observed_a"},
      {"runtime_executable", meta[:observed_b], "observed_b"}
    ])
  end

  defp uniq_refs(refs), do: Enum.uniq_by(refs, fn {type, id, _q} -> {type, id} end)

  # --- execution ---------------------------------------------------------------

  @impl true
  def run(%Context{} = ctx) do
    root = Path.join(ctx.evidence_dir, "chi-id")
    File.mkdir_p!(root)
    f = Map.new(falsifiers(), &{&1.id, &1})

    [
      guarded(f["CHI-ID-001"], fn ->
        run_claimed_subject_attack(
          ctx,
          f["CHI-ID-001"],
          root,
          "branch",
          "source_revision",
          &Fx.advance_branch!/1
        )
      end),
      guarded(f["CHI-ID-002"], fn ->
        run_claimed_subject_attack(
          ctx,
          f["CHI-ID-002"],
          root,
          "artifact",
          "artifact_digests",
          &Fx.substitute_artifact!/1
        )
      end),
      guarded(f["CHI-ID-003"], fn ->
        run_claimed_subject_attack(
          ctx,
          f["CHI-ID-003"],
          root,
          "manifest",
          "root_manifest_digest",
          &Fx.alter_manifest!/1
        )
      end),
      guarded(f["CHI-ID-004"], fn ->
        run_claimed_subject_attack(
          ctx,
          f["CHI-ID-004"],
          root,
          "rules",
          "validator_digests",
          &Fx.revise_rules!/1
        )
      end),
      guarded(f["CHI-ID-005"], fn ->
        run_claimed_subject_attack(
          ctx,
          f["CHI-ID-005"],
          root,
          "tag",
          "tag_commit",
          &Fx.move_tag!/1
        )
      end),
      guarded(f["CHI-ID-006"], fn ->
        run_runtime_attack(ctx, f["CHI-ID-006"], root, Fx.PaddedHostRuntime)
      end),
      guarded(f["CHI-ID-007"], fn ->
        run_runtime_attack(ctx, f["CHI-ID-007"], root, Fx.RelabelledHostRuntime)
      end),
      guarded(f["CHI-ID-008"], fn -> run_unchanged_subject(ctx, f["CHI-ID-008"], root) end),
      guarded(f["CHI-ID-009"], fn -> run_heterogeneous_runtimes(ctx, f["CHI-ID-009"], root) end),
      guarded(f["CHI-ID-010"], fn -> run_newer_calver(ctx, f["CHI-ID-010"], root) end),
      guarded(f["CHI-ID-011"], fn -> run_changed_validator(ctx, f["CHI-ID-011"], root) end),
      guarded(f["CHI-ID-012"], fn -> run_unchanged_reuse(ctx, f["CHI-ID-012"], root) end)
    ]
  end

  # One broken edge must not take the other falsifiers with it (§129-§130):
  # a raise becomes UNKNOWN for that falsifier only, never a pass.
  defp guarded(%Falsifier{} = f, fun) do
    fun.()
  rescue
    exception ->
      Result.unknown(f, "raised: " <> Exception.format(:error, exception, __STACKTRACE__))
  end

  # CHI-ID-001..005
  defp run_claimed_subject_attack(ctx, f, root, name, field, mutate) do
    release = Fx.release!(root, name)
    claim = Subject.capture(release.subject_opts)
    mutation = mutate.(release)
    standing_dir = Path.join(root, name <> "-standing")

    run_result =
      Context.stimulus(ctx, f, fn ->
        Runner.run(
          courts: [],
          profile: :core,
          claimed_subject: claim,
          subject_opts: release.subject_opts,
          evidence_dir: standing_dir,
          run_id: ctx.run_id <> "-" <> f.id
        )
      end)

    # Independent post-state: the durable receipt on disk, not the runner's
    # return value.
    receipt = read_receipt(standing_dir)
    verification = get_in(receipt || %{}, ["subject", "verification"]) || %{}
    fields = verification["fields"] || []

    forbidden =
      case receipt do
        nil ->
          :unknown

        receipt ->
          not (receipt["standing"] == "REFUSED" and verification["outcome"] == "mismatch" and
                 field in fields)
      end

    Result.negative(f,
      attempt_observed?: Context.observed?(ctx, f, "chicago.subject.verified"),
      forbidden_outcome_observed?: forbidden,
      evidence: %{
        "mutation" => inspect(mutation),
        "claimed_source_revision" => claim.source_revision,
        "observed_source_revision" => receipt && get_in(receipt, ["subject", "source_revision"]),
        "claimed_identity" => Subject.digest(claim),
        "observed_identity" => receipt && get_in(receipt, ["subject", "identity"]),
        "standing" => receipt && receipt["standing"],
        "claim" => receipt && receipt["claim"],
        "verification" => verification,
        "runner" => run_result |> elem(0) |> inspect()
      }
    )
  end

  # CHI-ID-008
  defp run_unchanged_subject(ctx, f, root) do
    release = Fx.release!(root, "unchanged")
    claim = Subject.capture(release.subject_opts)
    standing_dir = Path.join(root, "unchanged-standing")

    Context.stimulus(ctx, f, fn ->
      Runner.run(
        courts: [],
        profile: :core,
        claimed_subject: claim,
        subject_opts: release.subject_opts,
        evidence_dir: standing_dir,
        run_id: ctx.run_id <> "-" <> f.id
      )
    end)

    receipt = read_receipt(standing_dir)
    verification = get_in(receipt || %{}, ["subject", "verification"]) || %{}

    expected =
      case receipt do
        nil ->
          :unknown

        receipt ->
          receipt["standing"] != "REFUSED" and verification["outcome"] == "match" and
            get_in(receipt, ["subject", "identity"]) == Subject.digest(claim)
      end

    Result.positive(f,
      attempt_observed?: Context.observed?(ctx, f, "chicago.subject.verified"),
      expected_outcome_observed?: expected,
      evidence: %{
        "claimed_identity" => Subject.digest(claim),
        "standing" => receipt && receipt["standing"],
        "verification" => verification,
        "tag_commit" => claim.tag_commit,
        "source_revision" => claim.source_revision
      }
    )
  end

  # CHI-ID-006..007
  defp run_runtime_attack(ctx, f, root, runtime) do
    corpus = Fx.one_vector_corpus!(Path.join(root, f.id))

    result =
      Context.stimulus(ctx, f, fn ->
        Conformance.run(runtime_a: WasmexSession, runtime_b: runtime, corpus_dir: corpus)
      end)

    decisions = identity_decisions(ctx, f)

    Result.negative(f,
      attempt_observed?: decisions != [],
      forbidden_outcome_observed?:
        judged?(result) or Enum.any?(decisions, &(&1["outcome"] == "distinct")),
      evidence: %{
        "runtime_b" => inspect(runtime),
        "labels" => [
          inspect(AshA2A.GraphLaw.Runtime.identity(WasmexSession)),
          inspect(AshA2A.GraphLaw.Runtime.identity(runtime))
        ],
        "decisions" => decisions,
        "result" => summarize(result)
      }
    )
  end

  # CHI-ID-009
  defp run_heterogeneous_runtimes(ctx, f, root) do
    with :ok <- WasmexSession.available?([]),
         :ok <- RuntimeB.available?([]) do
      corpus = Fx.one_vector_corpus!(Path.join(root, f.id))

      result =
        Context.stimulus(ctx, f, fn ->
          Conformance.run(runtime_a: WasmexSession, runtime_b: RuntimeB, corpus_dir: corpus)
        end)

      decisions = identity_decisions(ctx, f)

      Result.positive(f,
        attempt_observed?: decisions != [],
        expected_outcome_observed?:
          judged?(result) and
            Enum.any?(
              decisions,
              &(&1["outcome"] == "distinct" and &1["basis"] == "observed_executable")
            ),
        evidence: %{"decisions" => decisions, "result" => summarize(result)}
      )
    else
      {:error, reason} ->
        Result.blocked(f, "a real runtime is unavailable on this machine: #{inspect(reason)}")
    end
  end

  # CHI-ID-010
  defp run_newer_calver(ctx, f, root) do
    release = Fx.release!(root, "calver")
    prior = prior_receipt!(ctx, f, release, root, "calver")
    newer = Fx.tag_newer_calver!(release)
    new_subject = Subject.capture(Keyword.put(release.subject_opts, :tag, newer))

    decision = Context.stimulus(ctx, f, fn -> Requalification.decide(prior, new_subject) end)

    prior_subject = prior["subject"]

    isolated? =
      prior_subject["source_revision"] == new_subject.source_revision and
        prior_subject["version"] == "26.9.16" and new_subject.version == "26.9.17"

    # A decision about a subject whose source also moved would not isolate
    # the CalVer question, so it cannot count either way.
    forbidden =
      case {isolated?, decision} do
        {false, _} -> :unknown
        {true, {:reuse, _}} -> true
        {true, {:requalify, %{gates: gates}}} -> 1 not in gates
      end

    Result.negative(f,
      attempt_observed?: Context.observed?(ctx, f, "chicago.requalification.decided"),
      forbidden_outcome_observed?: forbidden,
      evidence: %{
        "prior_version" => prior_subject["version"],
        "new_version" => new_subject.version,
        "same_source_revision" => isolated?,
        "prior_standing" => prior["standing"],
        "decision" => inspect(decision)
      }
    )
  end

  # CHI-ID-011
  defp run_changed_validator(ctx, f, root) do
    release = Fx.release!(root, "requalify")
    prior = prior_receipt!(ctx, f, release, root, "requalify")
    r2 = Fx.revise_rules!(release)
    new_subject = Subject.capture(release.subject_opts)

    decision = Context.stimulus(ctx, f, fn -> Requalification.decide(prior, new_subject) end)

    forbidden =
      case decision do
        {:reuse, _} ->
          true

        {:requalify, %{fields: fields, gates: gates}} ->
          not ("validator_digests" in fields and 2 in gates)
      end

    Result.negative(f,
      attempt_observed?: Context.observed?(ctx, f, "chicago.requalification.decided"),
      forbidden_outcome_observed?: forbidden,
      evidence: %{"r1" => release.r1, "r2" => r2, "decision" => inspect(decision)}
    )
  end

  # CHI-ID-012
  defp run_unchanged_reuse(ctx, f, root) do
    release = Fx.release!(root, "reuse")
    prior = prior_receipt!(ctx, f, release, root, "reuse")
    new_subject = Subject.capture(release.subject_opts)

    decision = Context.stimulus(ctx, f, fn -> Requalification.decide(prior, new_subject) end)

    Result.positive(f,
      attempt_observed?: Context.observed?(ctx, f, "chicago.requalification.decided"),
      expected_outcome_observed?: decision == {:reuse, prior["standing"]},
      evidence: %{"prior_standing" => prior["standing"], "decision" => inspect(decision)}
    )
  end

  # A real prior standing: a real runner run over the release, its receipt
  # read back from disk as a fresh consumer would (setup, not the stimulus).
  defp prior_receipt!(ctx, f, release, root, name) do
    dir = Path.join(root, name <> "-prior-standing")

    {:ok, _run} =
      Runner.run(
        courts: [],
        profile: :core,
        subject_opts: release.subject_opts,
        evidence_dir: dir,
        run_id: ctx.run_id <> "-" <> f.id <> "-prior"
      )

    read_receipt(dir) || raise "prior standing receipt was not written to #{dir}"
  end

  defp read_receipt(dir) do
    with {:ok, bytes} <- File.read(Path.join(dir, "standing_receipt.json")),
         {:ok, receipt} <- JSON.decode(bytes) do
      receipt
    else
      _ -> nil
    end
  end

  defp identity_decisions(ctx, f) do
    ctx
    |> Context.observed(f)
    |> Enum.filter(&(&1.activity == "sa2a.conformance.runtime_identity"))
    |> Enum.map(& &1.attributes)
  end

  defp judged?({_, %{"result" => _}}), do: true
  defp judged?(_), do: false

  defp summarize({tag, %{"result" => result}}), do: %{"tag" => inspect(tag), "result" => result}

  defp summarize({tag, %{code: code} = reason}),
    do: %{"tag" => inspect(tag), "code" => inspect(code), "basis" => inspect(reason[:basis])}

  defp summarize(other), do: %{"raw" => inspect(other, limit: 10)}
end
