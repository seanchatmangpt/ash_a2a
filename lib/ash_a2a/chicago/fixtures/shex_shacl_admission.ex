defmodule AshA2A.Chicago.Fixtures.ShexShaclAdmission do
  @moduledoc """
  Real law and real candidate graphs for the Gate 2 / admission-pipeline /
  ShEx / SHACL Chicago courts (RFC-SA2A-002 §33, §44, §45, §46):
  `AshA2A.Chicago.Courts.ExecutableWorld`, `AshA2A.Chicago.Courts.Shex` and
  `AshA2A.Chicago.Courts.Shacl`.

  Nothing here decides a verdict. Every document is real input for the real
  `praxis-graphlaw` engine reached through the real
  `AshA2A.Semantic.AdmissionPipeline`; the verdicts come from running it.

  ## The executable world's admitted law

    * **ShEx** (`shex_schema/0`, ShExJ -- the engine's `validate_all/5` entry
      point takes ShExJ, not ShExC) answers "is this object structurally a
      member of the world language?" (RFC-SA2A-001 S14): required predicate,
      cardinality, datatype, node kind, and a nested capability shape.
    * **SHACL** (`shacl_shapes/0`) answers "may an object having this
      structure have standing?" (RFC-SA2A-001 S15), encoding the four S15
      examples plus the S61 resource-bound and canonical-mutation invariants,
      and one `sh:Warning`-severity documentation shape so the severity rule
      ("warnings MUST NOT override a MUST-level violation") has a real subject.
    * **N3 falsifiers** (`falsifiers/0`), the **OWL RL profile** (`profile/0`)
      and a grounded **provenance** witness (`provenance/0`) complete the
      required stage set, so a lawful candidate really reaches `:admitted`.

  Every negative vector is `world_graph/0` with exactly one mutation, so a
  refusal names one cause (RFC-SA2A-002 §11, §22).
  """

  alias AshA2A.Semantic.{IR, Source}
  alias AshA2A.Semantic.AdmissionPipeline.Candidate

  @ex "http://example.org/sa2a-world/"
  @sa "http://seanchatmangpt.github.io/sa2a#"

  @prefixes """
  @prefix ex: <#{@ex}> .
  @prefix sa: <#{@sa}> .
  @prefix rdfs: <http://www.w3.org/2000/01/rdf-schema#> .
  @prefix xsd: <http://www.w3.org/2001/XMLSchema#> .
  """

  # --- the world ------------------------------------------------------------

  @world_node """
  ex:world a sa:World ;
    rdfs:label "Gate 2 executable world" ;
    rdfs:comment "The admitted world every Gate 2 candidate is judged against." ;
    sa:version 1 ;
    sa:homepage ex:home ;
    sa:capability ex:capPlan .
  """

  @capability """
  ex:capPlan a sa:Capability ;
    sa:tier 1 .
  """

  @consequence """
  ex:action1 sa:hasConsequence sa:Change ;
    sa:requiresAuthority ex:grantPolicy .
  """

  @do_step """
  ex:do1 a sa:DoStep ;
    sa:preparedReceipt ex:receiptAnchor .
  """

  @plan """
  ex:plan1 a sa:Plan ;
    sa:usesCapability ex:capPlan ;
    sa:fanOut 3 ;
    sa:resourceCost 5 ;
    sa:resourceBudget 10 .
  """

  @private_term """
  <#{@ex}admitted-ns/berthWindow> a sa:PrivateTerm .
  """

  @mutation """
  ex:mutation1 a sa:CanonicalMutation ;
    sa:viaBoundary sa:CommandBus .
  """

  @parts [
    world: @world_node,
    capability: @capability,
    consequence: @consequence,
    do_step: @do_step,
    plan: @plan,
    private_term: @private_term,
    mutation: @mutation
  ]

  @doc "The lawful baseline world graph: conforms to every admitted law document."
  @spec world_graph() :: String.t()
  def world_graph, do: graph([])

  @doc """
  The world graph with named parts replaced. `replacements` is a keyword list
  of `part => turtle` (use `""` to drop a part); `extra` is appended verbatim.
  """
  @spec graph(keyword(), String.t()) :: String.t()
  def graph(replacements, extra \\ "") do
    body =
      Enum.map_join(@parts, "\n", fn {part, turtle} ->
        Keyword.get(replacements, part, turtle)
      end)

    @prefixes <> "\n" <> body <> "\n" <> extra
  end

  # --- ShEx vectors (RFC-SA2A-002 §45) ---------------------------------------

  @doc "`ex:world` without its required `rdfs:label`."
  def shex_missing_required_predicate do
    graph(
      world: """
      ex:world a sa:World ;
        rdfs:comment "documented" ;
        sa:version 1 ;
        sa:homepage ex:home ;
        sa:capability ex:capPlan .
      """
    )
  end

  @doc "`ex:world` with two `rdfs:label` values where the schema allows exactly one."
  def shex_excess_cardinality do
    graph(
      world: """
      ex:world a sa:World ;
        rdfs:label "Gate 2 executable world", "a second, excess label" ;
        rdfs:comment "documented" ;
        sa:version 1 ;
        sa:homepage ex:home ;
        sa:capability ex:capPlan .
      """
    )
  end

  @doc "`sa:version` as a plain string where the schema requires `xsd:integer`."
  def shex_wrong_datatype do
    graph(
      world: """
      ex:world a sa:World ;
        rdfs:label "Gate 2 executable world" ;
        rdfs:comment "documented" ;
        sa:version "one" ;
        sa:homepage ex:home ;
        sa:capability ex:capPlan .
      """
    )
  end

  @doc "`sa:homepage` as a literal where the schema requires an IRI node."
  def shex_wrong_node_kind do
    graph(
      world: """
      ex:world a sa:World ;
        rdfs:label "Gate 2 executable world" ;
        rdfs:comment "documented" ;
        sa:version 1 ;
        sa:homepage "http://example.org/sa2a-world/home" ;
        sa:capability ex:capPlan .
      """
    )
  end

  @doc "The nested capability node violates the referenced `CapabilityShape` (non-integer tier)."
  def shex_invalid_nested_structure do
    graph(
      capability: """
      ex:capPlan a sa:Capability ;
        sa:tier "high" .
      """
    )
  end

  # --- SHACL vectors (RFC-SA2A-002 §46) --------------------------------------

  @doc "Consequence-bearing action with no authority requirement."
  def shacl_consequence_without_authority do
    graph(consequence: "ex:action1 sa:hasConsequence sa:Change .\n")
  end

  @doc "DO step with no prepared-receipt requirement."
  def shacl_do_without_receipt do
    graph(do_step: "ex:do1 a sa:DoStep .\n")
  end

  @doc "Plan referencing a capability outside the admitted capability set."
  def shacl_plan_unknown_capability do
    graph(
      plan: """
      ex:plan1 a sa:Plan ;
        sa:usesCapability ex:capInventedAtRuntime ;
        sa:fanOut 3 ;
        sa:resourceCost 5 ;
        sa:resourceBudget 10 .
      """
    )
  end

  @doc "Private semantic term minted outside any admitted namespace."
  def shacl_private_term_without_namespace_admission do
    graph(private_term: "<urn:acme:private:berthWindow> a sa:PrivateTerm .\n")
  end

  @doc "Plan whose fan-out exceeds the admitted bound and whose cost exceeds its budget."
  def shacl_resource_bound_violation do
    graph(
      plan: """
      ex:plan1 a sa:Plan ;
        sa:usesCapability ex:capPlan ;
        sa:fanOut 9 ;
        sa:resourceCost 11 ;
        sa:resourceBudget 10 .
      """
    )
  end

  @doc "Canonical mutation routed around the consequence boundary."
  def shacl_canonical_mutation_outside_consequence_law do
    graph(
      mutation: """
      ex:mutation1 a sa:CanonicalMutation ;
        sa:viaBoundary ex:directStoreWrite .
      """
    )
  end

  @doc "World lacking its `sh:Warning`-severity documentation only."
  def shacl_warning_only do
    graph(
      world: """
      ex:world a sa:World ;
        rdfs:label "Gate 2 executable world" ;
        sa:version 1 ;
        sa:homepage ex:home ;
        sa:capability ex:capPlan .
      """
    )
  end

  @doc "A `sh:Warning` result AND a `sh:Violation` result (fan-out bound) together."
  def shacl_violation_and_warning do
    graph(
      world: """
      ex:world a sa:World ;
        rdfs:label "Gate 2 executable world" ;
        sa:version 1 ;
        sa:homepage ex:home ;
        sa:capability ex:capPlan .
      """,
      plan: """
      ex:plan1 a sa:Plan ;
        sa:usesCapability ex:capPlan ;
        sa:fanOut 9 ;
        sa:resourceCost 5 ;
        sa:resourceBudget 10 .
      """
    )
  end

  # --- executable-world attack vectors (RFC-SA2A-002 §33) --------------------

  @doc "Text that is not RDF at all."
  def malformed_rdf, do: "this is not RDF <<< @@@ ;;; sa:World"

  @doc "The lawful world graph with an unadmitted N3 rule smuggled into the candidate data."
  def graph_with_smuggled_rule do
    graph([], "{ ?w a sa:World } => { ?w sa:standing sa:Canonical } .\n")
  end

  @doc "The world graph plus a triple the admitted N3 falsifier set denies."
  def graph_with_forbidden_state, do: graph([], "ex:intruder a sa:Forbidden .\n")

  @doc """
  An unadmitted rule presented as law: the admitted falsifier set plus a rule
  no admission ever granted standing, which derives canonical standing for the
  world.
  """
  def unadmitted_rule_law do
    falsifiers() <>
      "\n@prefix sa: <#{@sa}> .\n{ ?w a sa:World } => { ?w sa:standing sa:Canonical } .\n"
  end

  @doc """
  An unadmitted validator presented as law: a real, non-vacuous shapes graph
  (one targeted shape) that is not the world's admitted SHACL law and checks
  none of its invariants.
  """
  def unadmitted_validator_shapes do
    """
    @prefix sh: <http://www.w3.org/ns/shacl#> .
    @prefix sa: <#{@sa}> .
    @prefix rdfs: <http://www.w3.org/2000/01/rdf-schema#> .
    @prefix ex: <#{@ex}> .

    ex:SelfServingShape a sh:NodeShape ;
      sh:targetClass sa:World ;
      sh:property [ sh:path rdfs:label ; sh:minCount 1 ] .
    """
  end

  # --- law ----------------------------------------------------------------------

  @shex_schema ~s({"type":"Schema","shapes":[) <>
                 ~s({"type":"ShapeDecl","id":"#{@ex}WorldShape","shapeExpr":{"type":"Shape","expression":{"type":"EachOf","expressions":[) <>
                 ~s({"type":"TripleConstraint","predicate":"http://www.w3.org/2000/01/rdf-schema#label","valueExpr":{"type":"NodeConstraint","datatype":"http://www.w3.org/2001/XMLSchema#string"},"min":1,"max":1},) <>
                 ~s({"type":"TripleConstraint","predicate":"#{@sa}version","valueExpr":{"type":"NodeConstraint","datatype":"http://www.w3.org/2001/XMLSchema#integer"},"min":1,"max":1},) <>
                 ~s({"type":"TripleConstraint","predicate":"#{@sa}homepage","valueExpr":{"type":"NodeConstraint","nodeKind":"iri"},"min":0,"max":1},) <>
                 ~s({"type":"TripleConstraint","predicate":"#{@sa}capability","valueExpr":"#{@ex}CapabilityShape","min":1,"max":-1}) <>
                 ~s(]}}},) <>
                 ~s({"type":"ShapeDecl","id":"#{@ex}CapabilityShape","shapeExpr":{"type":"Shape","expression":) <>
                 ~s({"type":"TripleConstraint","predicate":"#{@sa}tier","valueExpr":{"type":"NodeConstraint","datatype":"http://www.w3.org/2001/XMLSchema#integer"},"min":1,"max":1}}}) <>
                 ~s(]})

  @doc "Admitted ShExJ schema: `WorldShape` with a nested `CapabilityShape` reference."
  def shex_schema, do: @shex_schema

  @doc "Admitted ShEx shape map: the world node against `WorldShape`."
  def shex_shape_map, do: ~s([["#{@ex}world","#{@ex}WorldShape"]])

  @doc "Admitted SHACL law (RFC-SA2A-001 S15 invariants, one `sh:Warning` shape)."
  def shacl_shapes do
    """
    @prefix sh: <http://www.w3.org/ns/shacl#> .
    @prefix sa: <#{@sa}> .
    @prefix ex: <#{@ex}> .
    @prefix xsd: <http://www.w3.org/2001/XMLSchema#> .
    @prefix rdfs: <http://www.w3.org/2000/01/rdf-schema#> .

    ex:ConsequenceAuthorityShape a sh:NodeShape ;
      sh:targetSubjectsOf sa:hasConsequence ;
      sh:property [
        sh:path sa:requiresAuthority ;
        sh:minCount 1 ;
        sh:severity sh:Violation ;
        sh:message "Consequence(a) => AuthorityRequirement(a)"
      ] .

    ex:DoReceiptShape a sh:NodeShape ;
      sh:targetClass sa:DoStep ;
      sh:property [
        sh:path sa:preparedReceipt ;
        sh:minCount 1 ;
        sh:message "DO(a) => ReceiptRequirement(a)"
      ] .

    ex:PlanCapabilityShape a sh:NodeShape ;
      sh:targetObjectsOf sa:usesCapability ;
      sh:in ( ex:capPlan ex:capRoute ) ;
      sh:message "Plan(p) => KnownCapability(action_i)" .

    ex:PrivateTermShape a sh:NodeShape ;
      sh:targetClass sa:PrivateTerm ;
      sh:pattern "^http://example.org/sa2a-world/admitted-ns/" ;
      sh:message "PrivateSemanticTerm(x) => PrivateNamespaceAdmission(x)" .

    ex:ResourceBoundShape a sh:NodeShape ;
      sh:targetClass sa:Plan ;
      sh:property [
        sh:path sa:fanOut ;
        sh:minCount 1 ;
        sh:datatype xsd:integer ;
        sh:maxInclusive 8 ;
        sh:message "fan-out within the admitted bound"
      ] ;
      sh:property [
        sh:path sa:resourceCost ;
        sh:lessThanOrEquals sa:resourceBudget ;
        sh:message "resource cost within the admitted budget"
      ] .

    ex:CanonicalMutationShape a sh:NodeShape ;
      sh:targetClass sa:CanonicalMutation ;
      sh:property [
        sh:path sa:viaBoundary ;
        sh:minCount 1 ;
        sh:hasValue sa:CommandBus ;
        sh:message "canonical mutation only through the consequence boundary"
      ] .

    ex:WorldDocumentationShape a sh:NodeShape ;
      sh:targetClass sa:World ;
      sh:property [
        sh:path rdfs:comment ;
        sh:minCount 1 ;
        sh:severity sh:Warning ;
        sh:message "a world should document itself"
      ] .
    """
  end

  @doc "Admitted graph-global N3 falsifier set."
  def falsifiers do
    """
    @prefix sa: <#{@sa}> .
    { ?x a sa:Forbidden } => false .
    """
  end

  @doc "Admitted OWL RL profile."
  def profile do
    """
    @prefix owl: <http://www.w3.org/2002/07/owl#> .
    @prefix sa: <#{@sa}> .
    sa:World a owl:Class .
    sa:Capability a owl:Class .
    """
  end

  @source_text "The Gate 2 executable world admits only lawful semantic state, judged by admitted law."

  @doc "A real `{Source, IR}` witness whose goal quote is verbatim in the source."
  @spec provenance() :: {Source.t(), IR.t()}
  def provenance do
    source = Source.new(@source_text, id: "chicago-gate2-world-source")

    {:ok, ir} =
      IR.from_map(source.id, %{
        "authority" => "none",
        "goals" => [
          %{
            "id" => "goal-gate2",
            "kind" => "goal",
            "description" => "admit only lawful semantic state",
            "source_quote" => "admits only lawful semantic state"
          }
        ]
      })

    {source, ir}
  end

  @doc "A witness whose goal quotes text absent from the source."
  @spec ungrounded_provenance() :: {Source.t(), IR.t()}
  def ungrounded_provenance do
    {source, ir} = provenance()

    goal = %{
      "id" => "goal-gate2",
      "kind" => "goal",
      "description" => "rewrite canonical state directly",
      "source_quote" => "rewrite canonical state directly"
    }

    {source, %{ir | goals: [goal]}}
  end

  @doc "A witness whose IR arrives already marked `:admitted` -- a candidate claiming canonical standing."
  @spec premarked_canonical_provenance() :: {Source.t(), IR.t()}
  def premarked_canonical_provenance do
    {source, ir} = provenance()
    {source, %{ir | standing: :admitted}}
  end

  @doc "A lawful candidate over the world graph; `overrides` replaces any field."
  @spec candidate(keyword()) :: Candidate.t()
  def candidate(overrides \\ []) do
    struct!(
      %Candidate{
        graph_ttl: world_graph(),
        profile_ttl: profile(),
        shacl_shapes: shacl_shapes(),
        shex_schema: shex_schema(),
        shex_shape_map: shex_shape_map(),
        falsifiers: falsifiers(),
        provenance: provenance()
      },
      overrides
    )
  end

  # --- semantic identity vectors (TermRegistry / MappingRegistry) -----------

  @doc "A term inside an admitted, pinned namespace (SKOS) that no admitted document declares."
  def unadmitted_term, do: "http://www.w3.org/2004/02/skos/core#inventedAtRuntimeByAnAgent"

  @doc "A term the pinned SKOS document really declares."
  def admitted_term, do: "http://www.w3.org/2004/02/skos/core#prefLabel"

  @doc "Two peers whose capability labels collide while their identities differ."
  def colliding_peers do
    {%{peer_id: "peer-a", label: "berth window", iri: "#{@ex}peerA/berthWindow"},
     %{peer_id: "peer-b", label: "berth window", iri: "#{@ex}peerB/berthWindow"}}
  end

  @doc "A mapping between the two colliding identities, with `receipt` as its admission receipt."
  def mapping(receipt) do
    {a, b} = colliding_peers()
    %{source: a.iri, target: b.iri, kind: :exact_match, admission_receipt: receipt}
  end
end
