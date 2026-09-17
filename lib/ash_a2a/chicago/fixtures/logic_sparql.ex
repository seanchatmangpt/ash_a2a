defmodule AshA2A.Chicago.Fixtures.LogicSparql do
  @moduledoc """
  Real inputs for the `SA2A-LOGIC` and `SA2A-SPARQL` courts
  (`AshA2A.Chicago.Courts.SafeLogic`, `AshA2A.Chicago.Courts.SparqlFalsifiers`).

  Every document here is real Turtle / N3 / ShExJ / SPARQL Update text handed to
  the real `praxis-graphlaw` engine or the real SA2A boundary modules. Nothing
  here fakes a verdict. Expected closure cardinalities are computed
  arithmetically from the program shape, never read back from the engine.
  """

  alias AshA2A.Semantic.{IR, Source}
  alias AshA2A.Semantic.AdmissionPipeline.Candidate

  @ns "http://example.org/chicago/logic#"
  @prefix "@prefix e: <#{@ns}> .\n"
  @math "@prefix math: <http://www.w3.org/2000/10/swap/math#> .\n"
  @string "@prefix string: <http://www.w3.org/2000/10/swap/string#> .\n"
  @log_iri "http://www.w3.org/2000/10/swap/log#"

  @doc "The fixture namespace."
  def ns, do: @ns

  # --- SA2A-LOGIC programs ---------------------------------------------------

  @doc "Admitted, safe, recursive: transitive closure of e:edge."
  def transitive_rules do
    @prefix <> "{ ?x e:edge ?y . ?y e:edge ?z } => { ?x e:edge ?z } .\n"
  end

  @doc """
  A chain `n1 -> n2 -> ... -> nk` as plain Turtle. `order: :reverse` writes the
  same graph with the statements reversed and the namespace under another
  prefix label (a different rendering of the identical RDF graph).
  """
  def chain_facts(k, order \\ :forward) when k >= 2 do
    edges = for i <- 1..(k - 1), do: {i, i + 1}

    case order do
      :forward ->
        @prefix <> Enum.map_join(edges, "\n", fn {a, b} -> "e:n#{a} e:edge e:n#{b} ." end)

      :reverse ->
        "@prefix other: <#{@ns}> .\n" <>
          (edges
           |> Enum.reverse()
           |> Enum.map_join("\n", fn {a, b} -> "other:n#{a} other:edge other:n#{b} ." end))
    end
  end

  @doc "Derived triple count of the transitive closure over a k-node chain: C(k,2) - (k-1)."
  def chain_derived(k), do: div(k * (k - 1), 2) - (k - 1)

  @doc "Admitted but pure-builtin, non-recursive: arithmetic and string builtins."
  def pure_builtin_rules do
    @prefix <>
      @math <>
      @string <>
      """
      { ?x e:score ?n . (?n 10) math:sum ?m } => { ?x e:boosted ?m } .
      { ?x e:name ?s . (?s "-checked") string:concat ?t } => { ?x e:label ?t } .
      """
  end

  def pure_builtin_facts do
    @prefix <>
      ~s(e:a e:score 1 ; e:name "alpha" .\ne:b e:score 2 ; e:name "beta" .\ne:c e:score 3 ; e:name "gamma" .)
  end

  @doc "Two derived triples per subject in `pure_builtin_facts/0`."
  def pure_builtin_derived, do: 6

  @doc "Non-range-restricted: ?w in the head is bound by nothing in the body."
  def unsafe_rules, do: @prefix <> "{ ?x e:edge ?y } => { ?x e:related ?w } .\n"

  @doc "Existential head: a blank node per firing (not function-free)."
  def existential_rules, do: @prefix <> "{ ?x e:edge ?y } => { ?y e:parent [ e:edge ?x ] } .\n"

  @doc "List term in the head: unbounded term creation (measured: runs until fuel is gone)."
  def list_head_rules, do: @prefix <> "{ ?x e:edge ?y } => { ?x e:edge (?y) } .\n"

  @doc "Recursion requiring unbounded arithmetic term creation."
  def unbounded_sum_rules,
    do: @prefix <> @math <> "{ ?x e:n ?n . (?n 1) math:sum ?m } => { ?x e:n ?m } .\n"

  def unbounded_sum_facts, do: @prefix <> "e:counter e:n 1 ."

  @doc "Side-effecting builtin (network fetch), in three spellings."
  def side_effecting_rules(:declared_prefix) do
    @prefix <>
      "@prefix log: <#{@log_iri}> .\n{ ?x e:source ?u . ?u log:semantics ?f } => { ?x e:fetched ?f } .\n"
  end

  def side_effecting_rules(:rebound_prefix) do
    @prefix <>
      "@prefix net: <#{@log_iri}> .\n{ ?x e:source ?u . ?u net:semantics ?f } => { ?x e:fetched ?f } .\n"
  end

  def side_effecting_rules(:full_iri) do
    @prefix <>
      "{ ?x e:source ?u . ?u <#{@log_iri}content> ?c } => { ?x e:fetched ?c } .\n"
  end

  @doc "Data turned into executed rules: log:parsedAsN3 + log:conclusion."
  def reification_rules do
    @prefix <>
      "@prefix log: <#{@log_iri}> .\n{ ?x e:ruleText ?t . ?t log:parsedAsN3 ?f . ?f log:conclusion ?g } => { ?x e:concluded ?g } .\n"
  end

  def reification_facts do
    @prefix <> ~s(e:a e:ruleText "{ ?s e:edge ?o } => { ?o e:edge ?s } ." .)
  end

  @doc "Pure builtin over an IRI that names a live network endpoint."
  def network_rules do
    @prefix <>
      "@prefix log: <#{@log_iri}> .\n{ ?x e:source ?u . ?u log:uri ?s } => { ?x e:sourceText ?s } .\n"
  end

  def network_facts(port) do
    @prefix <> "e:doc e:source <http://127.0.0.1:#{port}/chicago-logic-probe.ttl> ."
  end

  @doc "A rule smuggled into the fact channel, as `=>` and as a log:implies formula."
  def smuggled_facts(:implication),
    do: chain_facts(4) <> "\n{ ?x e:edge ?y } => { ?y e:edge ?x } .\n"

  def smuggled_facts(:log_implies),
    do: chain_facts(4) <> "\n{ ?x e:edge ?y } <#{@log_iri}implies> { ?y e:edge ?x } .\n"

  @doc "A byte-level mutation of an admitted rule document (one appended rule)."
  def mutated_transitive_rules,
    do: transitive_rules() <> "{ ?x e:edge ?y } => { ?y e:edge ?x } .\n"

  @doc "Rules deriving a consequence-bearing intent from an approval fact."
  def intent_rules do
    @prefix <> "{ ?r e:approvedFor ?l } => { ?r e:requestsCreateIntent ?l } .\n"
  end

  def intent_facts(label), do: @prefix <> ~s(e:request1 e:approvedFor "#{label}" .)

  def intent_witness(label),
    do: ~s(e:request1 e:requestsCreateIntent ?l . ?l <#{@log_iri}equalTo> "#{label}")

  @doc "Shallow B2 program: one non-recursive rule over `n` facts."
  def shallow_rules, do: @prefix <> "{ ?x e:parentOf ?y } => { ?y e:childOf ?x } .\n"

  def shallow_facts(n),
    do: @prefix <> Enum.map_join(1..n, "\n", fn i -> "e:p#{i} e:parentOf e:c#{i} ." end)

  # --- SA2A-SPARQL: admission pipeline law ----------------------------------

  @graph """
  @prefix ex: <http://example.org/> .
  @prefix schema: <http://schema.org/> .
  ex:a a ex:Goal ;
    schema:description "ship the admission pipeline" ;
    ex:owner ex:sean ;
    ex:dependsOn ex:b .
  """

  @shacl """
  @prefix sh: <http://www.w3.org/ns/shacl#> .
  @prefix ex: <http://example.org/> .
  @prefix schema: <http://schema.org/> .
  ex:GoalShape a sh:NodeShape ;
    sh:targetClass ex:Goal ;
    sh:property [ sh:path schema:description ; sh:minCount 1 ] ;
    sh:property [ sh:path ex:owner ; sh:minCount 1 ] .
  """

  @shex ~s({"shapes":[{"id":"http://example.org/GoalShEx","shapeExpr":{"type":"Shape","closed":false,"extra":[],"expression":{"type":"TripleConstraint","predicate":"http://schema.org/description","valueExpr":{"type":"NodeConstraint","datatype":"http://www.w3.org/2001/XMLSchema#string"},"min":1,"max":1}}}]})
  @shape_map ~s([["http://example.org/a","http://example.org/GoalShEx"]])

  @profile """
  @prefix owl: <http://www.w3.org/2002/07/owl#> .
  @prefix ex: <http://example.org/> .
  ex:Goal a owl:Class .
  """

  @source_text "The team agreed to ship the admission pipeline this week, with sean as owner.\n"

  @doc """
  The Root Manifest admitting this fixture's pipeline law -- the ShEx schema
  and shape map, SHACL shapes, OWL profile and all three falsifier sets --
  built over real files under `dir/sparql-law`
  (`AshA2A.Semantic.RootManifest.LawCorpus.build/3`).
  """
  @spec law_manifest!(Path.t()) :: AshA2A.Semantic.RootManifest.t()
  def law_manifest!(dir) do
    documents =
      [
        {"shex_schema", @shex},
        {"shex_shape_map", @shape_map},
        {"shacl_shapes", @shacl},
        {"semantic_profile", @profile}
      ] ++
        for(
          variant <- [:asserted, :derived, :derived_absent],
          do: {"n3_rules", falsifiers(variant)}
        )

    {:ok, manifest} =
      AshA2A.Semantic.RootManifest.LawCorpus.build(Path.join(dir, "sparql-law"), documents)

    manifest
  end

  @doc """
  A lawful admission candidate. `:falsifiers` is the mandatory graph-global
  falsifier set (N3 denials the engine evaluates over the closure).
  """
  def candidate(overrides \\ []) do
    source = Source.new(@source_text, id: "chicago-logic-sparql-source")

    {:ok, ir} =
      IR.from_map(source.id, %{
        "authority" => "none",
        "goals" => [
          %{
            "id" => "goal-1",
            "kind" => "goal",
            "description" => "ship the admission pipeline",
            "source_quote" => "ship the admission pipeline"
          }
        ]
      })

    struct!(
      %Candidate{
        graph_ttl: @graph,
        profile_ttl: @profile,
        shacl_shapes: @shacl,
        shex_schema: @shex,
        shex_shape_map: @shape_map,
        falsifiers: falsifiers(:asserted),
        provenance: {source, ir}
      },
      overrides
    )
  end

  def graph_with_forbidden, do: @graph <> "ex:z a ex:Forbidden .\n"

  @doc "Mandatory falsifier sets."
  def falsifiers(:asserted),
    do: "@prefix ex: <http://example.org/> .\n{ ?s a ex:Forbidden } => false .\n"

  # Only a *derived* fact trips it: ex:dependsOn marks the dependency Forbidden.
  def falsifiers(:derived) do
    "@prefix ex: <http://example.org/> .\n{ ?x ex:dependsOn ?y } => { ?y a ex:Forbidden } .\n{ ?s a ex:Forbidden } => false .\n"
  end

  # Same shape, but the rule's premise is absent from the graph.
  def falsifiers(:derived_absent) do
    "@prefix ex: <http://example.org/> .\n{ ?x ex:blockedBy ?y } => { ?y a ex:Forbidden } .\n{ ?s a ex:Forbidden } => false .\n"
  end

  # --- SA2A-SPARQL: RFC-SA2A-001 S61 structural suite -----------------------

  @sa "http://seanchatmangpt.github.io/sa2a#"

  def s61_graph(:consequence_without_authority),
    do: [
      {"http://example.org/chicago/cap1", @sa <> "hasConsequence",
       "http://example.org/chicago/change"}
    ]

  def s61_graph(:consequence_with_authority),
    do:
      s61_graph(:consequence_without_authority) ++
        [
          {"http://example.org/chicago/cap1", @sa <> "requiresAuthority",
           "http://example.org/chicago/grant"}
        ]

  # --- SA2A-SPARQL: RFC-SA2A-001 S18.4 update targets -----------------------

  @canonical "http://example.org/chicago/graph/canonical"
  @staging "http://example.org/chicago/graph/staging"
  @rdf_type "http://www.w3.org/1999/02/22-rdf-syntax-ns#type"

  def canonical_graph, do: @canonical
  def staging_graph, do: @staging

  def update_classification,
    do: [
      {@canonical, @rdf_type, @sa <> "CanonicalGraph"},
      {@staging, @rdf_type, @sa <> "StagingGraph"}
    ]

  @doc "SPARQL 1.1 Update requests, by attack."
  def update(:canonical_insert_data),
    do:
      "INSERT DATA { GRAPH <#{@canonical}> { <urn:chicago:s> <urn:chicago:p> <urn:chicago:o> } }"

  def update(:staging_insert_data),
    do: "INSERT DATA { GRAPH <#{@staging}> { <urn:chicago:s> <urn:chicago:p> <urn:chicago:o> } }"

  def update(:prefixed_canonical),
    do:
      "PREFIX g: <http://example.org/chicago/graph/> INSERT DATA { GRAPH g:canonical { <urn:chicago:s> <urn:chicago:p> <urn:chicago:o> } }"

  def update(:move_default), do: "MOVE DEFAULT TO <#{@staging}>"

  # SPARQL 1.1 Query §19.2: \u/\U codepoint escapes are processed before the
  # grammar, so this IS `INSERT DATA { ... }` into the default graph.
  def update(:escaped_keyword),
    do: "\\u0049NSERT DATA { <urn:chicago:s> <urn:chicago:p> <urn:chicago:o> }"

  def update(:escaped_default_operand), do: "MOVE \\u0044EFAULT TO <#{@staging}>"

  # SPARQL 1.1 Update QuadData: triples outside a GRAPH block in the same
  # template are default-graph triples.
  def update(:mixed_quad_data),
    do:
      "INSERT DATA { GRAPH <#{@staging}> { <urn:chicago:a> <urn:chicago:b> <urn:chicago:c> } <urn:chicago:s> <urn:chicago:p> <urn:chicago:o> }"

  def update(:mixed_modify_template),
    do:
      "INSERT { GRAPH <#{@staging}> { ?s ?p ?o } ?s <urn:chicago:leak> ?o } WHERE { GRAPH <#{@staging}> { ?s ?p ?o } }"

  # WITH scopes only the operation it opens; the second operation's bare
  # template writes the default graph.
  def update(:with_scope_leak),
    do:
      "WITH <#{@staging}> DELETE { ?s ?p ?o } WHERE { ?s ?p ?o } ; INSERT { ?s ?p ?o } WHERE { GRAPH <#{@staging}> { ?s ?p ?o } }"

  # Triple-quoted literals whose content holds unbalanced `"`, `{` and `}`: a
  # scanner without long-string state sees the bare triples as inside the
  # staging GRAPH block. rdflib 7.6.0 reads two default-graph triples.
  def update(:long_literal_desync),
    do:
      ~s(INSERT DATA { GRAPH <#{@staging}> { <urn:chicago:a> <urn:chicago:b> """x" { "y""" } <urn:chicago:s> <urn:chicago:p> <urn:chicago:o> . <urn:chicago:c> <urn:chicago:d> """z" } "w""" })

  def update(:comment_masked),
    do: "INSERT DATA { <urn:chicago:s> <urn:chicago:p> <urn:chicago:o> } # GRAPH <#{@staging}>"

  def update(:staging_modify_with),
    do:
      "WITH <#{@staging}> DELETE { ?s ?p ?o } INSERT { ?s ?p <urn:chicago:o2> } WHERE { ?s ?p ?o }"

  defmodule Domain do
    @moduledoc "Fixture domain for `AshA2A.Chicago.Fixtures.LogicSparql.Intent`."
    use Ash.Domain, extensions: [AshA2A], validate_config_inclusion?: false

    resources do
      resource(AshA2A.Chicago.Fixtures.LogicSparql.Intent)
    end
  end

  defmodule Intent do
    @moduledoc """
    A real consequence-bearing (`:change`) Ash resource: the actuator a
    rule-derived intent would reach if derivation implied authority.
    """
    use Ash.Resource,
      domain: AshA2A.Chicago.Fixtures.LogicSparql.Domain,
      data_layer: Ash.DataLayer.Ets,
      extensions: [AshA2A]

    attributes do
      uuid_primary_key(:id)
      attribute(:label, :string, public?: true, allow_nil?: false)
    end

    actions do
      defaults([:read, create: [:label]])
    end

    a2a do
      skill(:create_intent, :create)
    end
  end

  defmodule NetworkProbe do
    @moduledoc """
    A real loopback TCP listener that counts accepted connections: an
    environment observer for "no runtime network access". Calibrated by the
    court with a real connection of its own, so a blind probe cannot pass.
    """

    @spec start() :: map()
    def start do
      {:ok, listen} =
        :gen_tcp.listen(0, [:binary, active: false, ip: {127, 0, 0, 1}, reuseaddr: true])

      {:ok, port} = :inet.port(listen)
      counter = :counters.new(1, [:write_concurrency])
      acceptor = spawn(fn -> accept_loop(listen, counter) end)

      %{listen: listen, port: port, counter: counter, acceptor: acceptor}
    end

    @spec connections(map()) :: non_neg_integer()
    def connections(%{counter: counter}), do: :counters.get(counter, 1)

    @doc "Opens one real connection to the probe and waits until it is counted."
    @spec calibrate(map()) :: boolean()
    def calibrate(%{port: port} = probe) do
      before = connections(probe)

      case :gen_tcp.connect({127, 0, 0, 1}, port, [:binary, active: false], 2_000) do
        {:ok, socket} ->
          :gen_tcp.close(socket)
          wait_for(probe, before + 1, 40)

        _ ->
          false
      end
    end

    @spec stop(map()) :: :ok
    def stop(%{listen: listen, acceptor: acceptor}) do
      :gen_tcp.close(listen)
      Process.exit(acceptor, :kill)
      :ok
    end

    defp wait_for(probe, expected, 0), do: connections(probe) >= expected

    defp wait_for(probe, expected, tries) do
      if connections(probe) >= expected do
        true
      else
        Process.sleep(25)
        wait_for(probe, expected, tries - 1)
      end
    end

    defp accept_loop(listen, counter) do
      case :gen_tcp.accept(listen) do
        {:ok, socket} ->
          :counters.add(counter, 1, 1)
          :gen_tcp.close(socket)
          accept_loop(listen, counter)

        {:error, _} ->
          :ok
      end
    end
  end
end
