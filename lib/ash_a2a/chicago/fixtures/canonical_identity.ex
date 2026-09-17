defmodule AshA2A.Chicago.Fixtures.CanonicalIdentity do
  @moduledoc """
  Real inputs for the `SA2A-CANON`, `SA2A-NS`, `SA2A-PROJECTION` and
  `SA2A-CANONMUT` courts (RFC-SA2A-002 §50, §51, §77, §78).

  Every document here is real Turtle / JSON handed to the real SA2A boundary
  modules; every admitted IR goes through the real
  `AshA2A.Semantic.Admission.admit/2`; every manifest is written to disk and
  read back through the real `AshA2A.Semantic.RootManifest.load/2`. Nothing
  here fakes a verdict.

  `mappings/0` is the one admitted OCEL mapping set for the boundary telemetry
  these courts rely on; all four courts return it from `ocel_mappings/0`, so
  the runner admits each mapping once.
  """

  alias AshA2A.Chicago.Courts.InferenceMappings
  alias AshA2A.Chicago.Ocel.Mapping
  alias AshA2A.Semantic.{Admission, CanonicalGraph, IR, Ontology, OntologyCache, PlanningIR}
  alias AshA2A.Semantic.{PlanPackage, PlanProjection, RootManifest, Serialize, Source}
  alias AshA2A.Semantic.RootManifest.ConformanceCorpus

  # --- OCEL mappings ----------------------------------------------------------

  @doc """
  Admitted OCEL mappings for the boundary telemetry of the four courts.

  IR admission (`SA2A-CANONMUT`'s falsifier 6/7) reuses the single canonical
  `[:ash_a2a, :semantic, :ir_admission]` event/mapping from
  `InferenceMappings.ir_admission/0` rather than declaring a second one here:
  an earlier version of this branch emitted its own
  `[:ash_a2a, :semantic, :ir_admission, :decision]` event for the same real
  admission decision `AshA2A.Semantic.Admission.admit/2` makes; that duplicate
  was collapsed into the one event `llm_boundary.ex` already observes (see
  `AshA2A.Semantic.Admission.emit_admission/3`) rather than keeping two
  events for one decision.
  """
  @spec mappings() :: [Mapping.t()]
  def mappings do
    for {event, activity, keys} <- [
          {[:canonical_graph, :digest], "canonical_graph.digest",
           [:outcome, :code, :algorithm_id]},
          {[:canonical_graph, :compare], "canonical_graph.compare",
           [:outcome, :code, :algorithm_id]},
          {[:canonical_graph, :pin], "canonical_graph.pin", [:outcome, :code, :field]},
          {[:root_manifest, :load], "root_manifest.load", [:outcome, :code, :digest]},
          {[:iri, :resolve], "iri.resolve", [:outcome, :step, :code]},
          {[:iri, :mint_private], "iri.mint_private", [:outcome, :code]},
          {[:term_registry, :operational_use], "term_registry.operational_use",
           [:outcome, :code, :profile, :consequential]},
          {[:term_registry, :build], "term_registry.build", [:outcome, :code, :size]},
          {[:mapping_registry, :register], "mapping_registry.register", [:outcome, :code]},
          {[:mapping_registry, :reconcile], "mapping_registry.reconcile",
           [:outcome, :code, :labels_match]},
          {[:plan_projection, :verify], "plan_projection.verify", [:outcome, :code, :mode]},
          {[:plan_package, :build], "plan_package.build", [:outcome, :code, :standing]},
          {[:plan_package, :verify], "plan_package.verify", [:outcome, :code, :standing]},
          {[:ontology_cache, :load], "ontology_cache.load", [:outcome, :code, :iri]},
          {[:ontology, :project], "ontology.project", [:outcome, :code, :input_standing]}
        ] do
      Mapping.new!(
        event: [:ash_a2a, :semantic | event],
        activity: activity,
        source: __MODULE__,
        attributes: fn _m, meta -> Map.take(meta, keys) end
      )
    end ++ [InferenceMappings.ir_admission()]
  end

  @doc """
  True when the observer attributed a record of `activity` to `falsifier`
  whose attributes string-equal every pair in `attrs` (the court's in-run view;
  standing is still re-derived from the durable OCEL artifact).
  """
  @spec observed?(AshA2A.Chicago.Context.t(), AshA2A.Chicago.Falsifier.t(), String.t(), map()) ::
          boolean()
  def observed?(ctx, falsifier, activity, attrs \\ %{}) do
    ctx
    |> AshA2A.Chicago.Context.observed(falsifier)
    |> Enum.any?(fn record ->
      record.activity == activity and
        Enum.all?(attrs, fn {k, v} -> to_string(Map.get(record.attributes, k)) == to_string(v) end)
    end)
  end

  # --- SA2A-CANON: canonical graph identity corpus ---------------------------

  @ex "http://example.org/chicago/canon#"

  @doc """
  RDF documents by name. Every `:iso_*` document denotes the graph `:base`
  denotes (RDF 1.1 graph isomorphism); `:distinct_*` documents do not.
  """
  @spec graph(atom()) :: String.t()
  def graph(:base) do
    """
    @prefix ex: <#{@ex}> .
    ex:order1 ex:status ex:open .
    ex:order1 ex:total "42"^^<http://www.w3.org/2001/XMLSchema#integer> .
    ex:order1 ex:line _:l1 .
    _:l1 ex:sku ex:widget .
    _:l1 ex:qty "3"^^<http://www.w3.org/2001/XMLSchema#integer> .
    """
  end

  # Same statements, reverse order.
  def graph(:iso_triple_reorder) do
    """
    @prefix ex: <#{@ex}> .
    _:l1 ex:qty "3"^^<http://www.w3.org/2001/XMLSchema#integer> .
    _:l1 ex:sku ex:widget .
    ex:order1 ex:line _:l1 .
    ex:order1 ex:total "42"^^<http://www.w3.org/2001/XMLSchema#integer> .
    ex:order1 ex:status ex:open .
    """
  end

  # Different prefix label, SPARQL-style PREFIX, an unused alias declared
  # first, a second alias for the same namespace, and the xsd prefix.
  def graph(:iso_prefix_alias) do
    """
    @prefix unused: <http://example.org/unused#> .
    PREFIX xsd: <http://www.w3.org/2001/XMLSchema#>
    @prefix o: <#{@ex}> .
    @prefix alias: <#{@ex}> .
    alias:order1 o:status alias:open .
    o:order1 alias:total "42"^^xsd:integer .
    o:order1 o:line _:l1 .
    _:l1 alias:sku o:widget .
    _:l1 o:qty "3"^^xsd:integer .
    """
  end

  # Whitespace, comments, predicate/object lists and N-Triples syntax.
  def graph(:iso_serialization) do
    """
    # N-Triples lines are Turtle too.
    <#{@ex}order1>    <#{@ex}status>   <#{@ex}open> .


    <#{@ex}order1> <#{@ex}total> "42"^^<http://www.w3.org/2001/XMLSchema#integer> ;
                   <#{@ex}line>  _:line   .   # trailing comment
    _:line <#{@ex}sku> <#{@ex}widget> ; <#{@ex}qty> 3 .
    """
  end

  # Blank node relabeled.
  def graph(:iso_bnode_relabel) do
    """
    @prefix ex: <#{@ex}> .
    ex:order1 ex:status ex:open .
    ex:order1 ex:total "42"^^<http://www.w3.org/2001/XMLSchema#integer> .
    ex:order1 ex:line _:zz9 .
    _:zz9 ex:sku ex:widget .
    _:zz9 ex:qty "3"^^<http://www.w3.org/2001/XMLSchema#integer> .
    """
  end

  # Anonymous blank-node syntax (no label at all).
  def graph(:iso_bnode_anonymous) do
    """
    @prefix ex: <#{@ex}> .
    ex:order1 ex:line [ ex:qty "3"^^<http://www.w3.org/2001/XMLSchema#integer> ; ex:sku ex:widget ] ;
      ex:total "42"^^<http://www.w3.org/2001/XMLSchema#integer> ;
      ex:status ex:open .
    """
  end

  # One object IRI changed.
  def graph(:distinct_iri) do
    String.replace(graph(:base), "ex:status ex:open", "ex:status ex:closed")
  end

  # Two graphs over the same predicate, constants and triple count whose blank
  # node structure differs (a chain vs a fan): not isomorphic.
  def graph(:bnode_chain) do
    """
    @prefix ex: <#{@ex}> .
    ex:root ex:next _:a .
    _:a ex:next _:b .
    _:b ex:next ex:leaf .
    """
  end

  def graph(:distinct_bnode_structure) do
    """
    @prefix ex: <#{@ex}> .
    ex:root ex:next _:a .
    ex:root ex:next _:b .
    _:b ex:next ex:leaf .
    """
  end

  @doc "Malformed or non-RDF inputs that must never receive an identity."
  @spec malformed(atom()) :: binary()
  def malformed(:unterminated), do: "@prefix ex: <#{@ex}> .\nex:order1 ex:status \"open ."

  # praxis-graphlaw's wasm graph_hash returns the digest of the parseable
  # prefix for this input, i.e. a confident digest of a different graph.
  def malformed(:trailing_garbage), do: graph(:base) <> "GARBAGE !!! <<>> ;;\n"

  def malformed(:invalid_utf8),
    do: "@prefix ex: <#{@ex}> .\nex:a ex:p \"" <> <<0xFF, 0xFE>> <> "\" ."

  # --- SA2A-CANON: Root Manifest canonicalization pins -----------------------

  @doc "The committed Root Manifest path (the one `RootManifest.load/2` defaults to)."
  @spec committed_manifest_path() :: Path.t()
  def committed_manifest_path, do: ConformanceCorpus.manifest_path()

  @doc """
  Writes a copy of the committed Root Manifest whose `"canonicalization"` pin
  has been changed by `drift`, with a freshly recomputed content address (so
  the self-address check cannot be what refuses it). Returns the path.
  """
  @spec drifted_manifest(Path.t(), :algorithm | :hash_function | :implementation) ::
          {:ok, Path.t()} | {:error, term()}
  def drifted_manifest(dir, drift) do
    with {:ok, manifest} <- RootManifest.load(committed_manifest_path(), require_engine: false) do
      pinned = manifest.canonicalization

      canonicalization =
        case drift do
          :algorithm ->
            Map.merge(pinned, %{
              "algorithm" => "URDNA2015",
              "algorithm_id" => "URDNA2015/SHA-256/n-quads-sorted"
            })

          :hash_function ->
            Map.merge(pinned, %{
              "hash_function" => "SHA-384",
              "algorithm_id" => "RDFC-1.0/SHA-384/n-quads-sorted"
            })

          :implementation ->
            # The pin the manifest carried before SA2A-CANON: the wasm engine's
            # graph_hash (BLAKE3, not blank-node invariant) named as the executor.
            Map.merge(pinned, %{
              "implementation" => "oxrdf",
              "executed_by" => "praxis-graphlaw-wasm",
              "library" => "praxis-graphlaw v26.7.5"
            })
        end

      drifted = %{manifest | canonicalization: canonicalization}
      drifted = %{drifted | digest: RootManifest.content_digest(drifted)}
      path = Path.join([dir, "drift-#{drift}", "root_manifest.json"])
      RootManifest.write!(drifted, path)
      {:ok, path}
    end
  end

  @doc "Load options that resolve a copied manifest's pins against the real corpus."
  @spec manifest_load_opts() :: keyword()
  def manifest_load_opts, do: [root: ConformanceCorpus.root(), require_engine: false]

  # --- SA2A-PROJECTION: generated Root Manifest hand edit --------------------

  @doc """
  Writes a hand-edited copy of the committed, generated Root Manifest: the
  version policy is flipped to let ordinary transport agents mutate the trust
  root, and the recorded `digest` is left as generated. Returns the path.
  """
  @spec hand_edited_manifest(Path.t()) :: Path.t()
  def hand_edited_manifest(dir) do
    decoded = committed_manifest_path() |> File.read!() |> JSON.decode!()

    edited =
      put_in(decoded, ["version_policy", "ordinary_transport_agents_may_mutate"], true)

    path = Path.join([dir, "hand-edited", "root_manifest.json"])
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, JSON.encode!(edited))
    path
  end

  # --- SA2A-PROJECTION / SA2A-CANONMUT: admitted semantics ------------------

  @source_text """
  The meeting opens and the facilitator must advance the room through every
  phase in order until it can close. The room starts at the open phase.
  The facilitator can advance the room from one phase to the next phase.
  Attendance may vary, so the room count is unclear at the start.
  No phase may be skipped.
  """

  @doc "The real source every admitted `source_quote` is grounded in."
  @spec source() :: Source.t()
  def source, do: Source.new(@source_text, id: "chicago-canonical-identity-src-1")

  @doc "The IR proposal, as a JSON-shaped map (what a message or model would carry)."
  @spec ir_payload() :: map()
  def ir_payload do
    %{
      "authority" => "none",
      "entities" => [
        %{
          "id" => "room",
          "kind" => "entity",
          "type" => "schema:Place",
          "label" => "the room",
          "description" => "the room being advanced through phases",
          "source_quote" => "the room"
        },
        %{
          "id" => "facilitator",
          "kind" => "entity",
          "type" => "schema:Person",
          "label" => "the facilitator",
          "description" => "the person advancing the room",
          "source_quote" => "the facilitator"
        }
      ],
      "relations" => [
        %{
          "id" => "rel-advance",
          "kind" => "relation",
          "subject" => "facilitator",
          "predicate" => "schema:agent",
          "object" => "room",
          "description" => "the facilitator advances the room",
          "source_quote" => "advance the room"
        }
      ],
      "goals" => [
        %{
          "id" => "goal-close",
          "kind" => "goal",
          "description" => "advance the room through every phase until it can close",
          "source_quote" => "advance the room through every"
        }
      ],
      "constraints" => [
        %{
          "id" => "constraint-order",
          "kind" => "constraint",
          "description" => "phases must be advanced in order",
          "source_quote" => "in order"
        }
      ],
      "capabilities" => [
        %{
          "id" => "cap-advance",
          "kind" => "capability",
          "description" => "advance the room from one phase to the next phase",
          "source_quote" => "advance the room from one phase to the next phase"
        }
      ],
      "observations" => [
        %{
          "id" => "obs-open",
          "kind" => "observation",
          "description" => "the room starts at the open phase",
          "source_quote" => "The room starts at the open phase"
        }
      ],
      "uncertainties" => [
        %{
          "id" => "unc-count",
          "kind" => "uncertainty",
          "description" => "the room count is unclear at the start",
          "source_quote" => "the room count is unclear"
        }
      ],
      "exclusions" => [
        %{
          "id" => "excl-skip",
          "kind" => "exclusion",
          "description" => "no phase may be skipped",
          "source_quote" => "No phase may be skipped"
        }
      ]
    }
  end

  @doc "The candidate IR built by the real `IR.from_map/2`."
  @spec candidate_ir() :: IR.t()
  def candidate_ir do
    {:ok, ir} = IR.from_map(source().id, ir_payload())
    ir
  end

  @doc "The IR admitted by the real `Admission.admit/2` (raises if refused)."
  @spec admitted_ir() :: IR.t()
  def admitted_ir do
    {:ok, %IR{standing: :admitted} = ir} = Admission.admit(source(), candidate_ir())
    ir
  end

  @doc "`{admitted_ir, ontology, planning_ir, projection}` through the real manufacturers."
  @spec admitted_chain() :: {IR.t(), Ontology.t(), PlanningIR.t(), PlanProjection.t()}
  def admitted_chain do
    ir = admitted_ir()
    {:ok, ontology} = Ontology.from_ir(ir)
    {:ok, planning} = PlanningIR.from_ir(ir, ontology)
    {:ok, projection} = PlanProjection.from_admitted(planning, ontology)
    {ir, ontology, planning, projection}
  end

  @doc "Strict plan-package options with every production bound present."
  @spec package_opts() :: keyword()
  def package_opts do
    [
      profile: :strict,
      consequence_class: :change,
      required_capabilities: ["AshA2A.Chicago.Fixtures.CanonicalIdentity.advance"],
      max_fan_out: 1,
      max_depth: 4,
      max_parallelism: 1,
      resource_envelope: %{max_wall_ms: 1_000, max_memory_bytes: 1_048_576, max_invocations: 4},
      authority_requirements: [%{capability: "advance", scope: "room"}],
      receipt_obligations: [:prepared, :committed],
      preconditions: [{:at_phase, ["room", "open"]}],
      effects: [{:at_phase, ["room", "closed"]}]
    ]
  end

  @doc """
  Independent reader of canonical `O*`: the RFC S12 RDFC-1.0 identity of the
  ontology's own N-Triples serialization (`Serialize` -> `CanonicalGraph`).
  """
  @spec canonical_o_star(Ontology.t()) :: {:ok, String.t()} | {:error, term()}
  def canonical_o_star(%Ontology{} = ontology) do
    with {:ok, nt} <- Serialize.to_ntriples(ontology), do: CanonicalGraph.canonical_digest(nt)
  end

  @doc "A projection hand-edited and re-digested so its self-check agrees (consistent forgery)."
  @spec consistent_forgery(PlanProjection.t()) :: PlanProjection.t()
  def consistent_forgery(%PlanProjection{} = projection) do
    edited = %{projection | goals: ["advance the room straight to close, skipping phases"]}
    %{edited | projection_digest: PlanProjection.content_digest(edited)}
  end

  @doc "A package whose standing/authority fence is rewritten and re-digested."
  @spec forged_package(PlanPackage.t()) :: PlanPackage.t()
  def forged_package(%PlanPackage{} = package) do
    forged = %{package | standing: :admitted, authority: :full}
    %{forged | plan_digest: PlanPackage.content_digest(forged)}
  end

  @doc "The payload a projection-to-canonical promoter would submit: projection content as IR."
  @spec projection_as_ir_payload(PlanProjection.t()) :: map()
  def projection_as_ir_payload(%PlanProjection{} = projection) do
    %{
      "authority" => "none",
      "standing" => "admitted",
      "goals" =>
        Enum.with_index(projection.goals, fn goal, i ->
          %{"id" => "projected-goal-#{i}", "kind" => "goal", "description" => goal}
        end),
      "entities" => Enum.map(projection.objects, &Map.put(&1, "kind", "entity")),
      "relations" =>
        Enum.with_index(projection.predicates, fn p, i ->
          Map.merge(p, %{"id" => "projected-rel-#{i}", "kind" => "relation"})
        end)
    }
  end

  @doc "An inbound A2A message whose data part asserts admitted, canonical standing."
  @spec canonical_claim_message() :: A2A.Message.t()
  def canonical_claim_message do
    payload =
      ir_payload()
      |> Map.put("standing", "admitted")
      |> Map.put("canonical", true)
      |> Map.update!("goals", fn goals ->
        goals ++
          [
            %{
              "id" => "goal-message",
              "kind" => "goal",
              "description" => "close the room immediately",
              "source_quote" => "per the sender"
            }
          ]
      end)

    A2A.Message.new_user([A2A.Part.Data.new(payload)])
  end

  @doc "The data payload of the first data part of a message."
  @spec message_data(A2A.Message.t()) :: map()
  def message_data(%A2A.Message{parts: parts}) do
    Enum.find_value(parts, %{}, fn
      %A2A.Part.Data{data: data} -> data
      _ -> nil
    end)
  end

  @doc """
  Model output (a decoded structured-generation object) that claims canonical
  standing for facts the source does not contain.
  """
  @spec llm_canonical_claim() :: map()
  def llm_canonical_claim do
    ir_payload()
    |> Map.put("standing", "admitted")
    |> Map.put("canonical_state", "commit")
    |> Map.update!("goals", fn goals ->
      goals ++
        [
          %{
            "id" => "goal-model",
            "kind" => "goal",
            "description" => "skip straight to the closed phase",
            "source_quote" => "the model is confident the room may skip phases"
          }
        ]
    end)
  end

  # --- SA2A-CANONMUT: canonical vocabulary datastore -------------------------

  @skos "http://www.w3.org/2004/02/skos/core#"
  @injected "#{@skos}chicagoInjectedTerm"

  def skos_ns, do: @skos
  def injected_term, do: @injected

  @doc "Copies the real canonical ontology cache (the admitted vocabulary datastore) to `dir`."
  @spec copy_ontology_cache(Path.t(), String.t()) :: Path.t()
  def copy_ontology_cache(dir, name) do
    root = Path.join(dir, name)
    File.mkdir_p!(root)
    File.cp_r!(OntologyCache.default_root(), root)
    root
  end

  @doc """
  Direct datastore write: appends a term declaration to the cached SKOS
  document bytes, bypassing admission. With `consistent: true` the cache
  manifest is rewritten to pin the new bytes as well.
  """
  @spec direct_write(Path.t(), keyword()) :: :ok
  def direct_write(root, opts \\ []) do
    manifest_path = Path.join(root, "manifest.json")
    manifest = manifest_path |> File.read!() |> Jason.decode!()

    {entry, index} =
      manifest["entries"] |> Enum.with_index() |> Enum.find(fn {e, _} -> e["iri"] == @skos end)

    object_path = Path.join(root, entry["object"])

    bytes =
      File.read!(object_path) <>
        "\n<#{@injected}> a <http://www.w3.org/1999/02/22-rdf-syntax-ns#Property> .\n"

    File.write!(object_path, bytes)

    if Keyword.get(opts, :consistent, false) do
      forged =
        Map.merge(entry, %{
          "content_digest" => OntologyCache.digest(bytes),
          "byte_size" => byte_size(bytes)
        })

      manifest =
        put_in(manifest, ["entries"], List.replace_at(manifest["entries"], index, forged))

      File.write!(manifest_path, Jason.encode!(manifest, pretty: true))
    end

    :ok
  end

  # --- SA2A-CANONMUT: staging vs canonical classification --------------------

  @sa "http://seanchatmangpt.github.io/sa2a#"
  @rdf_type "http://www.w3.org/1999/02/22-rdf-syntax-ns#type"
  @ambiguous "http://example.org/chicago/canonmut/graph/ambiguous"
  @staging "http://example.org/chicago/canonmut/graph/staging"

  @doc "A classification graph where one IRI is typed BOTH canonical and staging."
  @spec ambiguous_classification() :: [tuple()]
  def ambiguous_classification do
    [
      {@ambiguous, @rdf_type, @sa <> "StagingGraph"},
      {@ambiguous, @rdf_type, @sa <> "CanonicalGraph"},
      {@staging, @rdf_type, @sa <> "StagingGraph"}
    ]
  end

  @spec update(:ambiguous | :staging) :: String.t()
  def update(:ambiguous),
    do:
      "INSERT DATA { GRAPH <#{@ambiguous}> { <urn:chicago:s> <urn:chicago:p> <urn:chicago:o> } }"

  def update(:staging),
    do: "INSERT DATA { GRAPH <#{@staging}> { <urn:chicago:s> <urn:chicago:p> <urn:chicago:o> } }"

  # --- SA2A-NS ------------------------------------------------------------------

  @owl "http://www.w3.org/2002/07/owl#"

  def skos_concept, do: @skos <> "Concept"
  def owl_class, do: @owl <> "Class"

  @doc "A real, non-empty admission receipt reference."
  @spec receipt(String.t()) :: map()
  def receipt(tag),
    do: %{receipt_id: "rcpt-chicago-ns-#{tag}", fingerprint: "fp-chicago-ns-#{tag}"}

  @doc "Complete private term attributes (RFC S7.2), with `overrides` merged."
  @spec private_term(map()) :: map()
  def private_term(overrides \\ %{}) do
    Map.merge(
      %{
        iri: "urn:ash-a2a:semantic:BerthWindowClearance",
        label: "Berth Window Clearance",
        definition:
          "Clearance granted to a vessel to occupy a specific berth during a specific window.",
        scope: :organization_private,
        owning_namespace: "urn:ash-a2a:semantic:",
        version: "2026.09.16",
        provenance: %{
          searched_sources: [@skos, @owl],
          public_absence_reason:
            "No admitted public source declares berth-window clearance semantics."
        },
        mappings: [%{target: @skos <> "Concept", kind: :broad_match}],
        admission_receipt: receipt("private-term")
      },
      overrides
    )
  end

  @doc "Two peers claiming the same capability label."
  @spec peers(:same_label_different_identity | :same_identity) :: {map(), map()}
  def peers(:same_label_different_identity) do
    {%{peer_id: "peer-a", label: "Create Invoice", iri: "https://schema.org/CreateAction"},
     %{
       peer_id: "peer-b",
       label: "create invoice",
       iri: "http://example.org/chicago/acme#CreateInvoice"
     }}
  end

  def peers(:same_identity) do
    {%{peer_id: "peer-a", label: "Create Invoice", iri: "https://schema.org/CreateAction"},
     %{peer_id: "peer-b", label: "Invoice creation", iri: "https://schema.org/CreateAction"}}
  end
end
