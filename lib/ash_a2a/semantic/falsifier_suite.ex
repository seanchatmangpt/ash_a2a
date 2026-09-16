defmodule AshA2A.Semantic.FalsifierSuite do
  @moduledoc """
  RFC-SA2A-001 v26.9.16 S18/S57/S61 minimum falsifier suite.

  ## What a falsifier is

  RFC S18.2: a graph-global falsifier is an `ASK` query over the semantic
  envelope. A `true` result from a *mandatory* falsifier MUST block
  admission. S61 enumerates the fourteen a Strict deployment must test for;
  all fourteen are defined here, each with:

    * `:ask` -- the **normative** SPARQL 1.1 `ASK` text. This is the
      specification of the falsifier, not documentation of it.
    * `:evaluation` -- how this build actually evaluates it at runtime
      (`:structural`, see the next section for exactly why).
    * `:backing` -- the real `AshA2A` module whose invariant this falsifier
      guards, or `:none` when the guarded machinery does not exist yet.

  ## Why the runtime evaluator is structural and not SPARQL

  The intended executor is Praxis GraphLaw, which has a real SPARQL 1.1
  engine (`praxis-graphlaw/src/sparql.rs`) and a real in-graph SPARQL hook
  condition (`kh:kind "sparql"` with `kh:query`, parsed through
  `spargebra::Query::parse`, evaluated via `TripleStore::query/1`). Elixir
  does not and must not own a SPARQL engine.

  That path is **not reachable from the currently prebuilt wasm**. Measured,
  not assumed -- `praxis_graphlaw_wasm_bg.wasm` (3,249,361 bytes) exports
  exactly `blake3_hex`, `graph_hash`, `graphlaw_version`, `init_panic_hook`,
  `run_hooks`, `validate_all`. There is no query export, so the only
  candidate carrier is `run_hooks/2`, and it does not carry hooks at all in
  that artifact: driving it with `kh:kind "sparql"`, `"count"`, `"delta"`,
  and the `hook:` alias namespace all returned
  `{"status":"ADMITTED","verdicts":[],"receipts":[],"schedule":[]}` --
  identical empty verdicts for every kind, positive and negative fixture
  alike. Root cause: that artifact reports `praxis-graphlaw v26.7.5`, whose
  `run_hooks_core_impl` builds its store with `TripleStore::from/1`; hook
  extraction at the time lived only in `TripleStore::load_triples/2`, so
  `post_store.hooks` is always empty and `evaluate_hooks/4` has nothing to
  evaluate. (The v26.7.9 *source* of `TripleStore::from/1` does compile
  hooks, via `validate_and_extract_hooks |> compile_hooks |>
  unwrap_or_default` -- but the shipped wasm predates that.)

  Additionally `ash_a2a` has no `wasmex` dependency, so no Elixir process in
  this build can reach that wasm at all.

  ### Exactly what would be needed to evaluate these in real SPARQL

  Either of:

    1. A new wasm export `sparql_ask(ttl: &str, query: &str) -> String`
       returning `{"ask": true|false}` / `{"error": "..."}`, wrapping
       `TripleStore::from(ttl).query(query)` with a boolean projection --
       `TripleStore::query/1` returns `Vec<Vec<Binding>>`, so an `ASK` must
       be reduced to `!results.is_empty()`, exactly as
       `hooks/condition.rs`'s `HookCondition::Sparql` arm already does; or
    2. A rebuild of `praxis-graphlaw-wasm` from >= v26.7.9 so `run_hooks/2`
       actually compiles in-graph `kh:kind "sparql"` hooks, plus a `wasmex`
       dependency here to call it.

  Neither is done in this change: (1) is a Praxis-side export and (2) would
  overwrite a shared build artifact other concurrent work has already
  measured byte-for-byte.

  So each falsifier below carries its normative `ASK` *and* a real
  structural evaluator over the same graph. The two are held to agreement by
  `test/ash_a2a/semantic/falsifier_sparql_oracle_test.exs`, which executes
  the `ASK` text against every fixture using a real, independent SPARQL 1.1
  engine and asserts the boolean matches `evaluate/2`. The structural
  evaluator is therefore checked against a real SPARQL implementation of the
  normative query, not merely asserted to correspond to it.

  ## Graph representation

  A graph is a list of `{subject, predicate, object}` tuples.

    * `subject` and `predicate` are IRI binaries.
    * `object` is an IRI binary, `{:lit, binary}`, or `{:int, integer}`.

  Graphs are RDF sets: `run/1`, `evaluate/2` and `to_ntriples/1` deduplicate
  on entry so multiplicity can never change a verdict (this matters for the
  aggregating falsifiers F07/F08, where a duplicated triple would otherwise
  inflate a `COUNT`/`SUM`).

  ## Scope

  Closing a falsifier here means: *this check discriminates this condition on
  the semantic graph, shown by a positive fixture that trips it and a
  negative fixture that does not*. It does not claim the guarded runtime
  machinery is wired end to end. The `:backing` field is the honest
  per-falsifier statement of that: a module name where the invariant has a
  real owner in this repo, `:none` where it does not.
  """

  alias AshA2A.Semantic.Falsifier
  alias AshA2A.Semantic.Vocabulary

  @sa "http://seanchatmangpt.github.io/sa2a#"
  @prov "http://www.w3.org/ns/prov#"
  @xsd_integer "http://www.w3.org/2001/XMLSchema#integer"
  @rdf_type "http://www.w3.org/1999/02/22-rdf-syntax-ns#type"

  @prologue """
  PREFIX sa: <#{@sa}>
  PREFIX prov: <#{@prov}>
  PREFIX rdf: <http://www.w3.org/1999/02/22-rdf-syntax-ns#>
  """

  @doc "The SA2A falsifier namespace IRI."
  def namespace, do: @sa

  @doc "Expand an `sa:` local name to a full IRI."
  def sa(local) when is_binary(local), do: @sa <> local

  @doc "Expand a `prov:` local name to a full IRI."
  def prov(local) when is_binary(local), do: @prov <> local

  @doc "The `rdf:type` IRI, taken from the existing prefix registry."
  def rdf_type, do: Vocabulary.expand("rdf:type")

  @doc "Shared SPARQL prologue used by every normative ASK in this suite."
  def prologue, do: @prologue

  # ==========================================================================
  # The fourteen (RFC S61), in RFC order.
  # ==========================================================================

  @falsifiers [
    %Falsifier{
      id: :consequence_without_authority_requirement,
      rfc: "S61.1",
      title: "consequence without authority requirement",
      mandatory: true,
      evaluation: :structural,
      backing: AshA2A.Authority,
      ask: """
      ASK {
        ?c sa:hasConsequence ?x .
        FILTER NOT EXISTS { ?c sa:requiresAuthority ?a }
      }
      """
    },
    %Falsifier{
      id: :do_without_prepared_receipt,
      rfc: "S61.2",
      title: "DO without prepared-receipt requirement",
      mandatory: true,
      evaluation: :structural,
      backing: AshA2A.ReceiptOutbox,
      ask: """
      ASK {
        ?d rdf:type sa:DoStep .
        FILTER NOT EXISTS { ?d sa:preparedReceipt ?r }
      }
      """
    },
    %Falsifier{
      id: :unknown_capability_referenced_by_plan,
      rfc: "S61.3",
      title: "unknown capability referenced by plan",
      mandatory: true,
      evaluation: :structural,
      backing: AshA2A.CapabilityIndex,
      ask: """
      ASK {
        ?s sa:usesCapability ?c .
        FILTER NOT EXISTS { ?c rdf:type sa:AdmittedCapability }
      }
      """
    },
    %Falsifier{
      id: :unadmitted_ontology_term,
      rfc: "S61.4",
      title: "unadmitted ontology term",
      mandatory: true,
      evaluation: :structural,
      backing: AshA2A.Semantic.Vocabulary,
      ask: """
      ASK {
        ?s sa:usesTerm ?t .
        FILTER NOT EXISTS { ?t rdf:type sa:AdmittedTerm }
      }
      """
    },
    %Falsifier{
      id: :unadmitted_rule,
      rfc: "S61.5",
      title: "unadmitted rule",
      mandatory: true,
      evaluation: :structural,
      backing: :none,
      ask: """
      ASK {
        ?s sa:appliesRule ?r .
        FILTER NOT EXISTS { ?r rdf:type sa:AdmittedRule }
      }
      """
    },
    %Falsifier{
      id: :unadmitted_validator,
      rfc: "S61.6",
      title: "unadmitted validator",
      mandatory: true,
      evaluation: :structural,
      backing: :none,
      ask: """
      ASK {
        ?s sa:validatedBy ?v .
        FILTER NOT EXISTS { ?v rdf:type sa:AdmittedValidator }
      }
      """
    },
    %Falsifier{
      id: :plan_exceeds_fanout_bound,
      rfc: "S61.7",
      title: "plan exceeding fan-out bound",
      mandatory: true,
      evaluation: :structural,
      backing: AshA2A.Planning.HddlSolver,
      ask: """
      ASK {
        ?p sa:fanOutBound ?b .
        {
          SELECT ?p (COUNT(?c) AS ?n) WHERE { ?p sa:hasSubStep ?c } GROUP BY ?p
        }
        FILTER (?n > ?b)
      }
      """
    },
    %Falsifier{
      id: :plan_exceeds_resource_envelope,
      rfc: "S61.8",
      title: "plan exceeding resource envelope",
      mandatory: true,
      evaluation: :structural,
      backing: :none,
      ask: """
      ASK {
        ?p sa:resourceBudget ?b .
        {
          SELECT ?p (SUM(?c) AS ?t) WHERE {
            ?p sa:hasSubStep ?s .
            ?s sa:resourceCost ?c .
          } GROUP BY ?p
        }
        FILTER (?t > ?b)
      }
      """
    },
    %Falsifier{
      id: :artifact_lacking_provenance,
      rfc: "S61.9",
      title: "semantic artifact lacking provenance",
      mandatory: true,
      evaluation: :structural,
      backing: AshA2A.Semantic.Ontology,
      ask: """
      ASK {
        ?a rdf:type sa:SemanticArtifact .
        FILTER NOT EXISTS { ?a prov:wasDerivedFrom ?x }
      }
      """
    },
    %Falsifier{
      id: :artifact_lacking_canonical_identity,
      rfc: "S61.10",
      title: "semantic artifact lacking canonical identity",
      mandatory: true,
      evaluation: :structural,
      backing: AshA2A.SemanticSubject,
      ask: """
      ASK {
        ?a rdf:type sa:SemanticArtifact .
        FILTER NOT EXISTS { ?a sa:canonicalDigest ?d }
      }
      """
    },
    %Falsifier{
      id: :projection_claiming_canonical_source,
      rfc: "S61.11",
      title: "projection attempting to become canonical source",
      mandatory: true,
      evaluation: :structural,
      backing: AshA2A.SemanticSubject,
      ask: """
      ASK {
        ?p sa:projectionOf ?x .
        ?p rdf:type sa:CanonicalSource .
      }
      """
    },
    %Falsifier{
      id: :authority_from_agent_identity_alone,
      rfc: "S61.12",
      title: "authority derived from agent identity alone",
      mandatory: true,
      evaluation: :structural,
      backing: AshA2A.Authority.Broker,
      ask: """
      ASK {
        ?a rdf:type sa:AuthorityGrant .
        ?a sa:derivedFrom ?i .
        ?i rdf:type sa:AgentIdentity .
        FILTER NOT EXISTS {
          ?a sa:derivedFrom ?o .
          ?o rdf:type sa:AuthorityBrokerDecision .
        }
      }
      """
    },
    %Falsifier{
      id: :llm_output_directly_admitted,
      rfc: "S61.13",
      title: "LLM output marked directly as ADMITTED",
      mandatory: true,
      evaluation: :structural,
      backing: AshA2A.Semantic.Admission,
      ask: """
      ASK {
        ?o sa:producedBy ?g .
        ?g rdf:type sa:LlmActivity .
        ?o sa:standing "ADMITTED" .
      }
      """
    },
    %Falsifier{
      id: :canonical_mutation_outside_brce,
      rfc: "S61.14",
      title: "canonical mutation outside BRCE",
      mandatory: true,
      evaluation: :structural,
      backing: AshA2A.CommandBus,
      ask: """
      ASK {
        ?m rdf:type sa:CanonicalMutation .
        FILTER NOT EXISTS { ?m sa:viaCommandBus ?b }
      }
      """
    }
  ]

  @ids Enum.map(@falsifiers, & &1.id)

  @doc "All fourteen falsifiers, in RFC S61 order."
  @spec falsifiers() :: [Falsifier.t()]
  def falsifiers, do: @falsifiers

  @doc "All fourteen falsifier ids, in RFC S61 order."
  @spec ids() :: [atom()]
  def ids, do: @ids

  @doc "Fetch one falsifier by id."
  @spec falsifier(atom()) :: {:ok, Falsifier.t()} | {:error, map()}
  def falsifier(id) do
    case Enum.find(@falsifiers, &(&1.id == id)) do
      nil -> {:error, %{code: :unknown_falsifier, detail: id}}
      found -> {:ok, found}
    end
  end

  @doc """
  The normative SPARQL 1.1 `ASK` text for `id`, with the shared prologue.

  This is the specification of the falsifier. `evaluate/2` is held to agree
  with a real SPARQL engine's answer to exactly this string.
  """
  @spec ask(atom()) :: {:ok, binary()} | {:error, map()}
  def ask(id) do
    with {:ok, f} <- falsifier(id), do: {:ok, @prologue <> "\n" <> f.ask}
  end

  @doc """
  Falsifiers whose guarded machinery has a real owner in this repo.

  The complement, `deferred/0`, is the honest DEFERRED list: the graph check
  discriminates, but nothing in `ash_a2a` yet implements the thing it guards.
  """
  @spec closed() :: [Falsifier.t()]
  def closed, do: Enum.reject(@falsifiers, &(&1.backing == :none))

  @doc "Falsifiers with no backing machinery in this repo yet (DEFERRED)."
  @spec deferred() :: [Falsifier.t()]
  def deferred, do: Enum.filter(@falsifiers, &(&1.backing == :none))

  @doc """
  Machine-readable status of the suite: every falsifier with its RFC section,
  evaluation mode, backing module and closed/deferred standing.
  """
  @spec report() :: [map()]
  def report do
    Enum.map(@falsifiers, fn f ->
      %{
        id: f.id,
        rfc: f.rfc,
        title: f.title,
        mandatory: f.mandatory,
        evaluation: f.evaluation,
        backing: f.backing,
        standing: if(f.backing == :none, do: :deferred, else: :closed)
      }
    end)
  end

  # ==========================================================================
  # Evaluation
  # ==========================================================================

  @doc """
  Evaluate one falsifier against `graph`.

  Returns `true` when the falsifier **trips** -- i.e. the violating condition
  is present, which is what the normative `ASK` returns `true` for.
  """
  @spec evaluate([tuple()], atom()) :: {:ok, boolean()} | {:error, map()}
  def evaluate(graph, id) when is_list(graph) do
    if id in @ids do
      {:ok, trips?(id, Enum.uniq(graph))}
    else
      {:error, %{code: :unknown_falsifier, detail: id}}
    end
  end

  @doc """
  Run every mandatory falsifier against `graph`.

  Returns `%{tripped: [id], clear: [id]}`, both in RFC S61 order.
  """
  @spec run([tuple()]) :: %{tripped: [atom()], clear: [atom()]}
  def run(graph) when is_list(graph) do
    g = Enum.uniq(graph)
    {tripped, clear} = Enum.split_with(@ids, &trips?(&1, g))
    %{tripped: tripped, clear: clear}
  end

  @doc """
  RFC S18.2 admission gate: a `true` mandatory falsifier MUST block admission.

  Returns `:ok`, or `{:error, %{code: :refused_falsifier, detail: ...}}` whose
  detail names every falsifier that tripped (`:falsifier` is the first in RFC
  order, `:falsifiers` is the full list) so the refusal says *which one*.
  """
  @spec admit([tuple()]) :: :ok | {:error, map()}
  def admit(graph) when is_list(graph) do
    case run(graph) do
      %{tripped: []} ->
        :ok

      %{tripped: [first | _] = all} ->
        {:error,
         %{
           code: :refused_falsifier,
           detail: %{
             falsifier: first,
             falsifiers: all,
             rfc:
               Enum.map(all, fn id ->
                 {:ok, f} = falsifier(id)
                 f.rfc
               end)
           }
         }}
    end
  end

  # -- the fourteen structural evaluators, each mirroring its normative ASK --

  defp trips?(:consequence_without_authority_requirement, g) do
    g
    |> subjects_with(sa("hasConsequence"))
    |> Enum.any?(&(not has?(g, &1, sa("requiresAuthority"))))
  end

  defp trips?(:do_without_prepared_receipt, g) do
    g |> typed(sa("DoStep")) |> Enum.any?(&(not has?(g, &1, sa("preparedReceipt"))))
  end

  defp trips?(:unknown_capability_referenced_by_plan, g) do
    g
    |> objects_of(sa("usesCapability"))
    |> Enum.any?(&(not type?(g, &1, sa("AdmittedCapability"))))
  end

  defp trips?(:unadmitted_ontology_term, g) do
    g |> objects_of(sa("usesTerm")) |> Enum.any?(&(not type?(g, &1, sa("AdmittedTerm"))))
  end

  defp trips?(:unadmitted_rule, g) do
    g |> objects_of(sa("appliesRule")) |> Enum.any?(&(not type?(g, &1, sa("AdmittedRule"))))
  end

  defp trips?(:unadmitted_validator, g) do
    g |> objects_of(sa("validatedBy")) |> Enum.any?(&(not type?(g, &1, sa("AdmittedValidator"))))
  end

  defp trips?(:plan_exceeds_fanout_bound, g) do
    # Mirrors the ASK's subquery: only plans that HAVE at least one sub-step
    # produce a COUNT row, and the outer join requires a declared bound.
    Enum.any?(int_pairs(g, sa("fanOutBound")), fn {plan, bound} ->
      case g |> objects(plan, sa("hasSubStep")) |> length() do
        0 -> false
        n -> n > bound
      end
    end)
  end

  defp trips?(:plan_exceeds_resource_envelope, g) do
    Enum.any?(int_pairs(g, sa("resourceBudget")), fn {plan, budget} ->
      costs =
        g
        |> objects(plan, sa("hasSubStep"))
        |> Enum.flat_map(fn step -> int_objects(g, step, sa("resourceCost")) end)

      # SPARQL: an empty group yields no row at all, so no FILTER match.
      costs != [] and Enum.sum(costs) > budget
    end)
  end

  defp trips?(:artifact_lacking_provenance, g) do
    g |> typed(sa("SemanticArtifact")) |> Enum.any?(&(not has?(g, &1, prov("wasDerivedFrom"))))
  end

  defp trips?(:artifact_lacking_canonical_identity, g) do
    g |> typed(sa("SemanticArtifact")) |> Enum.any?(&(not has?(g, &1, sa("canonicalDigest"))))
  end

  defp trips?(:projection_claiming_canonical_source, g) do
    g |> subjects_with(sa("projectionOf")) |> Enum.any?(&type?(g, &1, sa("CanonicalSource")))
  end

  defp trips?(:authority_from_agent_identity_alone, g) do
    Enum.any?(typed(g, sa("AuthorityGrant")), fn grant ->
      sources = objects(g, grant, sa("derivedFrom"))

      Enum.any?(sources, &type?(g, &1, sa("AgentIdentity"))) and
        not Enum.any?(sources, &type?(g, &1, sa("AuthorityBrokerDecision")))
    end)
  end

  defp trips?(:llm_output_directly_admitted, g) do
    g
    |> subjects_with(sa("producedBy"))
    |> Enum.any?(fn out ->
      Enum.any?(objects(g, out, sa("producedBy")), &type?(g, &1, sa("LlmActivity"))) and
        {:lit, "ADMITTED"} in objects(g, out, sa("standing"))
    end)
  end

  defp trips?(:canonical_mutation_outside_brce, g) do
    g |> typed(sa("CanonicalMutation")) |> Enum.any?(&(not has?(g, &1, sa("viaCommandBus"))))
  end

  # ==========================================================================
  # RFC S18.3 -- a CONSTRUCT projection does NOT automatically acquire standing
  # ==========================================================================

  @doc """
  RFC S18.3: standing of `node` in `graph`.

  A `sa:projectionOf` edge confers **no** standing on its own. Standing is
  `:admitted` only when the graph carries an explicit `sa:grantedStanding
  "ADMITTED"` for that node; being a projection of an admitted canonical
  graph never propagates. Anything else is `:none`.

  This is the S18.3 invariant stated as a function so it can be tested
  directly rather than only inferred from F11 not tripping.
  """
  @spec projection_standing([tuple()], binary()) :: :admitted | :none
  def projection_standing(graph, node) when is_list(graph) and is_binary(node) do
    g = Enum.uniq(graph)

    if {:lit, "ADMITTED"} in objects(g, node, sa("grantedStanding")) do
      :admitted
    else
      :none
    end
  end

  # ==========================================================================
  # RFC S18.4 -- direct SPARQL Update against canonical admitted state
  # ==========================================================================

  # SPARQL 1.1 Update operations that mutate graph state (Update, §3.1/§3.2).
  # Longest-first so DELETE WHERE / DELETE DATA are recognised before DELETE.
  @mutating_forms [
    "INSERT DATA",
    "DELETE DATA",
    "DELETE WHERE",
    "INSERT",
    "DELETE",
    "LOAD",
    "CLEAR",
    "DROP",
    "CREATE",
    "ADD",
    "MOVE",
    "COPY"
  ]

  @doc """
  RFC S18.4: direct SPARQL Update against canonical admitted state is
  PROHIBITED in Strict.

  `graph` classifies target graph IRIs: an IRI typed `sa:CanonicalGraph` is
  canonical, one typed `sa:StagingGraph` is staging. `update` is the SPARQL
  Update text.

  Returns `:ok` when the update is non-mutating, or mutating but targets only
  staging graphs. Returns
  `{:error, %{code: :refused_sparql_update_on_canonical, ...}}` otherwise.

  Strict default: a mutating update that names **no** graph targets the
  default graph, which in Strict *is* canonical consequential state, so it is
  refused. An update naming an IRI the graph does not classify is also
  refused -- unclassified is not staging.

  ## Honest limitation

  This extracts the operation form and the `GRAPH`/`WITH`/`INTO`/`FROM` IRIs
  by pattern match over the update text. It is **not** a SPARQL Update
  parser, and Elixir must not grow one. A real implementation routes the text
  through `spargebra::Update::parse` behind a wasm export (see this module's
  moduledoc); until such an export exists this check is deliberately
  conservative -- it refuses on ambiguity rather than admitting on it.
  """
  @spec check_update([tuple()], binary()) :: :ok | {:error, map()}
  def check_update(graph, update) when is_list(graph) and is_binary(update) do
    g = Enum.uniq(graph)
    form = mutating_form(update)

    cond do
      is_nil(form) ->
        :ok

      true ->
        targets = update_targets(update)
        classify_targets(g, form, targets)
    end
  end

  defp classify_targets(_g, form, []) do
    {:error,
     %{
       code: :refused_sparql_update_on_canonical,
       detail: %{
         rfc: "S18.4",
         form: form,
         target: :default_graph,
         reason:
           "mutating SPARQL Update names no graph; the default graph is canonical consequential state in Strict"
       }
     }}
  end

  defp classify_targets(g, form, targets) do
    offending =
      Enum.reject(targets, fn iri -> type?(g, iri, sa("StagingGraph")) end)

    case offending do
      [] ->
        :ok

      [first | _] ->
        {:error,
         %{
           code: :refused_sparql_update_on_canonical,
           detail: %{
             rfc: "S18.4",
             form: form,
             target: first,
             targets: offending,
             reason:
               if(type?(g, first, sa("CanonicalGraph")),
                 do: "mutating SPARQL Update targets a canonical graph",
                 else: "mutating SPARQL Update targets a graph not classified as sa:StagingGraph"
               )
           }
         }}
    end
  end

  defp mutating_form(update) do
    upcased = String.upcase(update)
    Enum.find(@mutating_forms, fn form -> String.contains?(upcased, form) end)
  end

  @graph_target_regex ~r/\b(?:GRAPH|WITH|INTO\s+GRAPH|FROM\s+GRAPH|INTO|FROM|TO)\s+<([^>]+)>/i

  defp update_targets(update) do
    @graph_target_regex
    |> Regex.scan(update)
    |> Enum.map(fn [_full, iri] -> iri end)
    |> Enum.uniq()
  end

  # ==========================================================================
  # N-Triples serialization (for handing a fixture to a real SPARQL engine)
  # ==========================================================================

  @doc """
  Serialize `graph` to canonical N-Triples.

  Deduplicated and sorted, so the same graph always produces byte-identical
  output regardless of the order triples were built in. This is what feeds a
  real SPARQL engine in the oracle test; it is deliberately N-Triples (no
  prefixes, no abbreviation) so nothing about the serializer can change the
  parsed graph.

  This is **not** a canonicalization in the RDFC-1.0 sense and must not be
  used as one -- it has no blank-node handling at all, because this suite's
  graphs are ground. RFC S12 canonical graph identity is GraphLaw's
  `graph_hash` (oxrdf `rdfc-10`), not this.
  """
  @spec to_ntriples([tuple()]) :: binary()
  def to_ntriples(graph) when is_list(graph) do
    graph
    |> Enum.uniq()
    |> Enum.map(fn {s, p, o} -> "<#{s}> <#{p}> #{term(o)} ." end)
    |> Enum.sort()
    |> Enum.join("\n")
    |> Kernel.<>("\n")
  end

  defp term({:lit, value}), do: "\"#{escape(value)}\""
  defp term({:int, value}), do: "\"#{value}\"^^<#{@xsd_integer}>"
  defp term(iri) when is_binary(iri), do: "<#{iri}>"

  defp escape(value) do
    value
    |> String.replace("\\", "\\\\")
    |> String.replace("\"", "\\\"")
    |> String.replace("\n", "\\n")
    |> String.replace("\r", "\\r")
    |> String.replace("\t", "\\t")
  end

  # ==========================================================================
  # Graph helpers
  # ==========================================================================

  defp objects(g, s, p), do: for({^s, ^p, o} <- g, do: o)

  defp subjects_with(g, p), do: for({s, ^p, _} <- g, do: s) |> Enum.uniq()

  defp objects_of(g, p), do: for({_, ^p, o} <- g, do: o) |> Enum.uniq()

  defp typed(g, class), do: for({s, @rdf_type, ^class} <- g, do: s) |> Enum.uniq()

  defp has?(g, s, p), do: Enum.any?(g, fn {a, b, _} -> a == s and b == p end)

  defp type?(g, node, class), do: Enum.any?(g, fn t -> t == {node, @rdf_type, class} end)

  defp int_objects(g, s, p), do: for({^s, ^p, {:int, n}} <- g, do: n)

  defp int_pairs(g, p), do: for({s, ^p, {:int, n}} <- g, do: {s, n}) |> Enum.uniq()
end
