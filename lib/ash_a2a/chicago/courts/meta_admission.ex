defmodule AshA2A.Chicago.Courts.MetaAdmission do
  @moduledoc """
  RFC-SA2A-002 §52 Meta-Admission Court (`SA2A-META`) with Court Versioning
  and Court Meta-Admission (§136, §137).

  §52: machinery MUST itself have standing before it can confer production
  standing. For every machinery kind the court substitutes an UNADMITTED
  artifact, lets that artifact's real machinery produce its apparent result,
  and requires that the apparent result cannot admit a production object:

    * pipeline law -- ShEx schema, SHACL shapes, N3 rules, OWL profile -- is
      substituted into a candidate judged by the real
      `AshA2A.Semantic.AdmissionPipeline` under the host's admitted world law
      (`AshA2A.Chicago.Fixtures.ShexShaclAdmission.law_manifest!/1`). Each
      substitute really makes the engine report `ADMITTED` for a graph the
      admitted law refuses; the stage that reads that verdict must refuse it
      (`:law_without_standing`) and the candidate must not reach `:admitted`.
    * Datalog program, SPARQL falsifier, planning domain, generator,
      authority policy, receipt schema and knowledge hook are run through
      their real machinery (`AshA2A.Chicago.Fixtures.RootManifestMeta.apparent/3`)
      and submitted to the production-standing gate
      `AshA2A.Semantic.MetaAdmission.confer/5` against a Root Manifest
      admitting the lawful artifact of each kind.
    * a semantic mapping is registered with a REAL receipt a real store holds
      -- for a different mapping (`AshA2A.Semantic.MappingRegistry`).

  §137: a nested `AshA2A.Chicago.Runner` run of three clean gate courts is
  CONFORMANT only under an admitted court manifest; a drifted falsifier
  declaration, a substituted OCEL validator, or a court the manifest never
  admitted must bar `CONFORMANT`.

  Every refusal family has a positive control (§100). Negative attempts are
  keyed on the deciding boundary having been reached (the pipeline stage
  event, the confer / register decision event, the nested run's court-manifest
  and stop events) -- never on the refusal itself -- so deleting a guard makes
  its falsifier survive (§11, §22).
  """

  use AshA2A.Chicago.Court

  alias AshA2A.Chicago.{Context, CourtManifest, Falsifier, Result}
  alias AshA2A.Chicago.Courts.ExecutableWorld
  alias AshA2A.Chicago.Fixtures.RootManifestMeta, as: F
  alias AshA2A.Chicago.Fixtures.ShexShaclAdmission, as: World
  alias AshA2A.Chicago.Fixtures.ShexShaclAdmission.Evidence
  alias AshA2A.Semantic.MappingRegistry
  alias AshA2A.Semantic.MetaAdmission, as: Meta

  @id "SA2A-META"
  @confer "semantic.meta_admission.confer"
  @standing "semantic.meta_admission.standing"
  @register "semantic.mapping.register"
  @run_stop "chicago.run.stop"
  @court_manifest "chicago.court_manifest.verified"

  # {n, kind, stage, stimulus description}
  @pipeline_cases [
    {"001", "shex_schema", :shex,
     "AdmissionPipeline.admit/2 of the world graph without its required rdfs:label, carrying a non-vacuous ShExJ schema that only requires sa:version in place of the admitted schema"},
    {"002", "shacl_shapes", :shacl,
     "AdmissionPipeline.admit/2 of the world graph whose consequence-bearing action lacks sa:requiresAuthority, judged by a non-vacuous shapes graph that only checks capability tiers"},
    {"003", "n3_rules", :rule_closure,
     "AdmissionPipeline.admit/2 of the world graph whose consequence-bearing action lacks sa:requiresAuthority, carrying the admitted falsifiers plus a rule `{ ?a sa:hasConsequence ?c } => { ?a sa:requiresAuthority sa:DerivedAuthority }`"},
    {"004", "semantic_profile", :profile_checks,
     "AdmissionPipeline.admit/2 of the lawful world graph carrying a non-vacuous OWL profile the world never admitted"}
  ]

  @gate_numbers %{
    "datalog_program" => "005",
    "sparql_falsifier" => "006",
    "planning_domain" => "007",
    "generator" => "008",
    "authority_policy" => "009",
    "receipt_schema" => "010",
    "hook" => "011"
  }

  @gate_stimulus %{
    "datalog_program" =>
      "LogicClosure.close/2 of a rule document deriving ex:administers from ex:requested, self-admitted by the caller's own :admitted_rules, then MetaAdmission.confer/5",
    "sparql_falsifier" =>
      "a SPARQL ASK falsifier that can never trip, executed by SPARQL.ex over a graph holding a Forbidden node (apparent: clear), then MetaAdmission.confer/5",
    "planning_domain" =>
      "the real hddl_cli solving a problem that grants no permission under a domain that dropped the has-permission precondition (apparent: solved), then MetaAdmission.confer/5",
    "generator" =>
      "a generator template rendering `standing: :production, authority: :root_custodian` via :io_lib.format/2, then MetaAdmission.confer/5",
    "authority_policy" =>
      "a policy document selecting :transport_verified_grants_capability, resolved by Authority.Grant.policy/1, then MetaAdmission.confer/5",
    "receipt_schema" =>
      "a receipt schema requiring only recorded_at, passing a real receipt stripped of idempotency key, actor and input digest, then MetaAdmission.confer/5",
    "hook" =>
      "a knowledge hook whose intent targets root_manifest:mutate, accepted by Hook.validate/1, then MetaAdmission.confer/5"
  }

  @impl true
  def id, do: @id
  @impl true
  def title, do: "Meta-admission: machinery standing and court meta-admission"
  @impl true
  def gate, do: 2
  @impl true
  def profile, do: :strict
  @impl true
  def rfc_sections, do: ["§52", "§100", "§136", "§137"]

  @impl true
  def ocel_mappings do
    F.mappings() ++
      Enum.filter(ExecutableWorld.ocel_mappings(), &(&1.activity == @register)) ++
      [AshA2A.Chicago.Runner.stop_mapping()]
  end

  # --- declarations ------------------------------------------------------------

  @impl true
  def falsifiers do
    {peer_a, _peer_b, _peer_c} = F.peers()

    pipeline =
      for {n, kind, stage, stimulus} <- @pipeline_cases do
        Falsifier.new!(
          id: "#{@id}-#{n}",
          court_id: @id,
          kind: :negative,
          invariant:
            "A #{kind} without standing cannot validate (RFC-SA2A-001 S20): its apparent ADMITTED verdict MUST NOT advance or confer standing",
          stimulus: stimulus,
          boundary: "AshA2A.Semantic.AdmissionPipeline :#{stage} stage (law standing)",
          forbidden_outcome:
            "the :#{stage} stage passes, or the candidate reaches :admitted, or canonical state changes",
          attempt_evidence: "admission.stage stage=#{stage} (any outcome) for this stimulus",
          survival_evidence:
            "admission.stage stage=#{stage} outcome=ok or admission.stop outcome=admitted in OCEL; {:ok, _} returned; independent canonical snapshot differs",
          guard:
            "AdmissionPipeline.with_law_standing/5 -> MetaAdmission.document_standing/4 (#{kind}) against the host Root Manifest",
          failure_class: :meta_admission_failure,
          rfc_sections: ["§52"],
          attempt_predicate: Evidence.stage(stage),
          outcome_predicate: {:any, [Evidence.stage(stage, :ok), Evidence.admitted()]}
        )
      end

    gate =
      for kind <- F.gate_kinds() do
        Falsifier.new!(
          id: "#{@id}-#{Map.fetch!(@gate_numbers, kind)}",
          court_id: @id,
          kind: :negative,
          invariant:
            "A #{kind} without standing cannot confer production standing (RFC-SA2A-001 S20/S58), whatever its machinery apparently produced",
          stimulus: Map.fetch!(@gate_stimulus, kind),
          boundary: "AshA2A.Semantic.MetaAdmission.confer/5",
          forbidden_outcome: "semantic.meta_admission.confer kind=#{kind} outcome=production",
          attempt_evidence: "semantic.meta_admission.confer kind=#{kind} (any outcome)",
          survival_evidence:
            "semantic.meta_admission.confer outcome=production in OCEL; {:ok, %{standing: :production}} returned",
          guard: "MetaAdmission.confer/5 -> document_standing/4 digest pin lookup (#{kind})",
          failure_class: :meta_admission_failure,
          rfc_sections: ["§52"],
          attempt_predicate: {:observed, @confer, %{"kind" => kind}},
          outcome_predicate: {:observed, @confer, %{"kind" => kind, "outcome" => "production"}}
        )
      end

    mapping = [
      Falsifier.new!(
        id: "#{@id}-012",
        court_id: @id,
        kind: :negative,
        invariant:
          "A semantic mapping without its own admission cannot reconcile identities: a real, store-held receipt for another mapping is not an admission of this one",
        stimulus:
          "MappingRegistry.register/2, on a registry bound to a real receipt store, of peerA exact_match peerB carrying the store-held executed receipt that admitted peerA exact_match peerC",
        boundary: "AshA2A.Semantic.MappingRegistry.register/2",
        forbidden_outcome: "the mapping registers and peerA/peerB reconcile as :admitted_mapping",
        attempt_evidence: "semantic.mapping.register for peerA (any outcome)",
        survival_evidence:
          "semantic.mapping.register outcome=admitted; MappingRegistry.reconcile/3 over the resulting registry",
        guard: "MappingRegistry.check_held/3 input_digest binding to admission_input/3",
        failure_class: :meta_admission_failure,
        rfc_sections: ["§52"],
        attempt_predicate: {:observed, @register, %{"source" => peer_a.iri}},
        outcome_predicate:
          {:observed, @register, %{"source" => peer_a.iri, "outcome" => "admitted"}}
      )
    ]

    court =
      for {n, stimulus, guard} <- [
            {"013",
             "nested Runner.run of three clean gate courts where gate court 1's falsifier declaration was revised after the court manifest admitting it was pinned",
             "CourtManifest.admission/3 per-court falsifier corpus / query digest comparison + StandingReceipt.recompute/1 drift bar"},
            {"014",
             "nested Runner.run of the three admitted gate courts with the OCEL validator substituted by a delegating module of another identity",
             "CourtManifest.admission/3 ocel_validator identity comparison + StandingReceipt.recompute/1 drift bar"},
            {"015",
             "nested Runner.run of the three gate courts under a court manifest that admits only gate courts 1 and 2",
             "CourtManifest.admission/3 unadmitted-court detection + StandingReceipt.recompute/1 drift bar"}
          ] do
        Falsifier.new!(
          id: "#{@id}-#{n}",
          court_id: @id,
          kind: :negative,
          invariant:
            "Court machinery that is not the admitted court manifest MUST NOT issue CONFORMANT standing (§136, §137)",
          stimulus: stimulus,
          boundary:
            "AshA2A.Chicago.Runner + AshA2A.Chicago.StandingReceipt (court meta-admission)",
          forbidden_outcome: "the nested run issues CONFORMANT",
          attempt_evidence:
            "chicago.court_manifest.verified and chicago.run.stop of the nested run",
          survival_evidence:
            "chicago.run.stop standing=CONFORMANT in OCEL; the nested standing_receipt.json standing",
          guard: guard,
          failure_class: :meta_admission_failure,
          rfc_sections: ["§136", "§137"],
          attempt_predicate: {:all, [{:observed, @court_manifest}, {:observed, @run_stop}]},
          outcome_predicate: {:observed, @run_stop, %{"standing" => "CONFORMANT"}}
        )
      end

    controls = [
      Falsifier.new!(
        id: "#{@id}-016",
        court_id: @id,
        kind: :positive_control,
        invariant:
          "Admitted pipeline law admits a lawful candidate, every law document with standing: the law-standing fence discriminates (§100)",
        stimulus:
          "AdmissionPipeline.admit/2 of the lawful world candidate under the world's admitted law",
        boundary: "AshA2A.Semantic.AdmissionPipeline law standing",
        attempt_evidence: "admission.start for this stimulus",
        survival_evidence:
          "admission.stage ok for :shex :shacl :rule_closure :profile_checks, meta_admission.standing admitted from the pipeline, admission.stop admitted",
        rfc_sections: ["§52", "§100"],
        attempt_predicate: {:observed, "admission.start"},
        outcome_predicate:
          {:all,
           Enum.map([:shex, :shacl, :rule_closure, :profile_checks], &Evidence.stage(&1, :ok)) ++
             [
               Evidence.admitted(),
               {:observed, @standing,
                %{"outcome" => "admitted", "consumer" => "AshA2A.Semantic.AdmissionPipeline"}}
             ]}
      ),
      Falsifier.new!(
        id: "#{@id}-017",
        court_id: @id,
        kind: :positive_control,
        invariant:
          "Admitted machinery of every gate kind confers production standing from its real apparent result: the confer gate discriminates (§100)",
        stimulus:
          "for each gate kind: the admitted artifact through its real machinery (lawful input), then MetaAdmission.confer/5",
        boundary: "AshA2A.Semantic.MetaAdmission.confer/5",
        attempt_evidence: "semantic.meta_admission.confer for every gate kind",
        survival_evidence:
          "semantic.meta_admission.confer outcome=production for every gate kind",
        rfc_sections: ["§52", "§100"],
        attempt_predicate:
          {:all, for(k <- F.gate_kinds(), do: {:observed, @confer, %{"kind" => k}})},
        outcome_predicate:
          {:all,
           for(
             k <- F.gate_kinds(),
             do: {:observed, @confer, %{"kind" => k, "outcome" => "production"}}
           )}
      ),
      Falsifier.new!(
        id: "#{@id}-018",
        court_id: @id,
        kind: :positive_control,
        invariant:
          "A mapping backed by the store-held receipt of exactly its own admission registers and reconciles: the binding fence discriminates (§100)",
        stimulus:
          "MappingRegistry.register/2, on a registry bound to a real receipt store, of peerA exact_match peerB with the held receipt admitting exactly that mapping",
        boundary: "AshA2A.Semantic.MappingRegistry.register/2",
        attempt_evidence: "semantic.mapping.register for peerA",
        survival_evidence:
          "semantic.mapping.register outcome=admitted; reconcile :admitted_mapping",
        rfc_sections: ["§52", "§100"],
        attempt_predicate: {:observed, @register, %{"source" => peer_a.iri}},
        outcome_predicate:
          {:observed, @register, %{"source" => peer_a.iri, "outcome" => "admitted"}}
      ),
      Falsifier.new!(
        id: "#{@id}-019",
        court_id: @id,
        kind: :positive_control,
        invariant:
          "Admitted court machinery issues CONFORMANT for a clean run: the court-manifest bar discriminates (§100, §137)",
        stimulus:
          "nested Runner.run of the three gate courts under a court manifest admitting exactly them and the admitted OCEL validator",
        boundary: "AshA2A.Chicago.Runner + AshA2A.Chicago.StandingReceipt (court meta-admission)",
        attempt_evidence:
          "chicago.court_manifest.verified and chicago.run.stop of the nested run",
        survival_evidence: "chicago.run.stop standing=CONFORMANT court_admission=admitted",
        rfc_sections: ["§137", "§100"],
        attempt_predicate: {:all, [{:observed, @court_manifest}, {:observed, @run_stop}]},
        outcome_predicate:
          {:all,
           [
             {:observed, @court_manifest, %{"outcome" => "admitted"}},
             {:observed, @run_stop,
              %{"standing" => "CONFORMANT", "court_admission" => "admitted"}}
           ]}
      )
    ]

    pipeline ++ gate ++ mapping ++ court ++ controls
  end

  # --- execution ---------------------------------------------------------------

  @impl true
  def run(%Context{} = ctx) do
    fs = Map.new(falsifiers(), &{&1.id, &1})
    f = fn n -> Map.fetch!(fs, "#{@id}-#{n}") end

    pipeline_results =
      case Evidence.engine() do
        {:blocked, reason} ->
          Evidence.blocked(Enum.map(~w(001 002 003 004 016), f), reason)

        :ok ->
          scratch = Evidence.scratch_dir(ctx, @id)

          [
            Evidence.stage_negative(
              ctx,
              f.("001"),
              World.candidate(
                graph_ttl: World.shex_missing_required_predicate(),
                shex_schema: F.self_serving_shex_schema()
              ),
              scratch,
              :shex
            ),
            Evidence.stage_negative(
              ctx,
              f.("002"),
              World.candidate(
                graph_ttl: World.shacl_consequence_without_authority(),
                shacl_shapes: F.self_serving_shacl_shapes()
              ),
              scratch,
              :shacl
            ),
            Evidence.stage_negative(
              ctx,
              f.("003"),
              World.candidate(
                graph_ttl: World.shacl_consequence_without_authority(),
                falsifiers: F.laundering_rules()
              ),
              scratch,
              :rule_closure
            ),
            Evidence.stage_negative(
              ctx,
              f.("004"),
              World.candidate(profile_ttl: F.unadmitted_profile()),
              scratch,
              :profile_checks
            ),
            lawful_pipeline(ctx, f.("016"), scratch)
          ]
      end

    gate_falsifiers = Enum.map(F.gate_kinds(), &f.(Map.fetch!(@gate_numbers, &1))) ++ [f.("017")]

    gate_results =
      case F.gate_manifest(Path.join(ctx.evidence_dir, "sa2a-meta")) do
        {:ok, manifest} ->
          Enum.map(
            F.gate_kinds(),
            &gate_negative(ctx, f.(Map.fetch!(@gate_numbers, &1)), manifest, &1)
          ) ++ [gate_positive(ctx, f.("017"), manifest)]

        {:error, refusal} ->
          Evidence.blocked(
            gate_falsifiers,
            "gate Root Manifest cannot be built here: #{inspect(refusal, limit: 6)}"
          )
      end

    mapping_results = [
      mapping_case(ctx, f.("012"), :unbound),
      mapping_case(ctx, f.("018"), :bound)
    ]

    court_results =
      case AshA2A.Semantic.RootManifest.current_engine_digest() do
        {:ok, _} ->
          [
            court_case(ctx, f.("013"), :drifted_declaration),
            court_case(ctx, f.("014"), :substituted_validator),
            court_case(ctx, f.("015"), :unadmitted_court),
            court_case(ctx, f.("019"), :admitted)
          ]

        {:error, refusal} ->
          # The gate fixture courts' own control needs the pinned engine
          # artifact; without it no nested run can be clean, so nothing is
          # decided here.
          Evidence.blocked(
            Enum.map(~w(013 014 015 019), f),
            "engine artifact not resolvable for the nested gate courts: #{inspect(refusal, limit: 6)}"
          )
      end

    pipeline_results ++ gate_results ++ mapping_results ++ court_results
  end

  # --- pipeline -------------------------------------------------------------------

  defp lawful_pipeline(ctx, f, scratch) do
    {result, before, after_snapshot} = Evidence.admit(ctx, f, World.candidate(), scratch)

    standing_from_pipeline? =
      Evidence.seen?(ctx, f, @standing, %{
        "outcome" => "admitted",
        "consumer" => "AshA2A.Semantic.AdmissionPipeline"
      })

    Result.positive(f,
      attempt_observed?: Evidence.seen?(ctx, f, "admission.start"),
      expected_outcome_observed?:
        Enum.all?(
          [:shex, :shacl, :rule_closure, :profile_checks],
          &Evidence.stage_seen?(ctx, f, &1, :ok)
        ) and
          Evidence.admitted_seen?(ctx, f) and standing_from_pipeline? and
          match?(
            {:ok, %{standing: :admitted, authority: :none, root_manifest_digest: "sha256:" <> _}},
            result
          ) and
          Evidence.canonical_unchanged?(before, after_snapshot),
      evidence: Evidence.admission_evidence(result, before, after_snapshot)
    )
  end

  # --- production-standing gate ---------------------------------------------------------

  defp gate_negative(ctx, f, manifest, kind) do
    bytes = F.artifact(kind, :rogue)

    case F.apparent(kind, bytes, :attack) do
      {:blocked, reason} ->
        Result.blocked(f, reason)

      apparent ->
        reply =
          Context.stimulus(ctx, f, fn ->
            Meta.confer(manifest, kind, bytes, apparent, consumer: @id)
          end)

        Result.negative(f,
          attempt_observed?: Context.observed?(ctx, f, @confer),
          forbidden_outcome_observed?:
            confer_seen?(ctx, f, kind, "production") or match?({:ok, _}, reply),
          evidence: %{
            "kind" => kind,
            "apparent_positive" => match?({:ok, _}, apparent),
            "apparent" => inspect(apparent, limit: 6, printable_limit: 256),
            "artifact_pinned" => pinned?(manifest, bytes, kind),
            "reply" => inspect(reply, limit: 8, printable_limit: 512)
          }
        )
    end
  end

  defp gate_positive(ctx, f, manifest) do
    apparent = Map.new(F.gate_kinds(), &{&1, F.apparent(&1, F.artifact(&1, :admitted), :lawful)})

    case Enum.find(apparent, &match?({_, {:blocked, _}}, &1)) do
      {kind, {:blocked, reason}} ->
        Result.blocked(f, "#{kind}: #{reason}")

      nil ->
        replies =
          Context.stimulus(ctx, f, fn ->
            Map.new(F.gate_kinds(), fn kind ->
              {kind,
               Meta.confer(manifest, kind, F.artifact(kind, :admitted), apparent[kind],
                 consumer: @id
               )}
            end)
          end)

        Result.positive(f,
          attempt_observed?: Enum.all?(F.gate_kinds(), &confer_seen?(ctx, f, &1, nil)),
          expected_outcome_observed?:
            Enum.all?(F.gate_kinds(), &confer_seen?(ctx, f, &1, "production")) and
              Enum.all?(replies, &match?({_, {:ok, %{standing: :production}}}, &1)),
          evidence:
            Map.new(replies, fn {kind, reply} ->
              {kind, inspect(reply, limit: 6, printable_limit: 256)}
            end)
        )
    end
  end

  defp confer_seen?(ctx, f, kind, outcome) do
    attrs = if outcome, do: %{"kind" => kind, "outcome" => outcome}, else: %{"kind" => kind}
    Evidence.seen?(ctx, f, @confer, attrs)
  end

  # Independent reader: the manifest's pinned file bytes, re-digested here.
  defp pinned?(manifest, bytes, kind) do
    digest = "sha256:" <> Base.encode16(:crypto.hash(:sha256, bytes), case: :lower)

    Enum.any?(AshA2A.Semantic.RootManifest.all_pins(manifest), fn pin ->
      pin["kind"] == kind and
        F.file_sha256(Path.join(manifest.root, pin["path"])) ==
          String.replace_prefix(digest, "sha256:", "")
    end)
  end

  # --- semantic mapping ---------------------------------------------------------------------

  defp mapping_case(ctx, f, variant) do
    {peer_a, peer_b, peer_c} = F.peers()

    F.with_store(fn store ->
      receipt =
        case variant do
          :unbound -> F.admission_receipt(store, peer_a.iri, peer_c.iri)
          :bound -> F.admission_receipt(store, peer_a.iri, peer_b.iri)
        end

      registry = MappingRegistry.new(receipt_store: {AshA2A.ReceiptStore.Memory, name: store})

      mapping = %{
        source: peer_a.iri,
        target: peer_b.iri,
        kind: :exact_match,
        admission_receipt: receipt
      }

      reply = Context.stimulus(ctx, f, fn -> MappingRegistry.register(registry, mapping) end)

      world = with({:ok, r} <- reply, do: r, else: (_ -> registry))
      reconciled = MappingRegistry.reconcile(world, peer_a, peer_b)
      # Independent reader: the store itself still holds the receipt it issued.
      held = AshA2A.ReceiptStore.Memory.fetch(receipt.command_id, name: store)

      attempt? = Evidence.seen?(ctx, f, @register, %{"source" => peer_a.iri})

      admitted? =
        Evidence.seen?(ctx, f, @register, %{"source" => peer_a.iri, "outcome" => "admitted"})

      evidence = %{
        "reply" => inspect(reply, limit: 6, printable_limit: 512),
        "reconcile_after" => inspect(reconciled, limit: 6, printable_limit: 256),
        "receipt_held_by_store" => match?({:ok, _}, held)
      }

      case variant do
        :unbound ->
          Result.negative(f,
            attempt_observed?: attempt?,
            forbidden_outcome_observed?:
              admitted? or match?({:ok, %{outcome: :admitted_mapping}}, reconciled),
            evidence: evidence
          )

        :bound ->
          Result.positive(f,
            attempt_observed?: attempt?,
            expected_outcome_observed?:
              admitted? and match?({:ok, %{outcome: :admitted_mapping}}, reconciled),
            evidence: evidence
          )
      end
    end)
  end

  # --- court meta-admission -------------------------------------------------------------------

  defp court_case(ctx, f, variant) do
    [g1, g2, g3] = F.gate_courts()
    dir = Path.join([ctx.evidence_dir, "sa2a-meta-court", Atom.to_string(variant)])

    {courts, admitted, opts} =
      case variant do
        :drifted_declaration ->
          {[F.GateCourt1Drifted, g2, g3], CourtManifest.build([g1, g2, g3]), []}

        :substituted_validator ->
          {[g1, g2, g3], CourtManifest.build([g1, g2, g3]),
           [ocel_validator: F.SubstituteOcelValidator]}

        :unadmitted_court ->
          {[g1, g2, g3], CourtManifest.build([g1, g2]), []}

        :admitted ->
          {[g1, g2, g3], CourtManifest.build([g1, g2, g3]), []}
      end

    reply = Context.stimulus(ctx, f, fn -> F.nested_run(dir, courts, admitted, opts) end)

    # Independent reader: the nested run's durable standing receipt.
    receipt =
      case File.read(Path.join([dir, "package", "standing_receipt.json"])) do
        {:ok, raw} -> JSON.decode!(raw)
        _ -> %{}
      end

    standing = receipt["standing"]
    manifest_section = get_in(receipt, ["court", "manifest"]) || %{}
    attempt? = Context.observed?(ctx, f, @court_manifest) and Context.observed?(ctx, f, @run_stop)

    evidence = %{
      "nested_standing" => standing,
      "court_manifest" => manifest_section,
      "nested_results" => get_in(receipt, ["results", "falsifiers_total"]),
      "reply" => if(match?({:ok, _}, reply), do: "ok", else: inspect(reply, limit: 5))
    }

    case variant do
      :admitted ->
        Result.positive(f,
          attempt_observed?: attempt?,
          expected_outcome_observed?:
            standing == "CONFORMANT" and manifest_section["verification"] == "admitted" and
              Evidence.seen?(ctx, f, @run_stop, %{"standing" => "CONFORMANT"}),
          evidence: evidence
        )

      _ ->
        Result.negative(f,
          attempt_observed?: attempt?,
          # Undetected drift is forbidden too: a nested run that happens not to
          # be CONFORMANT for another reason must not kill this falsifier.
          forbidden_outcome_observed?:
            standing == "CONFORMANT" or manifest_section["verification"] != "drift" or
              Evidence.seen?(ctx, f, @run_stop, %{"standing" => "CONFORMANT"}),
          evidence: evidence
        )
    end
  end
end
