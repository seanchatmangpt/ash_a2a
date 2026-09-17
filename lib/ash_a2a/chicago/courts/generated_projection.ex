defmodule AshA2A.Chicago.Courts.GeneratedProjection do
  @moduledoc """
  RFC-SA2A-002 §77 Generated Projection court (RFC-SA2A-001 S23, S24, S27).

  Generated projections must not become independent semantic truth. Each
  falsifier modifies a generated projection by hand and checks, through the
  real boundaries, that the edit neither mutates canonical `O*` nor acquires
  standing:

    * the plan projection `P = pi_plan(O*)` built by the real
      `AshA2A.Semantic.PlanProjection.from_admitted/2` from an IR admitted by
      the real `AshA2A.Semantic.Admission.admit/2`: a plain content edit, a
      consistent forgery (edit + recomputed `projection_digest`) and a forged
      `standing`/`authority` fence, each re-verified against the authoritative
      graph by `PlanProjection.verify/2`;
    * the plan package built by the real `AshA2A.Semantic.PlanPackage`: a
      package manufactured from an edited projection, and a package whose
      `standing`/`authority` fence is rewritten with a recomputed `plan_digest`;
    * the generated Root Manifest (`priv/sa2a/root_manifest.json`, produced by
      `AshA2A.Semantic.RootManifest.ConformanceCorpus`): a hand edit loads
      through the real `RootManifest.load/2`.

  Canonical `O*` is read independently of the verdict path: the RFC S12
  RDFC-1.0 identity of the ontology's own serialization
  (`Fixtures.CanonicalIdentity.canonical_o_star/1`) and a re-derivation of the
  ontology from the admitted IR are compared before and after every edit.
  """

  use AshA2A.Chicago.Court

  alias AshA2A.Chicago.{Context, Falsifier, Result}
  alias AshA2A.Chicago.Fixtures.CanonicalIdentity, as: F
  alias AshA2A.Semantic.{Ontology, PlanPackage, PlanProjection, RootManifest}
  alias AshA2A.Semantic.RootManifest.ConformanceCorpus

  @court "SA2A-PROJECTION"

  @impl true
  def id, do: @court
  @impl true
  def title, do: "Manually modified generated projections do not mutate O* nor acquire standing"
  @impl true
  def gate, do: nil
  @impl true
  def profile, do: :plan
  @impl true
  def rfc_sections, do: ["§77", "§100", "RFC-SA2A-001 S23", "S24", "S27"]

  @impl true
  def ocel_mappings, do: F.mappings()

  @verify_attempt {:observed, "plan_projection.verify", %{"mode" => "graph"}}
  @verified {:observed, "plan_projection.verify", %{"outcome" => "verified"}}

  @impl true
  def falsifiers do
    [
      projection_negative(1,
        invariant:
          "A hand-edited plan projection (goals rewritten, digest untouched) is refused and O* is unchanged",
        stimulus: "PlanProjection.verify/2 of the projection with goals replaced",
        guard: "PlanProjection content-digest tamper check"
      ),
      projection_negative(2,
        invariant:
          "A consistent forgery (goals rewritten AND projection_digest recomputed) is refused against the authoritative graph",
        stimulus: "PlanProjection.verify/2 of Fixtures.CanonicalIdentity.consistent_forgery/1",
        guard:
          "PlanProjection.verify/2 graph-witness check (projection content must be witnessed by O*)"
      ),
      projection_negative(3,
        invariant:
          "A projection whose standing/authority fence is rewritten (standing: :admitted, authority: :full) is refused",
        stimulus:
          "PlanProjection.verify/2 of %{projection | standing: :admitted, authority: :full}",
        guard:
          "PlanProjection.verify/2 structural fence check (standing :derived, authority :none)"
      ),
      declare(4, :positive_control,
        invariant:
          "Positive control for 001-003: the untouched projection verifies against its graph",
        stimulus: "PlanProjection.verify/2 of the manufactured projection",
        boundary: "AshA2A.Semantic.PlanProjection.verify/2",
        attempt_evidence: "plan_projection.verify mode=graph observed",
        survival_evidence: "plan_projection.verify outcome=verified",
        attempt_predicate: @verify_attempt,
        outcome_predicate: @verified
      ),
      declare(5, :negative,
        invariant: "A plan package cannot be manufactured from a hand-edited projection",
        stimulus: "PlanPackage.from_projection/3 of the projection with goals replaced",
        boundary: "AshA2A.Semantic.PlanPackage.from_projection/3",
        forbidden_outcome: "a package is built",
        attempt_evidence: "plan_package.build observed",
        survival_evidence: "plan_package.build outcome=accepted",
        guard: "PlanPackage.verify_projection/1 (PlanProjection.verify_self/1)",
        failure_class: :planning_failure,
        attempt_predicate: {:observed, "plan_package.build"},
        outcome_predicate: {:observed, "plan_package.build", %{"outcome" => "accepted"}}
      ),
      declare(6, :negative,
        invariant:
          "A plan package whose standing/authority fence is rewritten with a recomputed plan_digest does not verify",
        stimulus: "PlanPackage.verify/1 of Fixtures.CanonicalIdentity.forged_package/1",
        boundary: "AshA2A.Semantic.PlanPackage.verify/1",
        forbidden_outcome: "the forged package verifies (standing :admitted, authority :full)",
        attempt_evidence: "plan_package.verify observed",
        survival_evidence: "plan_package.verify outcome=accepted",
        guard:
          "PlanPackage.verify/1 structural fence check (standing :candidate, authority :none)",
        failure_class: :planning_failure,
        attempt_predicate: {:observed, "plan_package.verify"},
        outcome_predicate: {:observed, "plan_package.verify", %{"outcome" => "accepted"}}
      ),
      declare(7, :positive_control,
        invariant: "Positive control for 005-006: the untouched package verifies as a candidate",
        stimulus: "PlanPackage.verify/1 of the manufactured strict package",
        boundary: "AshA2A.Semantic.PlanPackage.verify/1",
        attempt_evidence: "plan_package.verify observed",
        survival_evidence: "plan_package.verify outcome=accepted standing=candidate",
        attempt_predicate: {:observed, "plan_package.verify"},
        outcome_predicate:
          {:observed, "plan_package.verify",
           %{"outcome" => "accepted", "standing" => "candidate"}}
      ),
      declare(8, :negative,
        invariant:
          "A hand edit to the generated Root Manifest (trust-root mutation policy flipped) does not load",
        stimulus: "RootManifest.load/2 of Fixtures.CanonicalIdentity.hand_edited_manifest/1",
        boundary: "AshA2A.Semantic.RootManifest.load/2",
        forbidden_outcome: "the edited manifest loads",
        attempt_evidence: "root_manifest.load observed",
        survival_evidence: "root_manifest.load outcome=loaded",
        guard: "RootManifest.verify_self_address/2",
        failure_class: :meta_admission_failure,
        attempt_predicate: {:observed, "root_manifest.load"},
        outcome_predicate: {:observed, "root_manifest.load", %{"outcome" => "loaded"}}
      ),
      declare(9, :positive_control,
        invariant:
          "Positive control for 008: the committed generated manifest loads and equals its lawful manufacturer's rebuild",
        stimulus:
          "RootManifest.load/2 of the committed manifest; ConformanceCorpus.build/1 over the real corpus",
        boundary: "AshA2A.Semantic.RootManifest.load/2",
        attempt_evidence: "root_manifest.load observed",
        survival_evidence: "root_manifest.load outcome=loaded; loaded digest == rebuilt digest",
        attempt_predicate: {:observed, "root_manifest.load"},
        outcome_predicate: {:observed, "root_manifest.load", %{"outcome" => "loaded"}}
      )
    ]
  end

  defp projection_negative(n, fields) do
    declare(
      n,
      :negative,
      [
        boundary: "AshA2A.Semantic.PlanProjection.verify/2 (against the authoritative graph)",
        forbidden_outcome: "the edited projection verifies, or canonical O* changes",
        attempt_evidence: "plan_projection.verify mode=graph observed",
        survival_evidence: "plan_projection.verify outcome=verified",
        failure_class: :planning_failure,
        attempt_predicate: @verify_attempt,
        outcome_predicate: @verified
      ] ++ fields
    )
  end

  defp fid(n), do: "#{@court}-" <> String.pad_leading(Integer.to_string(n), 3, "0")

  defp declare(n, kind, fields) do
    Falsifier.new!([id: fid(n), court_id: @court, kind: kind, rfc_sections: ["§77"]] ++ fields)
  end

  # --- execution --------------------------------------------------------------

  @impl true
  def run(%Context{} = ctx) do
    fs = Map.new(falsifiers(), &{&1.id, &1})
    f = fn n -> Map.fetch!(fs, fid(n)) end

    {ir, ontology, _planning, projection} = F.admitted_chain()
    {:ok, o_star} = F.canonical_o_star(ontology)
    edited = %{projection | goals: ["a goal nobody admitted"]}

    projections(ctx, f, ir, ontology, o_star, projection, edited) ++
      packages(ctx, f, projection, edited) ++ manifests(ctx, f)
  end

  defp projections(ctx, f, ir, ontology, o_star, projection, edited) do
    cases = [
      {1, edited},
      {2, F.consistent_forgery(projection)},
      {3, %{projection | standing: :admitted, authority: :full}}
    ]

    negatives =
      Enum.map(cases, fn {n, candidate} ->
        reply = Context.stimulus(ctx, f.(n), fn -> PlanProjection.verify(candidate, ontology) end)
        {o_star_after, rederived} = canonical_state(ir, ontology)

        Result.negative(f.(n),
          attempt_observed?:
            F.observed?(ctx, f.(n), "plan_projection.verify", %{"mode" => "graph"}),
          forbidden_outcome_observed?:
            match?({:ok, _}, reply) or o_star_after != {:ok, o_star} or not rederived,
          evidence: %{
            "reply" => summarize(reply),
            "o_star_before" => o_star,
            "o_star_after" => inspect(o_star_after),
            "rederived_ontology_matches" => rederived
          }
        )
      end)

    reply = Context.stimulus(ctx, f.(4), fn -> PlanProjection.verify(projection, ontology) end)

    negatives ++
      [
        Result.positive(f.(4),
          attempt_observed?:
            F.observed?(ctx, f.(4), "plan_projection.verify", %{"mode" => "graph"}),
          expected_outcome_observed?: reply == {:ok, projection},
          evidence: %{"reply" => summarize(reply)}
        )
      ]
  end

  defp canonical_state(ir, ontology) do
    {:ok, rederived} = Ontology.from_ir(ir)
    {F.canonical_o_star(ontology), rederived.fingerprint == ontology.fingerprint}
  end

  defp packages(ctx, f, projection, edited) do
    r5 =
      Context.stimulus(ctx, f.(5), fn ->
        PlanPackage.from_projection(edited, "hddl_cli", F.package_opts())
      end)

    case PlanPackage.from_projection(projection, "hddl_cli", F.package_opts()) do
      {:ok, package} ->
        forged = F.forged_package(package)
        r6 = Context.stimulus(ctx, f.(6), fn -> PlanPackage.verify(forged) end)
        r7 = Context.stimulus(ctx, f.(7), fn -> PlanPackage.verify(package) end)

        [
          Result.negative(f.(5),
            attempt_observed?: F.observed?(ctx, f.(5), "plan_package.build"),
            forbidden_outcome_observed?: match?({:ok, _}, r5),
            evidence: %{"reply" => summarize(r5)}
          ),
          Result.negative(f.(6),
            attempt_observed?: F.observed?(ctx, f.(6), "plan_package.verify"),
            forbidden_outcome_observed?: match?({:ok, _}, r6),
            evidence: %{"reply" => summarize(r6)}
          ),
          Result.positive(f.(7),
            attempt_observed?: F.observed?(ctx, f.(7), "plan_package.verify"),
            expected_outcome_observed?:
              match?({:ok, %PlanPackage{standing: :candidate, authority: :none}}, r7),
            evidence: %{"reply" => summarize(r7)}
          )
        ]

      {:error, reason} ->
        [
          Result.negative(f.(5),
            attempt_observed?: F.observed?(ctx, f.(5), "plan_package.build"),
            forbidden_outcome_observed?: match?({:ok, _}, r5),
            evidence: %{"reply" => summarize(r5)}
          ),
          Result.blocked(f.(6), "untouched package not manufacturable: #{inspect(reason)}"),
          Result.blocked(f.(7), "untouched package not manufacturable: #{inspect(reason)}")
        ]
    end
  end

  defp manifests(ctx, f) do
    path = F.hand_edited_manifest(ctx.evidence_dir)
    r8 = Context.stimulus(ctx, f.(8), fn -> RootManifest.load(path, F.manifest_load_opts()) end)

    r9 =
      Context.stimulus(ctx, f.(9), fn ->
        RootManifest.load(F.committed_manifest_path(), F.manifest_load_opts())
      end)

    rebuilt = ConformanceCorpus.build()

    positive =
      case {r9, rebuilt} do
        {{:ok, loaded}, {:ok, manifest}} ->
          Result.positive(f.(9),
            attempt_observed?: F.observed?(ctx, f.(9), "root_manifest.load"),
            expected_outcome_observed?: loaded.digest == manifest.digest,
            evidence: %{"loaded" => loaded.digest, "rebuilt" => manifest.digest}
          )

        {_, {:error, reason}} ->
          Result.blocked(f.(9), "lawful manufacturer could not rebuild: #{inspect(reason)}")

        {refused, _} ->
          Result.positive(f.(9),
            attempt_observed?: F.observed?(ctx, f.(9), "root_manifest.load"),
            expected_outcome_observed?: false,
            evidence: %{"reply" => summarize(refused)}
          )
      end

    [
      Result.negative(f.(8),
        attempt_observed?: F.observed?(ctx, f.(8), "root_manifest.load"),
        forbidden_outcome_observed?: match?({:ok, _}, r8),
        evidence: %{"reply" => summarize(r8)}
      ),
      positive
    ]
  end

  defp summarize({:ok, %PlanProjection{} = p}),
    do: %{"verified" => p.projection_digest, "standing" => p.standing}

  defp summarize({:ok, %PlanPackage{} = p}),
    do: %{"accepted" => p.plan_digest, "standing" => p.standing, "authority" => p.authority}

  defp summarize({:ok, %RootManifest{digest: digest}}), do: %{"loaded" => digest}

  defp summarize({:error, %{code: code} = refusal}),
    do: %{"refused" => code, "detail" => inspect(Map.get(refusal, :detail), limit: 8)}

  defp summarize(other), do: %{"reply" => inspect(other, limit: 8)}
end
