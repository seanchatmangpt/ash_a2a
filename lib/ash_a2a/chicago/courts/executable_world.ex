defmodule AshA2A.Chicago.Courts.ExecutableWorld do
  @moduledoc """
  RFC-SA2A-002 Gate 2 -- Executable World Admitted (`CHI-ADM`, §33) and the
  Admission Pipeline Court (§44).

  The court attempts to introduce unadmitted semantic state into the
  executable world at the real boundary that decides each kind of state:

    * terms -- `AshA2A.Semantic.TermRegistry.admit_operational_use/3` over the
      real index built from the pinned ontology cache (RFC-SA2A-001 S7.3);
    * graphs, rules, validators, canonical claims -- the real
      `AshA2A.Semantic.AdmissionPipeline` over the real `praxis-graphlaw` wasm,
      judged under the Gate 2 world law
      (`AshA2A.Chicago.Fixtures.ShexShaclAdmission`);
    * semantic mappings -- `AshA2A.Semantic.MappingRegistry.register/2`
      (RFC-SA2A-001 S47).

  A negative passes only as `AttemptObserved ∧ ¬Standing(candidate)` with
  canonical state unchanged. Canonical state is read through
  `AshA2A.Chicago.Fixtures.ShexShaclAdmission.Evidence.canonical_snapshot/1`
  (file digests of the admitted ontology cache and law corpus, plus engine
  scratch residue) -- never through the boundary under attack. The term and
  mapping boundaries emit `[:ash_a2a, :semantic, :term, :operational_use]` and
  `[:ash_a2a, :semantic, :mapping, :register]`, mapped by `ocel_mappings/0`.

  ## Defects this court found, and the SUT repairs that killed them

    * `CHI-ADM-005` unadmitted rule, `CHI-ADM-006` unadmitted validator
      (survived at 46e522f): the pipeline judged a candidate under whatever law
      documents the candidate carried, so an unadmitted N3 rule deriving the
      missing `sa:preparedReceipt`, or an unadmitted self-serving shapes graph,
      laundered a SHACL-invalid DO step into `:admitted`. Repair: every
      law-bearing stage requires standing of its documents through
      `AshA2A.Semantic.MetaAdmission.document_standing/4` against the host's
      verified Root Manifest (the world's admitted law,
      `AshA2A.Chicago.Fixtures.ShexShaclAdmission.law_manifest!/1`); the rule
      is refused at `:rule_closure`, the shapes at `:shacl`, both
      `:law_without_standing`.
    * `CHI-ADM-008` named receipt (survived at 46e522f):
      `MappingRegistry.register/2` accepted any map carrying non-empty
      `:receipt_id`/`:fingerprint`. Repair: the receipt must be an
      `%AshA2A.Receipt{}` the registry's receipt store really holds, executed,
      and bound to this mapping's admission input
      (`:semantic_mapping_receipt_not_held` / `:semantic_mapping_receipt_unbound`).

  When the real engine is unavailable the pipeline falsifiers are `:blocked`
  with the measured reason -- never killed.
  """

  use AshA2A.Chicago.Court

  alias AshA2A.{Command, Identity, Receipt}
  alias AshA2A.Chicago.{Context, Falsifier, Result}
  alias AshA2A.Chicago.Fixtures.ShexShaclAdmission, as: World
  alias AshA2A.Chicago.Fixtures.ShexShaclAdmission.Evidence
  alias AshA2A.Chicago.Ocel.Mapping
  alias AshA2A.Semantic.{AdmissionPipeline, MappingRegistry, TermRegistry}

  @id "CHI-ADM"
  @op_use "semantic.term.operational_use"
  @register "semantic.mapping.register"

  @required_failures [
    :parse,
    :identity,
    :shex,
    :shacl,
    :sparql_falsifiers,
    :provenance,
    :profile_checks
  ]

  @impl true
  def id, do: @id
  @impl true
  def title, do: "Gate 2 -- executable world admitted / admission pipeline"
  @impl true
  def gate, do: 2
  @impl true
  def profile, do: :core
  @impl true
  def rfc_sections, do: ["§33", "§44", "§100"]

  @impl true
  def ocel_mappings do
    [
      Mapping.new!(
        event: [:ash_a2a, :semantic, :term, :operational_use],
        activity: @op_use,
        source: __MODULE__,
        objects: fn _m, meta -> [{"semantic_term", meta[:iri], "term"}] end,
        attributes: fn _m, meta ->
          Map.take(meta, [:iri, :outcome, :code, :profile, :consequential])
        end
      ),
      Mapping.new!(
        event: [:ash_a2a, :semantic, :mapping, :register],
        activity: @register,
        source: __MODULE__,
        objects: fn _m, meta ->
          [{"semantic_term", meta[:source], "source"}, {"semantic_term", meta[:target], "target"}]
        end,
        attributes: fn _m, meta -> Map.take(meta, [:source, :target, :kind, :outcome, :code]) end
      )
    ]
  end

  # --- declarations -------------------------------------------------------------

  @impl true
  def falsifiers do
    {peer_a, _peer_b} = World.colliding_peers()
    term = World.unadmitted_term()

    [
      Falsifier.new!(
        id: "#{@id}-001",
        court_id: @id,
        kind: :negative,
        invariant:
          "An unadmitted ontology term MUST NOT become operational semantics in a consequential Strict operation (RFC-SA2A-001 S7.3)",
        stimulus:
          "TermRegistry.admit_operational_use/3 of #{term} (inside the admitted SKOS namespace, declared by no admitted document), Strict, consequential",
        boundary: "AshA2A.Semantic.TermRegistry.admit_operational_use/3",
        forbidden_outcome:
          "outcome admitted or candidate (usable) for a consequential Strict use; the term appears in the index rebuilt from the pinned cache; cache bytes change",
        attempt_evidence: "semantic.term.operational_use event for the term",
        survival_evidence:
          "semantic.term.operational_use outcome=admitted|candidate; fresh TermRegistry.from_cache/1 membership; ontology cache tree digest",
        guard: "TermRegistry.decide_operational_use/4 strict+consequential refusal",
        failure_class: :admission_failure,
        rfc_sections: ["§33"],
        attempt_predicate:
          {:observed, @op_use, %{"iri" => term, "profile" => "strict", "consequential" => "true"}},
        outcome_predicate:
          {:any,
           [
             {:observed, @op_use, %{"iri" => term, "outcome" => "admitted"}},
             {:observed, @op_use, %{"iri" => term, "outcome" => "candidate"}}
           ]}
      ),
      stage_falsifier("002", :parse,
        invariant: "A structurally invalid RDF object MUST NOT enter the executable world",
        stimulus: "AdmissionPipeline.admit/2 of a candidate whose graph is not RDF at all",
        guard: "AdmissionPipeline.run_stage(:parse, ...) universal-denial triple witness",
        class: :admission_failure
      ),
      stage_falsifier("003", :shacl,
        invariant: "A SHACL-invalid object MUST NOT acquire standing in the executable world",
        stimulus:
          "AdmissionPipeline.admit/2 of the world graph whose consequence-bearing action lacks sa:requiresAuthority",
        guard: "AdmissionPipeline.run_stage(:shacl, ...) SHACL REFUSED -> :shacl_nonconformant",
        class: :validator_failure
      ),
      stage_falsifier("004", :identity,
        invariant:
          "An unadmitted rule smuggled into candidate data MUST NOT derive state in the executable world",
        stimulus:
          "AdmissionPipeline.admit/2 of the lawful world graph with an N3 rule `{ ?w a sa:World } => { ?w sa:standing sa:Canonical }` appended to the candidate data",
        guard:
          "AdmissionPipeline.run_stage(:identity, ...) RDFC-1.0 canonical identity (fail-closed RDF.ex Turtle reader)",
        class: :admission_failure
      ),
      standing_falsifier("005", :shacl,
        invariant:
          "A rule without standing cannot derive canonical facts (RFC-SA2A-001 S20): an unadmitted rule MUST NOT take part in admission",
        stimulus:
          "AdmissionPipeline.admit/2 of the world graph whose sa:DoStep lacks sa:preparedReceipt, carrying as law the admitted falsifiers plus an unadmitted rule `{ ?d a sa:DoStep } => { ?d sa:preparedReceipt sa:Derived }`",
        boundary: "AshA2A.Semantic.AdmissionPipeline (law standing / meta-admission)",
        guard:
          "AdmissionPipeline :rule_closure law standing: MetaAdmission.document_standing/4 (n3_rules) against the host Root Manifest",
        class: :meta_admission_failure
      ),
      standing_falsifier("006", :shacl,
        invariant:
          "A validator without standing cannot validate (RFC-SA2A-001 S20): an unadmitted validator MUST NOT admit a candidate",
        stimulus:
          "AdmissionPipeline.admit/2 of the world graph whose sa:DoStep lacks sa:preparedReceipt, judged by a non-vacuous self-serving shapes graph in place of the admitted SHACL law",
        boundary: "AshA2A.Semantic.AdmissionPipeline (law standing / meta-admission)",
        guard:
          "AdmissionPipeline :shacl law standing: MetaAdmission.document_standing/4 (shacl_shapes) against the host Root Manifest",
        class: :meta_admission_failure
      ),
      mapping_falsifier("007",
        invariant: "An unadmitted semantic mapping MUST NOT reconcile two peer identities",
        stimulus:
          "MappingRegistry.register/2 of an exact_match between two colliding peer identities with no admission receipt",
        guard: "MappingRegistry.check_receipt/1 missing-receipt refusal",
        peer: peer_a
      ),
      mapping_falsifier("008",
        invariant:
          "A named receipt is not a receipt (RFC-SA2A-001 S6): a mapping backed by a receipt no admission issued MUST NOT reconcile two peer identities",
        stimulus:
          "MappingRegistry.register/2 of the same mapping carrying %{receipt_id, fingerprint} that no admission issued and no receipt store holds",
        guard:
          "MappingRegistry.check_held/3: receipt fetched back from the registry's receipt store, identity + executed + admission-input binding",
        peer: peer_a
      ),
      stage_falsifier("009", :provenance,
        invariant:
          "A candidate marked directly as canonical MUST NOT acquire standing: standing is earned, never asserted (RFC-SA2A-001 S6)",
        stimulus:
          "AdmissionPipeline.admit/2 of the lawful world whose provenance IR arrives already marked standing: :admitted",
        guard:
          "AdmissionPipeline :provenance stage -> AshA2A.Semantic.Admission.fence/1 (standing: :candidate, authority: :none)",
        class: :admission_failure
      ),
      Falsifier.new!(
        id: "#{@id}-010",
        court_id: @id,
        kind: :negative,
        invariant:
          "Failure at every REQUIRED stage prevents standing and leaves canonical state unchanged (§44, RFC-SA2A-001 S13)",
        stimulus:
          "seven AdmissionPipeline.admit/2 calls, each failing one required stage: parse, identity, shex, shacl, sparql_falsifiers, provenance, profile_checks",
        boundary: "AshA2A.Semantic.AdmissionPipeline required stage set",
        forbidden_outcome:
          "any of the seven candidates reaches :admitted, or canonical state changes across them",
        attempt_evidence:
          "admission.stage outcome=refused for each of the seven targeted stages attributed to this stimulus",
        survival_evidence:
          "admission.stop outcome=admitted in OCEL; {:ok, _} returned; independent canonical snapshot differs",
        guard: "AdmissionPipeline.run_stages/3 reduce_while halt + finalize/5 intersection",
        failure_class: :admission_failure,
        rfc_sections: ["§44"],
        attempt_predicate: {:all, Enum.map(@required_failures, &Evidence.stage(&1, :refused))},
        outcome_predicate: Evidence.admitted()
      ),
      Falsifier.new!(
        id: "#{@id}-011",
        court_id: @id,
        kind: :positive_control,
        invariant:
          "A lawful candidate traverses every required stage and is admitted with authority :none (§44, §100)",
        stimulus: "AdmissionPipeline.admit/2 of the lawful Gate 2 world under its admitted law",
        boundary: "AshA2A.Semantic.AdmissionPipeline full required stage set",
        attempt_evidence: "admission.start attributed to this stimulus",
        survival_evidence:
          "admission.stage outcome=ok for all eight required stages and admission.stop outcome=admitted",
        rfc_sections: ["§44", "§100"],
        attempt_predicate: {:observed, "admission.start"},
        outcome_predicate:
          {:all,
           Enum.map(AdmissionPipeline.required_stages(), &Evidence.stage(&1, :ok)) ++
             [Evidence.admitted()]}
      ),
      Falsifier.new!(
        id: "#{@id}-012",
        court_id: @id,
        kind: :positive_control,
        invariant:
          "An admitted vocabulary term is usable as operational semantics: the term fence discriminates",
        stimulus:
          "TermRegistry.admit_operational_use/3 of #{World.admitted_term()}, Strict, consequential",
        boundary: "AshA2A.Semantic.TermRegistry.admit_operational_use/3",
        attempt_evidence: "semantic.term.operational_use event for the term",
        survival_evidence: "semantic.term.operational_use outcome=admitted",
        rfc_sections: ["§33", "§100"],
        attempt_predicate: {:observed, @op_use, %{"iri" => World.admitted_term()}},
        outcome_predicate:
          {:observed, @op_use, %{"iri" => World.admitted_term(), "outcome" => "admitted"}}
      ),
      Falsifier.new!(
        id: "#{@id}-013",
        court_id: @id,
        kind: :positive_control,
        invariant:
          "A mapping backed by a receipt really committed to a receipt store is admitted and reconciles: the mapping fence discriminates",
        stimulus:
          "MappingRegistry.register/2, on a registry bound to a real AshA2A.ReceiptStore.Memory, of the colliding-peer exact_match with a receipt for exactly its admission input, claimed, committed and fetched back from that store",
        boundary: "AshA2A.Semantic.MappingRegistry.register/2",
        attempt_evidence: "semantic.mapping.register event for the source identity",
        survival_evidence:
          "semantic.mapping.register outcome=admitted; MappingRegistry.reconcile/3 returns :admitted_mapping",
        rfc_sections: ["§33", "§100"],
        attempt_predicate: {:observed, @register, %{"source" => peer_a.iri}},
        outcome_predicate:
          {:observed, @register, %{"source" => peer_a.iri, "outcome" => "admitted"}}
      )
    ]
  end

  defp stage_falsifier(n, stage, opts) do
    Falsifier.new!(
      id: "#{@id}-#{n}",
      court_id: @id,
      kind: :negative,
      invariant: Keyword.fetch!(opts, :invariant),
      stimulus: Keyword.fetch!(opts, :stimulus),
      boundary: "AshA2A.Semantic.AdmissionPipeline :#{stage} stage",
      forbidden_outcome:
        "the :#{stage} stage passes, or the candidate reaches :admitted, or canonical state changes",
      attempt_evidence: "admission.stage event for stage=#{stage} attributed to this stimulus",
      survival_evidence:
        "admission.stage stage=#{stage} outcome=ok or admission.stop outcome=admitted in OCEL; " <>
          "{:ok, _} returned; independent canonical snapshot differs",
      guard: Keyword.fetch!(opts, :guard),
      failure_class: Keyword.fetch!(opts, :class),
      rfc_sections: ["§33", "§44"],
      attempt_predicate: Evidence.stage(stage),
      outcome_predicate: {:any, [Evidence.stage(stage, :ok), Evidence.admitted()]}
    )
  end

  defp standing_falsifier(n, stage, opts) do
    Falsifier.new!(
      id: "#{@id}-#{n}",
      court_id: @id,
      kind: :negative,
      invariant: Keyword.fetch!(opts, :invariant),
      stimulus: Keyword.fetch!(opts, :stimulus),
      boundary: Keyword.fetch!(opts, :boundary),
      forbidden_outcome: "the candidate reaches :admitted, or canonical state changes",
      attempt_evidence:
        "admission.start and an admission.stage event for stage=#{stage} attributed to this stimulus",
      survival_evidence:
        "admission.stop outcome=admitted in OCEL; {:ok, _} returned; independent canonical snapshot differs",
      guard: Keyword.fetch!(opts, :guard),
      failure_class: Keyword.fetch!(opts, :class),
      rfc_sections: ["§33"],
      attempt_predicate: {:all, [{:observed, "admission.start"}, Evidence.stage(stage)]},
      outcome_predicate: Evidence.admitted()
    )
  end

  defp mapping_falsifier(n, opts) do
    peer = Keyword.fetch!(opts, :peer)

    Falsifier.new!(
      id: "#{@id}-#{n}",
      court_id: @id,
      kind: :negative,
      invariant: Keyword.fetch!(opts, :invariant),
      stimulus: Keyword.fetch!(opts, :stimulus),
      boundary: "AshA2A.Semantic.MappingRegistry.register/2",
      forbidden_outcome:
        "the mapping is registered, and the colliding peers reconcile as :admitted_mapping",
      attempt_evidence: "semantic.mapping.register event for the source identity",
      survival_evidence:
        "semantic.mapping.register outcome=admitted; MappingRegistry.reconcile/3 over the resulting registry",
      guard: Keyword.fetch!(opts, :guard),
      failure_class: :admission_failure,
      rfc_sections: ["§33"],
      attempt_predicate: {:observed, @register, %{"source" => peer.iri}},
      outcome_predicate: {:observed, @register, %{"source" => peer.iri, "outcome" => "admitted"}}
    )
  end

  # --- execution ------------------------------------------------------------------

  @impl true
  def run(%Context{} = ctx) do
    fs = Map.new(falsifiers(), &{&1.id, &1})
    f = fn n -> Map.fetch!(fs, "#{@id}-#{n}") end
    registry = TermRegistry.from_cache(profile: :strict)

    term_results = [
      term_negative(ctx, f.("001"), registry),
      term_positive(ctx, f.("012"), registry)
    ]

    mapping_results = [
      mapping_negative(ctx, f.("007"), nil),
      mapping_negative(ctx, f.("008"), %{
        receipt_id: "urn:chicago:named-only:#{System.unique_integer([:positive])}",
        fingerprint: "named-not-present"
      }),
      mapping_positive(ctx, f.("013"))
    ]

    pipeline_results =
      case Evidence.engine() do
        {:blocked, reason} ->
          Evidence.blocked(Enum.map(~w(002 003 004 005 006 009 010 011), f), reason)

        :ok ->
          pipeline(ctx, f, Evidence.scratch_dir(ctx, @id))
      end

    term_results ++ mapping_results ++ pipeline_results
  end

  defp pipeline(ctx, f, scratch) do
    [
      Evidence.stage_negative(
        ctx,
        f.("002"),
        World.candidate(graph_ttl: World.malformed_rdf()),
        scratch,
        :parse
      ),
      Evidence.stage_negative(
        ctx,
        f.("003"),
        World.candidate(graph_ttl: World.shacl_consequence_without_authority()),
        scratch,
        :shacl
      ),
      Evidence.stage_negative(
        ctx,
        f.("004"),
        World.candidate(graph_ttl: World.graph_with_smuggled_rule()),
        scratch,
        :identity
      ),
      Evidence.standing_negative(
        ctx,
        f.("005"),
        World.candidate(
          graph_ttl: World.shacl_do_without_receipt(),
          falsifiers:
            World.falsifiers() <>
              "\n@prefix sa: <http://seanchatmangpt.github.io/sa2a#> .\n" <>
              "{ ?d a sa:DoStep } => { ?d sa:preparedReceipt sa:Derived } .\n"
        ),
        scratch,
        :shacl
      ),
      Evidence.standing_negative(
        ctx,
        f.("006"),
        World.candidate(
          graph_ttl: World.shacl_do_without_receipt(),
          shacl_shapes: World.unadmitted_validator_shapes()
        ),
        scratch,
        :shacl
      ),
      Evidence.stage_negative(
        ctx,
        f.("009"),
        World.candidate(provenance: World.premarked_canonical_provenance()),
        scratch,
        :provenance
      ),
      every_required_stage(ctx, f.("010"), scratch),
      lawful_admitted(ctx, f.("011"), scratch)
    ]
  end

  # --- terms -----------------------------------------------------------------------

  defp term_negative(ctx, f, {:ok, registry}) do
    term = World.unadmitted_term()
    before = cache_digest()

    reply =
      Context.stimulus(ctx, f, fn ->
        TermRegistry.admit_operational_use(registry, term, profile: :strict, consequential?: true)
      end)

    # Independent post-state: the index rebuilt from the pinned bytes on disk.
    {:ok, rebuilt} = TermRegistry.from_cache(profile: :strict)
    after_digest = cache_digest()

    Result.negative(f,
      attempt_observed?: Evidence.seen?(ctx, f, @op_use, %{"iri" => term}),
      forbidden_outcome_observed?:
        Evidence.seen?(ctx, f, @op_use, %{"iri" => term, "outcome" => "admitted"}) or
          Evidence.seen?(ctx, f, @op_use, %{"iri" => term, "outcome" => "candidate"}) or
          TermRegistry.member?(rebuilt, term) or before != after_digest,
      evidence: %{
        "reply" => inspect(reply, limit: 10, printable_limit: 512),
        "rebuilt_index_size" => TermRegistry.size(rebuilt),
        "term_in_rebuilt_index" => TermRegistry.member?(rebuilt, term),
        "ontology_cache_before" => before,
        "ontology_cache_after" => after_digest
      }
    )
  end

  defp term_negative(_ctx, f, {:error, reason}),
    do: Result.blocked(f, "admitted term index unavailable: #{inspect(reason)}")

  defp term_positive(ctx, f, {:ok, registry}) do
    term = World.admitted_term()

    reply =
      Context.stimulus(ctx, f, fn ->
        TermRegistry.admit_operational_use(registry, term, profile: :strict, consequential?: true)
      end)

    Result.positive(f,
      attempt_observed?: Evidence.seen?(ctx, f, @op_use, %{"iri" => term}),
      expected_outcome_observed?:
        Evidence.seen?(ctx, f, @op_use, %{"iri" => term, "outcome" => "admitted"}) and
          reply == {:ok, {:admitted, term}},
      evidence: %{"reply" => inspect(reply)}
    )
  end

  defp term_positive(_ctx, f, {:error, reason}),
    do: Result.blocked(f, "admitted term index unavailable: #{inspect(reason)}")

  defp cache_digest do
    :ash_a2a
    |> :code.priv_dir()
    |> to_string()
    |> Path.join("semantic/ontology_cache")
    |> Evidence.tree_digest()
  end

  # --- mappings ---------------------------------------------------------------------

  defp mapping_negative(ctx, f, receipt) do
    {peer_a, peer_b} = World.colliding_peers()
    canonical = MappingRegistry.new()

    reply =
      Context.stimulus(ctx, f, fn ->
        MappingRegistry.register(canonical, World.mapping(receipt))
      end)

    # Independent post-state: reconciliation over whatever registry the
    # executable world would hold after this call.
    world = with({:ok, registry} <- reply, do: registry, else: (_ -> canonical))
    reconciled = MappingRegistry.reconcile(world, peer_a, peer_b)

    Result.negative(f,
      attempt_observed?: Evidence.seen?(ctx, f, @register, %{"source" => peer_a.iri}),
      forbidden_outcome_observed?:
        Evidence.seen?(ctx, f, @register, %{"source" => peer_a.iri, "outcome" => "admitted"}) or
          match?({:ok, %{outcome: :admitted_mapping}}, reconciled),
      evidence: %{
        "reply" => inspect(reply, limit: 10, printable_limit: 512),
        "reconcile_after" => inspect(reconciled, limit: 10, printable_limit: 512)
      }
    )
  end

  defp mapping_positive(ctx, f) do
    {peer_a, peer_b} = World.colliding_peers()
    name = Module.concat(__MODULE__, "ReceiptStore#{System.unique_integer([:positive])}")
    {:ok, store} = AshA2A.ReceiptStore.Memory.start_link(name: name)

    try do
      receipt = committed_receipt(name, peer_a.iri, peer_b.iri)
      registry = MappingRegistry.new(receipt_store: {AshA2A.ReceiptStore.Memory, name: name})

      reply =
        Context.stimulus(ctx, f, fn ->
          MappingRegistry.register(registry, World.mapping(receipt))
        end)

      reconciled =
        case reply do
          {:ok, registry} -> MappingRegistry.reconcile(registry, peer_a, peer_b)
          other -> other
        end

      Result.positive(f,
        attempt_observed?: Evidence.seen?(ctx, f, @register, %{"source" => peer_a.iri}),
        expected_outcome_observed?:
          Evidence.seen?(ctx, f, @register, %{"source" => peer_a.iri, "outcome" => "admitted"}) and
            match?({:ok, %{outcome: :admitted_mapping}}, reconciled),
        evidence: %{
          "receipt_id" => receipt.receipt_id,
          "reconcile_after" => inspect(reconciled, limit: 10, printable_limit: 512)
        }
      )
    after
      if Process.alive?(store), do: GenServer.stop(store)
    end
  end

  # A receipt claimed, committed and read back from a real receipt store for
  # exactly this mapping's admission input: present and bound, not named.
  defp committed_receipt(store, source, target) do
    command =
      Command.new("AshA2A.Chicago.Courts.ExecutableWorld.admit_mapping",
        command_id: "chicago-adm-mapping-#{System.unique_integer([:positive])}",
        agent_id: "chicago-adm-agent",
        principal_id: "chicago-adm-principal",
        input: MappingRegistry.admission_input(source, target, :exact_match)
      )

    {:execute, %Identity{} = execution_id} =
      AshA2A.ReceiptStore.Memory.claim(command, name: store)

    receipt =
      command
      |> Receipt.pending(execution_id, :none)
      |> Receipt.finalize({:reply, %{admitted: true}})

    :ok = AshA2A.ReceiptStore.Memory.commit(receipt, name: store)
    {:ok, fetched} = AshA2A.ReceiptStore.Memory.fetch(command.command_id, name: store)
    fetched
  end

  # --- §44 --------------------------------------------------------------------------

  defp every_required_stage(ctx, f, scratch) do
    candidates = [
      parse: World.candidate(graph_ttl: World.malformed_rdf()),
      identity: World.candidate(expected_graph_hash: String.duplicate("0", 64)),
      shex: World.candidate(graph_ttl: World.shex_missing_required_predicate()),
      shacl: World.candidate(graph_ttl: World.shacl_do_without_receipt()),
      sparql_falsifiers: World.candidate(graph_ttl: World.graph_with_forbidden_state()),
      provenance: World.candidate(provenance: World.ungrounded_provenance()),
      profile_checks: World.candidate(profile_ttl: "")
    ]

    opts = Evidence.pipeline_opts(scratch)
    before = Evidence.canonical_snapshot(scratch)

    replies =
      Context.stimulus(ctx, f, fn ->
        for {stage, candidate} <- candidates do
          {stage, AdmissionPipeline.admit(candidate, opts)}
        end
      end)

    after_snapshot = Evidence.canonical_snapshot(scratch)

    refused_where_targeted? =
      Enum.all?(replies, fn {stage, reply} -> match?({:error, %{stage: ^stage}}, reply) end)

    Result.negative(f,
      attempt_observed?:
        refused_where_targeted? and
          Enum.all?(@required_failures, &Evidence.stage_seen?(ctx, f, &1, :refused)),
      forbidden_outcome_observed?:
        Evidence.admitted_seen?(ctx, f) or Enum.any?(replies, &match?({_, {:ok, _}}, &1)) or
          not Evidence.canonical_unchanged?(before, after_snapshot),
      evidence: %{
        "replies" =>
          Map.new(replies, fn {stage, reply} ->
            {stage,
             case reply do
               {:error, refusal} -> AshA2A.Semantic.AdmissionRefusal.describe(refusal)
               {:ok, result} -> "ADMITTED #{result.admission_digest}"
             end}
          end),
        "rule_closure" =>
          "no graph makes the pinned engine's DATALOG dialect refuse; this stage is exercised only by the positive control",
        "canonical_before" => before,
        "canonical_after" => after_snapshot
      }
    )
  end

  defp lawful_admitted(ctx, f, scratch) do
    {result, before, after_snapshot} = Evidence.admit(ctx, f, World.candidate(), scratch)

    Result.positive(f,
      attempt_observed?: Evidence.seen?(ctx, f, "admission.start"),
      expected_outcome_observed?:
        Enum.all?(AdmissionPipeline.required_stages(), &Evidence.stage_seen?(ctx, f, &1, :ok)) and
          Evidence.admitted_seen?(ctx, f) and
          match?(
            {:ok, %{standing: :admitted, authority: :none}},
            result
          ) and Evidence.canonical_unchanged?(before, after_snapshot),
      evidence: Evidence.admission_evidence(result, before, after_snapshot)
    )
  end
end
