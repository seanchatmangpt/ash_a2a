# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshA2A.Semantic.Conformance do
  @moduledoc """
  Real, executable RFC-SA2A-001 v26.9.16 conformance checks: the profile
  requirement checks (S59, declared in `AshA2A.Semantic.Profile`), the
  invariants (S60), and the twelve explanation questions (S78).

  Every function in this module calls this repo's real, current, unmodified
  code -- `AshA2A.Semantic.{Source, IR, Admission, Ontology, PlanningIR,
  Vocabulary}`, `AshA2A.{Command, CommandBus, Authority, Receipt,
  ReceiptOutbox, SemanticSubject, Info}`, the real compiled
  `AshA2A.ArchitectureVerifier.Fixture.Resource`, and (for the static DO-path
  check) the real compiled BEAM abstract code of `AshA2A.CommandBus` and its
  neighbours. Nothing here is a mock, a stub, or a hand-asserted description
  of expected behavior. Like `AshA2A.ArchitectureVerifier`, this module never
  prints and never halts -- that I/O belongs to
  `Mix.Tasks.AshA2a.VerifyConformance` alone, so every function here stays
  directly callable and directly assertable from a test.

  ## The honesty rule this module is built around

  A check that cannot genuinely establish its requirement returns
  `{:unverifiable, detail}` with a real reason -- never `:met`. A vacuously
  passing check is worse than an absent one: it manufactures confidence the
  system has not earned, and every downstream claim built on it inherits the
  lie. Several checks below therefore return `{:unmet, _}` or
  `{:unverifiable, _}` naming exactly which hop is missing, and one invariant
  (`:private_term_admission`) returns `:violated` carrying a real, executed
  falsifier rather than a description of one.

  ## Where the missing validation machinery is expected to come from

  ShEx, SHACL, SPARQL, Datalog and N3 closure are deliberately NOT
  implemented in Elixir here, and the checks for them do not pretend
  otherwise. (RFC S12 RDFC-1.0 canonical graph identity is also not
  implemented here: `AshA2A.Semantic.CanonicalGraph` takes it from the RDF.ex
  dependency; see `check_canonical_graph_identity/0` for what that check does
  and does not cover.) They are expected to be provided by an external engine
  module configured as:

      config :ash_a2a, semantic_engine: MyApp.GraphLawEngine

  `engine_capability/2` below checks that configuration for real -- it reads
  the real application environment, resolves the real module, and asks
  `function_exported?/3` for the real function. When the engine is absent the
  check reports which exact function was missing, so wiring one in flips the
  requirement to `:met` with no change to this module.

  ## See also

    * `AshA2A.Semantic.Profile` -- the five profiles and their requirement lists.
    * `Mix.Tasks.AshA2a.VerifyConformance` -- the CI-runnable gate.
  """

  alias AshA2A.ArchitectureVerifier.Fixture.Resource
  alias AshA2A.Semantic.{Admission, IR, Ontology, PlanningIR, Profile, Source, Vocabulary}
  alias AshA2A.{Authority, Command, CommandBus, Identity, Info, Receipt, ReceiptOutbox}
  alias AshA2A.SemanticSubject

  @typedoc "Outcome of one real profile-requirement check."
  @type requirement_status ::
          :met | {:met, String.t()} | {:unmet, String.t()} | {:unverifiable, String.t()}

  @typedoc "One requirement result, as reported by `requirement_results/0`."
  @type requirement_result :: %{
          id: atom(),
          level: Profile.level(),
          title: String.t(),
          rfc_section: String.t(),
          status: :met | :unmet | :unverifiable,
          detail: String.t()
        }

  @typedoc """
  How strongly an invariant result was established.

    * `:witnessed` -- a real, finite, adversarial case was constructed and
      executed and the invariant held for it. This is NOT a universal proof:
      it establishes the gate exists and fires, not that no path avoids it.
    * `:structural` -- established by real static analysis over compiled code
      (BEAM abstract code), which quantifies over every call site in the
      scanned modules rather than over one executed case.
    * `:none` -- nothing was established; only ever paired with
      `:unverifiable`.
  """
  @type invariant_scope :: :witnessed | :structural | :none

  @typedoc "One RFC S60 invariant result."
  @type invariant_result :: %{
          id: atom(),
          formula: String.t(),
          status: :ok | :violated | :unverifiable,
          scope: invariant_scope(),
          detail: String.t()
        }

  @typedoc "One RFC S78 explanation answer."
  @type answer ::
          {:answered, term()} | {:partial, term(), String.t()} | {:unanswerable, String.t()}

  # The real, grounded sample text every semantic check below compiles from.
  # Every `source_quote` used in this module is verbatim-present here, because
  # `AshA2A.Semantic.Admission.validate_item/3` really enforces that.
  @sample_text "Goal: deliver the quarterly report. The analyst reviews the draft."
  @sample_source_id "sa2a-conformance-source"

  # Modules that make up the real production DO path, scanned by
  # `check_no_llm_on_production_do_path/0`.
  @do_path_modules [
    AshA2A.CommandBus,
    AshA2A.Dispatcher,
    AshA2A.ReceiptOutbox,
    AshA2A.Receipt,
    AshA2A.Authority
  ]

  # ===========================================================================
  # Top-level reports
  # ===========================================================================

  @doc """
  Runs every real profile-requirement check declared by
  `AshA2A.Semantic.Profile.requirements/0` and returns one
  `t:requirement_result/0` per requirement, in declaration order.
  """
  @spec requirement_results() :: [requirement_result()]
  def requirement_results do
    Enum.map(Profile.requirements(), &run_requirement/1)
  end

  @doc """
  Real conformance status for one level, over its full CUMULATIVE requirement
  set (this level plus every lower level).

  `:conformant?` is true only when every cumulative requirement is `:met`.
  An `{:unverifiable, _}` requirement blocks conformance exactly as hard as an
  `{:unmet, _}` one -- see `AshA2A.Semantic.Profile`'s moduledoc for why.
  """
  @spec level_status(Profile.level()) :: %{
          level: Profile.level(),
          label: String.t(),
          met: [requirement_result()],
          unmet: [requirement_result()],
          unverifiable: [requirement_result()],
          conformant?: boolean()
        }
  def level_status(level), do: level_status(level, requirement_results())

  @doc """
  Same as `level_status/1` but over an already-computed result list, so a
  caller reporting on all five levels runs every real check exactly once
  instead of five times.
  """
  @spec level_status(Profile.level(), [requirement_result()]) :: map()
  def level_status(level, results) do
    ids = level |> Profile.cumulative_requirements() |> MapSet.new(& &1.id)
    scoped = Enum.filter(results, &MapSet.member?(ids, &1.id))
    grouped = Enum.group_by(scoped, & &1.status)

    met = Map.get(grouped, :met, [])
    unmet = Map.get(grouped, :unmet, [])
    unverifiable = Map.get(grouped, :unverifiable, [])

    %{
      level: level,
      label: Profile.label(level),
      met: met,
      unmet: unmet,
      unverifiable: unverifiable,
      conformant?: unmet == [] and unverifiable == []
    }
  end

  @doc """
  The highest level whose full cumulative requirement set is really `:met`, or
  `:none` when even `:sa2a_core` is not fully met.

  This is the only honest way to answer "what does ash_a2a conform to today".
  """
  @spec earned_level() :: Profile.level() | :none
  def earned_level, do: earned_level(requirement_results())

  @doc "Same as `earned_level/0`, over an already-computed result list."
  @spec earned_level([requirement_result()]) :: Profile.level() | :none
  def earned_level(results) do
    Profile.levels()
    |> Enum.filter(&level_status(&1, results).conformant?)
    |> List.last()
    |> Kernel.||(:none)
  end

  @doc """
  One real run of everything: requirement results, per-level status, the RFC
  S60 invariants, and the honestly-earned level.
  """
  @spec report() :: %{
          requirements: [requirement_result()],
          levels: [map()],
          invariants: [invariant_result()],
          earned_level: Profile.level() | :none
        }
  def report do
    results = requirement_results()

    %{
      requirements: results,
      levels: Enum.map(Profile.levels(), &level_status(&1, results)),
      invariants: invariants(),
      earned_level: earned_level(results)
    }
  end

  defp run_requirement(%{check: {module, function}} = requirement) do
    {status, detail} = normalize(apply(module, function, []))

    requirement
    |> Map.take([:id, :level, :title, :rfc_section])
    |> Map.merge(%{status: status, detail: detail})
  end

  defp normalize(:met), do: {:met, "met"}
  defp normalize({:met, detail}), do: {:met, detail}
  defp normalize({:unmet, detail}), do: {:unmet, detail}
  defp normalize({:unverifiable, detail}), do: {:unverifiable, detail}

  # ===========================================================================
  # SA2A-CORE requirement checks
  # ===========================================================================

  @doc """
  Real check: `AshA2A.SemanticSubject.new/1` really accepts a well-formed
  `sha256:<64 hex>` triple of digests and really refuses a malformed one with
  a typed `{:refused_semantic_subject, field}`, and `AshA2A.Semantic.Source`
  really derives its id from content rather than from a call-site counter.
  """
  @spec check_semantic_identity() :: requirement_status()
  def check_semantic_identity do
    good = SemanticSubject.new(digest_opts())
    bad = SemanticSubject.new(Keyword.put(digest_opts(), :graph_digest, "not-a-digest"))
    a = Source.new(@sample_text, [])
    b = Source.new(@sample_text, [])
    c = Source.new(@sample_text <> " changed", [])

    case {good, bad} do
      {{:ok, %SemanticSubject{}}, {:error, {:refused_semantic_subject, :graph_digest}}}
      when a.id == b.id and a.id != c.id ->
        :met

      other ->
        {:unmet,
         "expected a well-formed subject to be accepted, a malformed one refused, and " <>
           "content-derived Source ids; got #{inspect(other)} with source ids " <>
           "#{a.id} / #{b.id} / #{c.id}"}
    end
  end

  @doc """
  Real check: a real admitted `AshA2A.Semantic.IR` really projects to real RDF
  triples through `AshA2A.Semantic.Ontology.from_ir/1`, with real W3C IRIs for
  the well-known terms (`rdf:type`, `prov:wasDerivedFrom`).
  """
  @spec check_rdf_representation() :: requirement_status()
  def check_rdf_representation do
    with {:ok, ontology} <- sample_ontology() do
      rdf_type = Vocabulary.expand("rdf:type")
      typed = Enum.filter(ontology.triples, &(&1.predicate == rdf_type))

      if typed != [] and String.starts_with?(rdf_type, "http://www.w3.org/1999/02/") do
        {:met,
         "#{length(ontology.triples)} real triples projected, #{length(typed)} of them typed " <>
           "with the real W3C IRI #{rdf_type}"}
      else
        {:unmet,
         "expected real rdf:type triples using the real W3C IRI; got #{length(typed)} " <>
           "typed triple(s) over predicate #{rdf_type}"}
      end
    else
      {:error, reason} -> {:unmet, "sample semantic pipeline failed: #{inspect(reason)}"}
    end
  end

  @doc """
  Real check, and a real FALSIFIER: canonical graph identity requires the
  graph digest to be injective over distinct RDF graphs. It is not.

  `AshA2A.Semantic.Vocabulary.expand/1` falls back to `local/1` for any term it
  does not recognize, and `local/1` replaces every non-`[A-Za-z0-9_.-]` run
  with `_`. Two genuinely distinct predicates therefore collapse to one IRI,
  and two genuinely distinct RDF graphs get the SAME
  `AshA2A.Semantic.Ontology` fingerprint. This check builds both graphs for
  real, runs the real pipeline, and reports the real colliding digest.

  `AshA2A.Semantic.Ontology.fingerprint/1` is additionally a SHA-256 over
  `:erlang.term_to_binary/1` of a sorted Elixir term, not an RDF
  canonicalization (RDFC-1.0): it has no blank-node labeling algorithm, no IRI
  normalization, and no literal/datatype normalization. RFC S12 canonical
  graph identity is `AshA2A.Semantic.CanonicalGraph` (RDFC-1.0 over RDF.ex);
  `praxis-graphlaw`'s wasm `graph_hash/1` is not RDFC-1.0 (not
  blank-node-relabel invariant). This check still measures
  `Ontology.fingerprint/1`, which uses neither, so it stays `:unmet` until the
  fingerprint itself is re-derived.
  """
  @spec check_canonical_graph_identity() :: requirement_status()
  def check_canonical_graph_identity do
    # Both predicates are admissible local terms: the namespaced variant
    # ("acme:widget") is refused by Admission's admitted-namespace gate
    # (RFC-SA2A-002 SA2A-LLM-003), but the local-term collision still reaches
    # Ontology.fingerprint/1.
    with {:ok, a} <- sample_ontology(predicate: "acme_widget"),
         {:ok, b} <- sample_ontology(predicate: "acme/widget") do
      if a.fingerprint == b.fingerprint do
        {:unmet,
         "graph identity is NOT injective: predicates \"acme_widget\" and \"acme/widget\" both " <>
           "expand to #{Vocabulary.expand("acme/widget")}, so two distinct RDF graphs share one " <>
           "fingerprint (#{a.fingerprint}). Ontology.fingerprint/1 is a SHA-256 over " <>
           ":erlang.term_to_binary/1 of a sorted Elixir term, not RDFC-1.0 canonicalization " <>
           "(no blank-node labeling, no IRI/literal normalization)."}
      else
        {:unmet,
         "the known IRI-collision falsifier no longer reproduces (#{a.fingerprint} != " <>
           "#{b.fingerprint}), but Ontology.fingerprint/1 is still a term hash rather than an " <>
           "RDFC-1.0 canonical graph hash -- re-derive this check before claiming it met"}
      end
    else
      {:error, reason} -> {:unverifiable, "sample pipeline failed: #{inspect(reason)}"}
    end
  end

  @doc """
  Real check: the vocabulary registry really resolves well-known prefixes to
  the real public W3C/schema.org namespace IRIs, for at least eight registered
  public prefixes.

  This is the "prefer public semantics" half of the requirement only. That
  UNRECOGNIZED terms silently mint a private `urn:ash-a2a:semantic:` IRI is a
  separate, strict-level requirement -- see
  `check_no_runtime_semantic_invention/0`.
  """
  @spec check_public_semantics_first() :: requirement_status()
  def check_public_semantics_first do
    prefixes = Vocabulary.prefixes()

    expected = %{
      "rdf" => "http://www.w3.org/1999/02/22-rdf-syntax-ns#",
      "rdfs" => "http://www.w3.org/2000/01/rdf-schema#",
      "owl" => "http://www.w3.org/2002/07/owl#",
      "prov" => "http://www.w3.org/ns/prov#",
      "schema" => "https://schema.org/"
    }

    mismatched =
      Enum.reject(expected, fn {prefix, iri} ->
        Map.get(prefixes, prefix) == iri and Vocabulary.expand(prefix <> ":Term") == iri <> "Term"
      end)

    cond do
      mismatched != [] ->
        {:unmet, "public prefixes did not resolve to their real IRIs: #{inspect(mismatched)}"}

      map_size(prefixes) < 8 ->
        {:unmet, "only #{map_size(prefixes)} public prefixes registered; expected at least 8"}

      true ->
        :met
    end
  end

  @doc "Real check of a configured ShEx-capable semantic engine. See `engine_capability/2`."
  @spec check_shex_validation() :: requirement_status()
  def check_shex_validation, do: engine_capability(:validate_shex, 3)

  @doc "Real check of a configured SHACL-capable semantic engine. See `engine_capability/2`."
  @spec check_shacl_validation() :: requirement_status()
  def check_shacl_validation, do: engine_capability(:validate_shacl, 2)

  @doc "Real check of a configured SPARQL-capable semantic engine. See `engine_capability/2`."
  @spec check_sparql_falsifiers() :: requirement_status()
  def check_sparql_falsifiers, do: engine_capability(:query_sparql, 2)

  @doc """
  Real check: every semantic node the real `AshA2A.Semantic.Ontology`
  projection emits really carries a `prov:wasDerivedFrom` triple back to the
  real source URN. Executed against the real sample pipeline, then verified by
  set difference (every subject that has an `rdf:type` triple must also have a
  `prov:wasDerivedFrom` triple).
  """
  @spec check_provenance() :: requirement_status()
  def check_provenance do
    with {:ok, ontology} <- sample_ontology() do
      typed = subjects_for(ontology, Vocabulary.expand("rdf:type"))
      provenanced = subjects_for(ontology, Vocabulary.expand("prov:wasDerivedFrom"))
      missing = MapSet.difference(typed, provenanced)

      if MapSet.size(typed) > 0 and MapSet.size(missing) == 0 do
        :met
      else
        {:unmet,
         "#{MapSet.size(missing)} of #{MapSet.size(typed)} typed semantic node(s) carry no " <>
           "prov:wasDerivedFrom triple: #{inspect(MapSet.to_list(missing))}"}
      end
    else
      {:error, reason} -> {:unmet, "sample semantic pipeline failed: #{inspect(reason)}"}
    end
  end

  @doc """
  Real check: a real admitted, authorized `:change` command really runs through
  `AshA2A.CommandBus.run/4` against the real compiled
  `AshA2A.ArchitectureVerifier.Fixture.Resource` and really produces a real
  `AshA2A.Receipt` carrying a real receipt identity, execution identity,
  consequence class, and content fingerprint.
  """
  @spec check_admission_receipts() :: requirement_status()
  def check_admission_receipts do
    case authorized_run("sa2a-conformance-receipt-#{unique()}") do
      {:ok, %Receipt{status: :completed} = receipt} ->
        if is_binary(receipt.fingerprint) and receipt.consequence == :change and
             match?(%Identity{kind: :execution}, receipt.execution_id) do
          :met
        else
          {:unmet, "receipt was produced but is missing real evidence: #{inspect(receipt)}"}
        end

      other ->
        {:unmet, "an authorized :change command did not produce a receipt: #{inspect(other)}"}
    end
  end

  @doc """
  Real check: `AshA2A.CommandBus.run/4` really refuses (a) an `:unknown`
  -consequence capability with `:consequence_unclassified` and (b) a `:change`
  -consequence capability carrying no `AshA2A.Authority` with
  `:authority_required` -- both refused before any dispatch.
  """
  @spec check_fail_closed() :: requirement_status()
  def check_fail_closed do
    unknown = run_unauthorized(:probe, "sa2a-conformance-unknown-#{unique()}")
    unauthorized = run_unauthorized(:create, "sa2a-conformance-unauthorized-#{unique()}")

    case {unknown, unauthorized} do
      {{:error, %{code: :consequence_unclassified}}, {:error, %{code: :authority_required}}} ->
        :met

      other ->
        {:unmet,
         "expected {:consequence_unclassified, :authority_required} refusals, got #{inspect(other)}"}
    end
  end

  # ===========================================================================
  # SA2A-LOGIC requirement checks
  # ===========================================================================

  @doc "Real check of a configured Datalog-capable semantic engine."
  @spec check_safe_finite_datalog() :: requirement_status()
  def check_safe_finite_datalog, do: engine_capability(:datalog_closure, 2)

  @doc "Real check of a configured N3-rule-capable semantic engine."
  @spec check_admitted_n3_rules() :: requirement_status()
  def check_admitted_n3_rules, do: engine_capability(:n3_closure, 2)

  @doc """
  Real check: deterministic closure requires a closure operation to exist in
  the first place. Delegates to the same real engine check as
  `check_admitted_n3_rules/0`; when an engine IS configured this still reports
  `{:unverifiable, _}`, because determinism is a property of two real runs
  over the same input, which this repo has no fixture corpus to drive yet.
  """
  @spec check_deterministic_closure() :: requirement_status()
  def check_deterministic_closure do
    case engine_capability(:n3_closure, 2) do
      :met ->
        {:unverifiable,
         "a semantic engine exposing n3_closure/2 is configured, but determinism is a property " <>
           "of two real runs over an identical admitted graph, and this repo carries no " <>
           "conformance corpus to drive those runs -- not established either way"}

      other ->
        other
    end
  end

  @doc """
  Real check: rule provenance requires derived triples to record their deriving
  rule. `AshA2A.Semantic.Ontology`'s triple shape is a bare
  `%{subject, predicate, object}` map with no rule slot, checked here for real
  against the real projected triples, so nothing derived could carry rule
  provenance even if a rule engine were wired in.
  """
  @spec check_rule_provenance() :: requirement_status()
  def check_rule_provenance do
    with {:ok, ontology} <- sample_ontology() do
      keys = ontology.triples |> Enum.flat_map(&Map.keys/1) |> Enum.uniq() |> Enum.sort()

      {:unmet,
       "projected triples carry keys #{inspect(keys)} -- there is no rule/derivation slot, so " <>
         "no derived triple can record which rule derived it"}
    else
      {:error, reason} -> {:unverifiable, "sample pipeline failed: #{inspect(reason)}"}
    end
  end

  # ===========================================================================
  # SA2A-PLAN requirement checks
  # ===========================================================================

  @doc """
  Real check: a real admitted IR plus its real ontology really project to a
  real `AshA2A.Semantic.PlanningIR` carrying the ontology fingerprint, a real
  primary goal, and its own content fingerprint.
  """
  @spec check_planning_projection() :: requirement_status()
  def check_planning_projection do
    with {:ok, ir} <- sample_admitted_ir(),
         {:ok, ontology} <- Ontology.from_ir(ir),
         {:ok, planning} <- PlanningIR.from_ir(ir, ontology) do
      if planning.ontology_fingerprint == ontology.fingerprint and
           is_binary(PlanningIR.primary_goal(planning)) and
           planning.fingerprint != "pending" do
        :met
      else
        {:unmet, "planning projection was built but is not bound to the ontology it came from"}
      end
    else
      {:error, reason} -> {:unmet, "planning projection failed: #{inspect(reason)}"}
    end
  end

  @doc """
  Real check: FOND planning requires nondeterministic effects to be
  EXPRESSIBLE. `AshA2A.HddlOperator` -- the only operator entity this codebase
  compiles -- declares `parameters`, `preconditions`, `add_effects`, and
  `delete_effects` only: a deterministic STRIPS add/delete-list operator with
  no `oneof`/nondeterministic-outcome slot. Checked for real against the real
  struct's own keys, not against documentation.
  """
  @spec check_fond_hddl() :: requirement_status()
  def check_fond_hddl do
    keys =
      %AshA2A.HddlOperator{}
      |> Map.from_struct()
      |> Map.keys()
      |> Enum.reject(&String.starts_with?(Atom.to_string(&1), "__"))
      |> Enum.sort()

    nondeterministic = Enum.filter(keys, &(&1 in [:oneof, :nondeterministic_effects, :outcomes]))

    if nondeterministic == [] do
      {:unmet,
       "AshA2A.HddlOperator declares #{inspect(keys)} -- a deterministic STRIPS add/delete-list " <>
         "operator with no nondeterministic-outcome slot, so FOND operators are not expressible. " <>
         "The native solver path (AshA2A.Planning.HddlSolver) is real, but nothing upstream of " <>
         "it can emit a nondeterministic effect."}
    else
      {:unverifiable,
       "nondeterministic effect slot(s) #{inspect(nondeterministic)} now exist on " <>
         "AshA2A.HddlOperator, but that the native solver really solves FOND problems is not " <>
         "established by anything in this repo -- re-derive this check"}
    end
  end

  @doc """
  Real check: compiled capabilities carry a real consequence classification,
  but nothing REQUIRES a plannable capability to declare preconditions and
  effects. Checked for real against the real compiled capability index of
  `AshA2A.ArchitectureVerifier.Fixture.Resource`, which compiles cleanly with
  zero declared `hddl_operator` blocks.
  """
  @spec check_capability_preconditions_effects() :: requirement_status()
  def check_capability_preconditions_effects do
    index = Resource |> Info.capability_index() |> List.wrap()
    without = Enum.filter(index, &(Map.get(&1, :hddl_operators, []) == []))

    if without == [] do
      :met
    else
      {:unmet,
       "#{length(without)} of #{length(index)} real compiled capabilities declare no " <>
         "hddl_operator (preconditions/effects): " <>
         "#{Enum.map_join(without, ", ", & &1.id)}. The DSL surface exists " <>
         "(AshA2A.HddlOperator, AshA2A.Skill.hddl_operators) but no gate refuses a capability " <>
         "that omits it, so a plan can be built over capabilities with unstated preconditions."}
    end
  end

  @doc "Real check of an explicitly configured planning fan-out bound."
  @spec check_bounded_fan_out() :: requirement_status()
  def check_bounded_fan_out,
    do: planning_bound(:max_fan_out, "planning fan-out")

  @doc "Real check of an explicitly configured planning resource envelope."
  @spec check_bounded_resource_envelope() :: requirement_status()
  def check_bounded_resource_envelope,
    do: planning_bound(:max_resource_units, "planning resource envelope")

  @doc """
  Real check: plan admission requires an admission gate a selected plan must
  clear. `AshA2A.Semantic.Admission.admit/2` admits semantic IR, and
  `AshA2A.Semantic.PlanningIR` is born with `standing: :admitted` hardcoded in
  its own struct default -- checked here for real -- so a plan projection is
  never actually admitted by anything; it simply declares itself admitted.
  """
  @spec check_plan_admission() :: requirement_status()
  def check_plan_admission do
    with {:ok, ir} <- sample_admitted_ir(),
         {:ok, ontology} <- Ontology.from_ir(ir),
         {:ok, planning} <- PlanningIR.from_ir(ir, ontology) do
      if planning.standing == :admitted and
           not function_exported?(PlanningIR, :admit, 1) and
           not function_exported?(PlanningIR, :admit, 2) do
        {:unmet,
         "PlanningIR is constructed with standing: :admitted by struct default and exposes no " <>
           "admit/1 or admit/2 -- a plan declares its own standing rather than clearing a gate. " <>
           "No selection path refuses an unadmitted plan."}
      else
        {:unverifiable,
         "PlanningIR's admission surface has changed (standing #{inspect(planning.standing)}) -- " <>
           "re-derive this check against the real gate before claiming it met"}
      end
    else
      {:error, reason} -> {:unverifiable, "planning projection failed: #{inspect(reason)}"}
    end
  end

  # ===========================================================================
  # SA2A-DO requirement checks
  # ===========================================================================

  @doc """
  Real check: `AshA2A.Authority.Broker` really exists as a behaviour declaring
  `issue/3`, `revoke/2`, and `verify/2`, and a real reference implementation
  (`AshA2A.Authority.Broker.InMemory`) really exports all three.
  """
  @spec check_authority_broker() :: requirement_status()
  def check_authority_broker do
    broker = AshA2A.Authority.Broker
    impl = AshA2A.Authority.Broker.InMemory
    required = [issue: 3, revoke: 2, verify: 2]

    callbacks =
      if Code.ensure_loaded?(broker) and function_exported?(broker, :behaviour_info, 1),
        do: broker.behaviour_info(:callbacks),
        else: []

    missing_callbacks = Enum.reject(required, &(&1 in callbacks))
    loaded? = Code.ensure_loaded?(impl)

    missing_impl =
      Enum.reject(required, fn {f, a} -> loaded? and function_exported?(impl, f, a) end)

    cond do
      missing_callbacks != [] ->
        {:unmet, "AshA2A.Authority.Broker is missing callbacks #{inspect(missing_callbacks)}"}

      missing_impl != [] ->
        {:unmet, "#{inspect(impl)} does not export #{inspect(missing_impl)}"}

      true ->
        :met
    end
  end

  @doc """
  Real check: `AshA2A.CommandBus` really is the receipted consequence boundary
  -- a real authorized `:change` run really returns a real `AshA2A.Receipt`,
  and the same bus really refuses both unclassified and unauthorized work
  (`check_fail_closed/0`'s two real refusals), so consequence cannot be
  reached without passing through it.
  """
  @spec check_brce() :: requirement_status()
  def check_brce do
    with :met <- check_fail_closed(),
         {:ok, %Receipt{}} <- authorized_run("sa2a-conformance-brce-#{unique()}") do
      :met
    else
      {:unmet, detail} -> {:unmet, "fail-closed admission did not hold: #{detail}"}
      other -> {:unmet, "authorized consequence run did not produce a receipt: #{inspect(other)}"}
    end
  end

  @doc """
  Real check: `AshA2A.Receipt.pending/3` really builds a `:pending` anchor,
  `AshA2A.ReceiptOutbox.append/1` really persists it (real
  `ReceiptOutbox.anchored?/1` returns true for it), and
  `AshA2A.Receipt.finalize/2` really preserves the SAME receipt identity while
  replacing the pending outcome -- the exact mechanism
  `AshA2A.CommandBus.execute_claimed/9` uses before DO.
  """
  @spec check_prepared_receipts() :: requirement_status()
  def check_prepared_receipts do
    command = conformance_command("sa2a-conformance-anchor-#{unique()}", authority?: true)
    execution_id = Identity.execution(Ash.UUIDv7.generate())
    anchor = Receipt.pending(command, execution_id, :change)

    append = ReceiptOutbox.append(anchor)
    anchored? = ReceiptOutbox.anchored?(anchor)
    finalized = Receipt.finalize(anchor, {:reply, :ok})
    ReceiptOutbox.remove(anchor)

    cond do
      append != :ok ->
        {:unmet, "ReceiptOutbox.append/1 refused the pending anchor: #{inspect(append)}"}

      not anchored? ->
        {:unmet, "ReceiptOutbox.anchored?/1 did not see the appended pending anchor"}

      anchor.status != :pending or finalized.status != :completed ->
        {:unmet,
         "anchor/finalized statuses were #{inspect(anchor.status)}/#{inspect(finalized.status)}"}

      finalized.receipt_id != anchor.receipt_id ->
        {:unmet, "finalize/2 did not preserve the anchor's receipt identity"}

      true ->
        :met
    end
  end

  @doc """
  Real check: a real authorized `:change` run really records the OBSERVED
  outcome -- `status: :completed`, a real `reply`, and a real `recorded_at` --
  rather than inferring success.
  """
  @spec check_execution_receipts() :: requirement_status()
  def check_execution_receipts do
    case authorized_run("sa2a-conformance-execution-#{unique()}") do
      {:ok, %Receipt{status: :completed, reply: reply, recorded_at: %DateTime{}}}
      when not is_nil(reply) ->
        :met

      other ->
        {:unmet,
         "expected a real completed receipt carrying the observed reply, got #{inspect(other)}"}
    end
  end

  @doc """
  Real check: `AshA2A.CommandBus.reconcile_outboxed_receipts/2` really drains
  the real outbox into the real configured store and really reports how many
  were committed and how many remain. Exercised with a real appended receipt,
  not an empty outbox.
  """
  @spec check_reconciliation() :: requirement_status()
  def check_reconciliation do
    command = conformance_command("sa2a-conformance-reconcile-#{unique()}", authority?: true)
    execution_id = Identity.execution(Ash.UUIDv7.generate())
    receipt = command |> Receipt.from_reply(execution_id, :change, {:reply, :ok})
    :ok = ReceiptOutbox.append(receipt)

    result = CommandBus.reconcile_outboxed_receipts()
    ReceiptOutbox.remove(receipt)

    case result do
      {:ok, %{committed: committed, remaining: remaining}}
      when is_integer(committed) and is_integer(remaining) and committed >= 1 ->
        :met

      other ->
        {:unmet,
         "reconcile_outboxed_receipts/2 did not drain a real appended receipt: #{inspect(other)}"}
    end
  end

  @doc """
  Real check: replay evidence really distinguishes a genuine retry from a
  conflict. Runs the SAME `command_id` twice with identical content (expecting
  the second to return the first receipt's identity -- a real replay) and then
  a third time with genuinely different input (expecting a real
  `:command_conflict` refusal), all through the real `AshA2A.CommandBus` and
  the real configured receipt store.
  """
  @spec check_replay_evidence() :: requirement_status()
  def check_replay_evidence do
    command_id = "sa2a-conformance-replay-#{unique()}"
    first = authorized_run(command_id)
    replay = authorized_run(command_id)
    conflict = authorized_run(command_id, input: %{divergent: true})

    case {first, replay, conflict} do
      {{:ok, %Receipt{} = a}, {:ok, %Receipt{} = b}, {:error, %{code: :command_conflict}}}
      when a.receipt_id == b.receipt_id ->
        :met

      other ->
        {:unmet,
         "expected {receipt, same-identity replay, :command_conflict}, got #{inspect(other)}"}
    end
  end

  # ===========================================================================
  # SA2A-STRICT requirement checks
  # ===========================================================================

  @doc """
  Real check, and a real FALSIFIER: `AshA2A.Semantic.Vocabulary.expand/1`
  really mints a brand-new private `urn:ash-a2a:semantic:` IRI at runtime for
  any term it does not recognize, with no admission step and no namespace
  gate. Executed here against a term that certainly was never admitted.
  """
  @spec check_no_runtime_semantic_invention() :: requirement_status()
  def check_no_runtime_semantic_invention do
    invented = Vocabulary.expand("never-admitted:term-#{unique()}")

    if String.starts_with?(invented, "urn:ash-a2a:semantic:") do
      {:unmet,
       "Vocabulary.expand/1 minted the private IRI #{invented} at runtime for a term no " <>
         "admission step ever saw. There is no admitted-namespace gate: any unrecognized term " <>
         "silently becomes a new private semantic term."}
    else
      {:unverifiable,
       "Vocabulary.expand/1 no longer mints a private URN for an unrecognized term (got " <>
         "#{invented}) -- re-derive this check against the real new behavior"}
    end
  end

  @doc """
  Real check: meta-admission requires the admission rules themselves to be
  admitted data carrying their own receipt. They are compiled module
  attributes -- `AshA2A.Semantic.Vocabulary.prefixes/0` returns a hardcoded
  map, checked here for real by confirming it is byte-identical across two
  calls and is not sourced from any admitted graph or configuration.
  """
  @spec check_meta_admission() :: requirement_status()
  def check_meta_admission do
    constant? = Vocabulary.prefixes() == Vocabulary.prefixes()
    configured = Application.get_env(:ash_a2a, :admitted_vocabulary)

    if constant? and is_nil(configured) do
      {:unmet,
       "the admission vocabulary is a compiled module attribute " <>
         "(Vocabulary.prefixes/0, #{map_size(Vocabulary.prefixes())} entries) with no " <>
         "corresponding admitted graph, receipt, or :admitted_vocabulary configuration -- the " <>
         "rules that admit everything else are themselves unadmitted"}
    else
      {:unverifiable,
       "an :admitted_vocabulary configuration now exists (#{inspect(configured)}) -- whether it " <>
         "is really admitted with a real receipt is not established by this check"}
    end
  end

  @doc """
  Real check: a Root Manifest pinning the whole admitted semantic surface.
  Checked for real against the real application environment and the real
  module namespace; neither exists.
  """
  @spec check_admitted_root_manifest() :: requirement_status()
  def check_admitted_root_manifest do
    configured = Application.get_env(:ash_a2a, :root_manifest)
    module? = Code.ensure_loaded?(AshA2A.Semantic.RootManifest)

    if is_nil(configured) and not module? do
      {:unmet,
       "no :root_manifest configuration and no AshA2A.Semantic.RootManifest module exist -- " <>
         "nothing pins the admitted semantic surface as a whole, so the set of admitted terms, " <>
         "shapes, and rules has no single admitted root to verify against"}
    else
      {:unverifiable,
       "a root-manifest surface now exists (config #{inspect(configured)}, module " <>
         "#{module?}) -- whether it is really admitted is not established by this check"}
    end
  end

  @doc """
  Real check: projected ephemeral software requires the RUNNING code to be
  verified against the manufacture digest it claims. `AshA2A.SemanticSubject`
  really carries a `manufacturer_digest` and an `ephemeral?` flag, but it is
  explicitly evidence-only (its own moduledoc: "grants no capability and no
  authority"), and nothing on the dispatch path compares it to the running
  code -- witnessed here by the real fact that a command carrying a real
  semantic subject is still refused for missing authority alone.
  """
  @spec check_projected_ephemeral_software() :: requirement_status()
  def check_projected_ephemeral_software do
    {:ok, subject} = SemanticSubject.new(digest_opts())
    refusal = run_unauthorized(:create, "sa2a-conformance-projection-#{unique()}", subject)

    case refusal do
      {:error, %{code: :authority_required}} ->
        {:unmet,
         "SemanticSubject carries a real manufacturer_digest (#{subject.manufacturer_digest}) " <>
           "and ephemeral?: #{subject.ephemeral?}, but it is evidence-only: a command carrying " <>
           "it is admitted or refused purely on authority, and no dispatch-path check compares " <>
           "the running code to the manufacture digest it claims"}

      other ->
        {:unverifiable,
         "the semantic subject now affects admission (#{inspect(other)}) -- re-derive this check"}
    end
  end

  @doc """
  Real check: LLM output can never carry semantic authority.
  `AshA2A.Semantic.IR.from_map/2` really forces any non-`"none"` authority
  claim to `:invalid`, and `AshA2A.Semantic.Admission.admit/2`'s real fence
  really refuses it with `:semantic_authority_ceiling_violated`.
  `AshA2A.Semantic.Ontology.from_ir/1` really refuses a non-admitted IR too.
  All three executed for real here.
  """
  @spec check_no_llm_authority() :: requirement_status()
  def check_no_llm_authority do
    {:ok, claiming} =
      IR.from_map(@sample_source_id, Map.put(sample_ir_map(), "authority", "granted"))

    fenced = Admission.admit(sample_source(), claiming)

    {:ok, candidate} = IR.from_map(@sample_source_id, sample_ir_map())
    unadmitted_ontology = Ontology.from_ir(candidate)

    case {claiming.authority, fenced, candidate.standing, unadmitted_ontology} do
      {:invalid, {:error, %{code: :semantic_authority_ceiling_violated}}, :candidate,
       {:error, %{code: :ontology_requires_admitted_semantics}}} ->
        :met

      other ->
        {:unmet, "the authority ceiling did not hold: #{inspect(other)}"}
    end
  end

  @doc """
  Real STRUCTURAL check: walks the real compiled BEAM abstract code of every
  module on the production DO path (`#{inspect(@do_path_modules)}`) and
  collects every remote call target, then asserts none of them is an LLM
  module (any module whose name contains `Llm`/`LLM`, any
  `AshA2A.Providers.*`, `AshA2A.Semantic.Compiler`, or
  `AshA2A.Planning.SemanticSynthesis`).

  Unlike the witnessed checks, this one really does quantify over every call
  site in the scanned modules -- **provided every call site names its module
  literally**. It reports `{:unverifiable, _}` if abstract code is
  unavailable (stripped beams), and equally if any scanned module contains a
  call site whose callee module is a runtime value.

  ## Why a dynamic call site makes this unverifiable rather than met

  `remote_call_targets/1` reads module atoms out of the AST. A call written
  `mod.run(x)`, or `apply(mod, :run, [x])`, names no module in the AST: the
  target is a runtime value. An earlier revision collected only the literal
  form and then concluded "none is an LLM module" from the targets it could
  see -- so a DO-path module could reach an LLM through a variable and the
  check would still report `:met`.

  This is not hypothetical on the real DO path. A real scan of the real
  compiled beams found `AshA2A.CommandBus` carrying 3 variable-module call
  sites and `AshA2A.ReceiptOutbox` 1 `:erlang.apply/3` site, and the check
  returned `{:met, "...covering 75 distinct remote-call target(s); none is
  an LLM module"}` over them.

  Resolving a dynamic target is not soundly decidable by AST inspection -- it
  would require knowing every value that reaches the module position at
  runtime. So the honest answer is `:unverifiable` with the real sites named,
  not `:met`. A vacuously-true structural check is worse than an absent one:
  it spends the reader's trust and returns nothing for it.
  """
  @spec check_no_llm_on_production_do_path() :: requirement_status()
  def check_no_llm_on_production_do_path do
    scanned = Enum.map(@do_path_modules, &{&1, remote_call_targets(&1), dynamic_call_sites(&1)})

    failures =
      for {module, targets, sites} <- scanned,
          {:error, reason} <- [targets, sites],
          do: {module, reason}

    offenders =
      for {module, {:ok, targets}, _sites} <- scanned,
          target <- targets,
          llm_module?(target),
          do: {module, target}

    dynamic =
      for {module, _targets, {:ok, sites}} <- scanned, sites != [], do: {module, sites}

    cond do
      failures != [] ->
        {:unverifiable, "BEAM abstract code unavailable for #{inspect(failures)}"}

      offenders != [] ->
        {:unmet, "LLM call targets found on the DO path: #{inspect(offenders)}"}

      dynamic != [] ->
        count = Enum.sum(for {_module, sites} <- dynamic, do: length(sites))

        {:unverifiable,
         "no LITERALLY NAMED call target on the DO path is an LLM module, but #{count} call " <>
           "site(s) across #{length(dynamic)} module(s) dispatch on a module that is a runtime " <>
           "value, so the scan does not quantify over them: #{inspect(dynamic)}. Resolving a " <>
           "dynamic callee is not decidable by AST inspection; this requirement is therefore " <>
           "unverifiable by static analysis, not met"}

      true ->
        total = Enum.sum(for {_module, {:ok, targets}, _sites} <- scanned, do: length(targets))

        {:met,
         "scanned the real BEAM abstract code of #{length(@do_path_modules)} DO-path module(s) " <>
           "(#{Enum.map_join(@do_path_modules, ", ", &inspect/1)}) covering #{total} distinct " <>
           "remote-call target(s) with no dynamically dispatched call site; none is an LLM module"}
    end
  end

  @doc "Real check of an explicitly configured bound on production planning iterations."
  @spec check_no_unbounded_production_planning_loop() :: requirement_status()
  def check_no_unbounded_production_planning_loop,
    do: planning_bound(:max_iterations, "production planning loop iterations")

  @doc """
  Real check: every production loop declares explicit finite resource bounds.
  Checked for real against the real `:ash_a2a` application environment -- the
  only real bound configured anywhere is
  `:receipt_commit_retry_delays_ms` (which `AshA2A.CommandBus` really reads),
  and it bounds one retry sequence, not a planning or reasoning envelope.
  """
  @spec check_explicit_finite_resource_bounds() :: requirement_status()
  def check_explicit_finite_resource_bounds do
    retry = Application.get_env(:ash_a2a, :receipt_commit_retry_delays_ms, [50, 150])
    bounds = Application.get_env(:ash_a2a, :planning_bounds)

    if is_nil(bounds) do
      {:unmet,
       "the only real finite bound in the :ash_a2a environment is " <>
         ":receipt_commit_retry_delays_ms (#{inspect(retry)}), which bounds one receipt-commit " <>
         "retry sequence. No :planning_bounds envelope (fan-out, iterations, resource units) " <>
         "is configured or consulted anywhere."}
    else
      {:unverifiable,
       "a :planning_bounds envelope now exists (#{inspect(bounds)}) -- whether every production " <>
         "loop really consults it is not established by this check"}
    end
  end

  # ===========================================================================
  # RFC S60 -- invariants
  # ===========================================================================

  @doc """
  Every RFC S60 invariant, as a real executable check.

  Read `:scope` before reading `:status`. A `:witnessed` `:ok` means a real,
  adversarially-constructed case was executed and the invariant held for it --
  it does NOT mean no code path avoids the gate. A `:structural` `:ok` was
  established by real static analysis over compiled code and does quantify
  over every call site scanned. An `:unverifiable` invariant carries a real
  reason and establishes nothing.
  """
  @spec invariants() :: [invariant_result()]
  def invariants do
    [
      invariant_executed_implies_authorized(),
      invariant_executed_implies_prepared_receipt(),
      invariant_authorized_implies_admitted(),
      invariant_selected_implies_admitted_plan(),
      invariant_constructed_implies_admitted_source(),
      invariant_canonical_implies_admitted(),
      invariant_derived_implies_rule_standing(),
      invariant_validated_implies_validator_standing(),
      invariant_private_term_admission(),
      invariant_llm_output_is_candidate(),
      invariant_projection_is_not_semantic_authority(),
      invariant_message_is_not_fact(),
      invariant_task_is_not_authority()
    ]
  end

  @doc "Invariant: `Executed(a) => Authorized(a)`."
  @spec invariant_executed_implies_authorized() :: invariant_result()
  def invariant_executed_implies_authorized do
    refused = run_unauthorized(:create, "sa2a-invariant-exec-auth-#{unique()}")
    mismatched = run_mismatched_authority("sa2a-invariant-exec-mismatch-#{unique()}")
    executed = authorized_run("sa2a-invariant-exec-ok-#{unique()}")

    case {refused, mismatched, executed} do
      {{:error, %{code: :authority_required}}, {:error, %{code: :authority_mismatch}},
       {:ok, %Receipt{status: :completed}}} ->
        ok(
          :executed_implies_authorized,
          "Executed(a) => Authorized(a)",
          :witnessed,
          "a :change command with no Authority was refused (:authority_required), one with an " <>
            "Authority naming a different principal was refused (:authority_mismatch), and only " <>
            "the correctly-authorized command really executed"
        )

      other ->
        violated(
          :executed_implies_authorized,
          "Executed(a) => Authorized(a)",
          "expected {:authority_required, :authority_mismatch, completed}, got #{inspect(other)}"
        )
    end
  end

  @doc "Invariant: `Executed(a) => PreparedReceipt(a)`."
  @spec invariant_executed_implies_prepared_receipt() :: invariant_result()
  def invariant_executed_implies_prepared_receipt do
    case check_prepared_receipts() do
      :met ->
        case authorized_run("sa2a-invariant-prepared-#{unique()}") do
          {:ok, %Receipt{execution_id: %Identity{kind: :execution}}} ->
            ok(
              :executed_implies_prepared_receipt,
              "Executed(a) => PreparedReceipt(a)",
              :witnessed,
              "Receipt.pending/3 really anchored to ReceiptOutbox before DO and finalize/2 " <>
                "preserved the same receipt identity; a real executed :change command carries " <>
                "the resulting real execution identity"
            )

          other ->
            violated(
              :executed_implies_prepared_receipt,
              "Executed(a) => PreparedReceipt(a)",
              "an executed command carried no execution identity: #{inspect(other)}"
            )
        end

      {status, detail} when status in [:unmet, :unverifiable] ->
        unverifiable(
          :executed_implies_prepared_receipt,
          "Executed(a) => PreparedReceipt(a)",
          "the prepared-receipt mechanism itself did not hold: #{detail}"
        )
    end
  end

  @doc "Invariant: `Authorized(a) => Admitted(a)`."
  @spec invariant_authorized_implies_admitted() :: invariant_result()
  def invariant_authorized_implies_admitted do
    expired = run_expired_authority("sa2a-invariant-expired-#{unique()}")
    unknown = run_unauthorized(:probe, "sa2a-invariant-unknown-#{unique()}")

    case {expired, unknown} do
      {{:error, %{code: :authority_mismatch}}, {:error, %{code: :consequence_unclassified}}} ->
        ok(
          :authorized_implies_admitted,
          "Authorized(a) => Admitted(a)",
          :witnessed,
          "holding an Authority is not sufficient: a real EXPIRED Authority naming the right " <>
            "principal and capability was still refused (:authority_mismatch), and an " <>
            "unclassified-consequence capability was refused before authority was even consulted"
        )

      other ->
        violated(
          :authorized_implies_admitted,
          "Authorized(a) => Admitted(a)",
          "expected {:authority_mismatch, :consequence_unclassified}, got #{inspect(other)}"
        )
    end
  end

  @doc "Invariant: `Selected(p) => AdmittedPlan(p)`."
  @spec invariant_selected_implies_admitted_plan() :: invariant_result()
  def invariant_selected_implies_admitted_plan do
    {_status, detail} = normalize(check_plan_admission())

    unverifiable(
      :selected_implies_admitted_plan,
      "Selected(p) => AdmittedPlan(p)",
      "there is no plan-admission gate to witness: #{detail}"
    )
  end

  @doc "Invariant: `Constructed(c) => AdmittedSource(c)`."
  @spec invariant_constructed_implies_admitted_source() :: invariant_result()
  def invariant_constructed_implies_admitted_source do
    {:ok, ir} = IR.from_map("a-different-source-id", sample_ir_map())
    mismatch = Admission.admit(sample_source(), ir)

    {:ok, ungrounded} = IR.from_map(@sample_source_id, ungrounded_ir_map())
    ungrounded_result = Admission.admit(sample_source(), ungrounded)

    case {mismatch, ungrounded_result} do
      {{:error, %{code: :semantic_source_mismatch}}, {:error, %{code: :ungrounded_assertion}}} ->
        ok(
          :constructed_implies_admitted_source,
          "Constructed(c) => AdmittedSource(c)",
          :witnessed,
          "IR claiming a different source id was refused (:semantic_source_mismatch), and an " <>
            "item whose source_quote is not verbatim present in the real source text was " <>
            "refused (:ungrounded_assertion)"
        )

      other ->
        violated(
          :constructed_implies_admitted_source,
          "Constructed(c) => AdmittedSource(c)",
          "expected {:semantic_source_mismatch, :ungrounded_assertion}, got #{inspect(other)}"
        )
    end
  end

  @doc "Invariant: `Canonical(x) => Admitted(x)`."
  @spec invariant_canonical_implies_admitted() :: invariant_result()
  def invariant_canonical_implies_admitted do
    {:ok, candidate} = IR.from_map(@sample_source_id, sample_ir_map())
    refused = Ontology.from_ir(candidate)
    projected = with({:ok, ir} <- sample_admitted_ir(), do: Ontology.from_ir(ir))

    case {candidate.standing, refused, projected} do
      {:candidate, {:error, %{code: :ontology_requires_admitted_semantics}}, {:ok, %Ontology{}}} ->
        ok(
          :canonical_implies_admitted,
          "Canonical(x) => Admitted(x)",
          :witnessed,
          "Ontology.from_ir/1 really refused a :candidate IR and really projected the same IR " <>
            "once it had been admitted by Semantic.Admission.admit/2"
        )

      other ->
        violated(
          :canonical_implies_admitted,
          "Canonical(x) => Admitted(x)",
          "expected a refusal for candidate IR and a projection for admitted IR, got #{inspect(other)}"
        )
    end
  end

  @doc "Invariant: `Derived(x, r) AND Canonical(x) => Standing(r)`."
  @spec invariant_derived_implies_rule_standing() :: invariant_result()
  def invariant_derived_implies_rule_standing do
    {_status, detail} = normalize(check_rule_provenance())

    unverifiable(
      :derived_implies_rule_standing,
      "Derived(x, r) AND Canonical(x) => Standing(r)",
      "nothing derives triples in this repo and nothing could record a deriving rule: #{detail}"
    )
  end

  @doc "Invariant: `Validated(x, v) AND Admitted(x) => Standing(v)`."
  @spec invariant_validated_implies_validator_standing() :: invariant_result()
  def invariant_validated_implies_validator_standing do
    {_status, detail} = normalize(check_shacl_validation())

    unverifiable(
      :validated_implies_validator_standing,
      "Validated(x, v) AND Admitted(x) => Standing(v)",
      "no validator runs against admitted graphs, so no validator standing exists to check: " <>
        detail
    )
  end

  @doc """
  Invariant: `PrivateTerm(x) AND Strict => AdmittedNamespace(x)`.

  This one really is VIOLATED, and the violation is executed, not described:
  `AshA2A.Semantic.Vocabulary.expand/1` mints a private
  `urn:ash-a2a:semantic:` IRI for any unrecognized term with no admitted
  namespace anywhere, and the mapping is not even injective.
  """
  @spec invariant_private_term_admission() :: invariant_result()
  def invariant_private_term_admission do
    colon = Vocabulary.expand("acme:widget")
    slash = Vocabulary.expand("acme/widget")

    if String.starts_with?(colon, "urn:ash-a2a:semantic:") and colon == slash do
      violated(
        :private_term_admission,
        "PrivateTerm(x) AND Strict => AdmittedNamespace(x)",
        "executed falsifier: \"acme:widget\" and \"acme/widget\" both mint the SAME private IRI " <>
          "#{colon} with no admitted namespace and no admission step. Private terms are both " <>
          "un-admitted and non-injective."
      )
    else
      unverifiable(
        :private_term_admission,
        "PrivateTerm(x) AND Strict => AdmittedNamespace(x)",
        "the known falsifier no longer reproduces (#{colon} vs #{slash}) -- re-derive before " <>
          "claiming this invariant holds"
      )
    end
  end

  @doc "Invariant: `LLMOutput(x) => Candidate(x)`."
  @spec invariant_llm_output_is_candidate() :: invariant_result()
  def invariant_llm_output_is_candidate do
    case check_no_llm_authority() do
      :met ->
        ok(
          :llm_output_is_candidate,
          "LLMOutput(x) => Candidate(x)",
          :witnessed,
          "IR.from_map/2 really forced a proposed \"authority\": \"granted\" to :invalid, " <>
            "Semantic.Admission.admit/2 really refused it " <>
            "(:semantic_authority_ceiling_violated), and every IR.from_map/2 result really " <>
            "starts at standing: :candidate"
        )

      {_status, detail} ->
        violated(
          :llm_output_is_candidate,
          "LLMOutput(x) => Candidate(x)",
          "the authority ceiling did not hold: #{detail}"
        )
    end
  end

  @doc "Invariant: `Projection(x) NOT=> SemanticAuthority(x)`."
  @spec invariant_projection_is_not_semantic_authority() :: invariant_result()
  def invariant_projection_is_not_semantic_authority do
    {:ok, subject} = SemanticSubject.new(digest_opts())
    refusal = run_unauthorized(:create, "sa2a-invariant-projection-#{unique()}", subject)

    case refusal do
      {:error, %{code: :authority_required}} ->
        ok(
          :projection_is_not_semantic_authority,
          "Projection(x) NOT=> SemanticAuthority(x)",
          :witnessed,
          "a real command carrying a real SemanticSubject (graph #{subject.graph_digest}) was " <>
            "still refused :authority_required -- carrying a semantic projection identity " <>
            "confers no authority whatsoever"
        )

      other ->
        violated(
          :projection_is_not_semantic_authority,
          "Projection(x) NOT=> SemanticAuthority(x)",
          "a semantic subject changed the admission outcome: #{inspect(other)}"
        )
    end
  end

  @doc "Invariant: `Message(x) NOT=> Fact(x)`."
  @spec invariant_message_is_not_fact() :: invariant_result()
  def invariant_message_is_not_fact do
    {:ok, ungrounded} = IR.from_map(@sample_source_id, ungrounded_ir_map())

    case Admission.admit(sample_source(), ungrounded) do
      {:error, %{code: :ungrounded_assertion, detail: id}} ->
        ok(
          :message_is_not_fact,
          "Message(x) NOT=> Fact(x)",
          :witnessed,
          "an asserted item (#{inspect(id)}) whose source_quote is not verbatim present in the " <>
            "real message text was refused :ungrounded_assertion -- asserting something in a " <>
            "message does not make it admitted fact"
        )

      other ->
        violated(
          :message_is_not_fact,
          "Message(x) NOT=> Fact(x)",
          "an ungrounded assertion was not refused: #{inspect(other)}"
        )
    end
  end

  @doc "Invariant: `Task(x) NOT=> Authority(x)`."
  @spec invariant_task_is_not_authority() :: invariant_result()
  def invariant_task_is_not_authority do
    command =
      conformance_command("sa2a-invariant-task-#{unique()}",
        authority?: false,
        task_id: Identity.task(Ash.UUIDv7.generate())
      )

    case CommandBus.run(command, probe_message(), Resource) do
      {:error, %{code: :authority_required}} ->
        ok(
          :task_is_not_authority,
          "Task(x) NOT=> Authority(x)",
          :witnessed,
          "a real command carrying a real task identity " <>
            "(#{Identity.external(command.task_id)}) but no Authority was still refused " <>
            ":authority_required -- being part of a task confers no authority"
        )

      other ->
        violated(
          :task_is_not_authority,
          "Task(x) NOT=> Authority(x)",
          "a task identity changed the admission outcome: #{inspect(other)}"
        )
    end
  end

  # ===========================================================================
  # RFC S78 -- the twelve questions
  # ===========================================================================

  @doc """
  Answers the RFC S78 twelve questions about one real `AshA2A.Receipt`, using
  only the evidence the current receipt + envelope surface genuinely carries.

  Every answer is one of:

    * `{:answered, value}` -- the receipt really carries this.
    * `{:partial, value, gap}` -- partially answerable; `gap` names exactly
      what is missing.
    * `{:unanswerable, reason}` -- the surface genuinely cannot answer this
      yet, with the real reason.

  Nothing here infers an answer the receipt does not actually carry.
  """
  @spec explain(Receipt.t()) :: [
          %{id: atom(), question: String.t(), rfc_section: String.t(), answer: answer()}
        ]
  def explain(%Receipt{} = receipt) do
    [
      question(:meaning, "What does this mean?", answer_meaning(receipt)),
      question(:standing, "Why does it have standing?", answer_standing(receipt)),
      question(:rules, "Which rules derived it?", answer_rules()),
      question(:validators, "Which validators admitted it?", answer_validators()),
      question(:plan, "Which plan selected it?", answer_plan(receipt)),
      question(:authority, "Who had the authority?", answer_authority(receipt)),
      question(:receipt_location, "Where is the receipt?", answer_receipt_location(receipt)),
      question(:replay, "Can it be replayed?", answer_replay(receipt)),
      question(:consequence, "What consequence class did it cross?", answer_consequence(receipt)),
      question(
        :refusal,
        "What was refused, and under which typed code?",
        answer_refusal(receipt)
      ),
      question(:ordering, "When, and in what execution order?", answer_ordering(receipt)),
      question(:subject, "What exact semantic subject produced it?", answer_subject(receipt))
    ]
  end

  @doc """
  Convenience: `explain/1` over a real receipt produced by a real authorized
  run, for a caller that wants to see the explanation surface exercised
  end to end without building a command itself.
  """
  @spec explain_sample() :: {:ok, [map()]} | {:error, term()}
  def explain_sample do
    with {:ok, subject} <- real_semantic_subject(),
         {:ok, %Receipt{} = receipt} <-
           authorized_run("sa2a-conformance-explain-#{unique()}", semantic_subject: subject) do
      {:ok, explain(receipt)}
    else
      other -> {:error, other}
    end
  end

  @doc """
  A real `AshA2A.SemanticSubject` whose three digests are really derived from
  real content -- the real `AshA2A.Semantic.Ontology` fingerprint of the
  admitted sample graph, the real `AshA2A.Semantic.PlanningIR` fingerprint
  projected from it, and a real BLAKE-free SHA-256 of this module's own
  compiled BEAM file (a real manufacture digest of the running code, not a
  placeholder).
  """
  @spec real_semantic_subject() :: {:ok, SemanticSubject.t()} | {:error, term()}
  def real_semantic_subject do
    with {:ok, ir} <- sample_admitted_ir(),
         {:ok, ontology} <- Ontology.from_ir(ir),
         {:ok, planning} <- PlanningIR.from_ir(ir, ontology),
         {:ok, manufacturer} <- running_code_digest() do
      SemanticSubject.new(
        graph_digest: "sha256:" <> ontology.fingerprint,
        projection_digest: "sha256:" <> planning.fingerprint,
        manufacturer_digest: "sha256:" <> manufacturer
      )
    end
  end

  defp running_code_digest do
    case :code.which(__MODULE__) do
      path when is_list(path) ->
        case File.read(to_string(path)) do
          {:ok, binary} ->
            {:ok, :sha256 |> :crypto.hash(binary) |> Base.encode16(case: :lower)}

          {:error, reason} ->
            {:error, {:beam_unreadable, reason}}
        end

      other ->
        {:error, {:beam_unavailable, other}}
    end
  end

  @doc """
  How many of the twelve RFC S78 questions this receipt surface really
  answers, partially answers, and genuinely cannot answer.
  """
  @spec explain_coverage([map()]) :: %{
          answered: non_neg_integer(),
          partial: non_neg_integer(),
          unanswerable: non_neg_integer()
        }
  def explain_coverage(answers) when is_list(answers) do
    tally = Enum.frequencies_by(answers, &elem(&1.answer, 0))

    %{
      answered: Map.get(tally, :answered, 0),
      partial: Map.get(tally, :partial, 0),
      unanswerable: Map.get(tally, :unanswerable, 0)
    }
  end

  defp question(id, text, answer),
    do: %{id: id, question: text, rfc_section: "S78", answer: answer}

  defp answer_meaning(%Receipt{semantic_subject: nil, capability_id: capability}) do
    {:partial, %{capability_id: capability},
     "the receipt names the capability that ran but carries no SemanticSubject, so there is no " <>
       "admitted graph to resolve the meaning of this claim against"}
  end

  defp answer_meaning(%Receipt{semantic_subject: subject, capability_id: capability}) do
    {:partial, %{capability_id: capability, graph_digest: subject.graph_digest},
     "the graph digest identifies WHICH admitted graph gave this capability its meaning, but " <>
       "nothing in this repo can resolve that digest back to the graph's triples"}
  end

  defp answer_standing(%Receipt{standing: standing, status: status}) do
    {:answered,
     %{
       receipt_standing: standing,
       status: status,
       durable?: standing == :durable,
       store: CommandBus.default_store()
     }}
  end

  defp answer_rules do
    {:unanswerable,
     "no rule engine runs in this repo and AshA2A.Semantic.Ontology triples carry no " <>
       "derivation slot -- see AshA2A.Semantic.Conformance.check_rule_provenance/0"}
  end

  defp answer_validators do
    {:unanswerable,
     "no ShEx/SHACL validator is wired in (no :semantic_engine configured) -- see " <>
       "AshA2A.Semantic.Conformance.check_shacl_validation/0"}
  end

  defp answer_plan(%Receipt{metadata: metadata}) do
    case Map.get(metadata, :plan_id) || Map.get(metadata, "plan_id") do
      nil ->
        {:unanswerable,
         "AshA2A.Receipt carries no plan field and this receipt's metadata carries no :plan_id; " <>
           "nothing on the dispatch path records which plan selected a command"}

      plan_id ->
        {:partial, %{plan_id: plan_id},
         "a plan id was recorded in receipt metadata, but there is no plan admission record to " <>
           "resolve it against -- see check_plan_admission/0"}
    end
  end

  defp answer_authority(%Receipt{principal_id: principal, capability_id: capability}) do
    {:partial, %{principal_id: principal, capability_id: capability},
     "AshA2A.Receipt has no authority field: the admitting AshA2A.Authority's token_id, source, " <>
       "and expiry are NOT recorded, so the principal is known but the specific authority " <>
       "grant it acted under is not"}
  end

  defp answer_receipt_location(%Receipt{receipt_id: id, execution_id: execution_id}) do
    store = CommandBus.default_store()

    {:answered,
     %{
       receipt_id: Identity.external(id),
       execution_id: Identity.external(execution_id),
       store: store,
       durable_store?:
         Code.ensure_loaded?(store) and function_exported?(store, :durable?, 0) and
           store.durable?()
     }}
  end

  defp answer_replay(%Receipt{
         command_id: command_id,
         fingerprint: fingerprint,
         replayed?: replayed?
       }) do
    {:answered,
     %{
       command_id: Identity.external(command_id),
       fingerprint: fingerprint,
       already_replayed?: replayed?,
       mechanism:
         "re-submitting the same command_id with identical content returns this same receipt; " <>
           "the same command_id with different content is refused :command_conflict"
     }}
  end

  defp answer_consequence(%Receipt{consequence: consequence}) do
    {:answered,
     %{consequence: consequence, receipt_anchor_required?: consequence in [:change, :external_do]}}
  end

  defp answer_refusal(%Receipt{status: :failed, reply: {:error, %{code: code} = detail}}),
    do: {:answered, %{refused?: true, code: code, detail: detail}}

  defp answer_refusal(%Receipt{status: :failed, reply: reply}),
    do:
      {:partial, %{refused?: true, reply: reply}, "the failure reply carries no typed :code key"}

  defp answer_refusal(%Receipt{status: status}),
    do: {:answered, %{refused?: false, status: status}}

  defp answer_ordering(%Receipt{recorded_at: at, execution_id: execution_id, task_id: task_id}) do
    {:partial,
     %{
       recorded_at: at,
       execution_id: Identity.external(execution_id),
       task_id: task_id && Identity.external(task_id)
     },
     "recorded_at is a wall-clock stamp taken at finalization, not a causal order: no event " <>
       "sequence number, OCEL event id, or happens-before edge is recorded, so two receipts " <>
       "cannot be strictly ordered from receipt evidence alone"}
  end

  defp answer_subject(%Receipt{semantic_subject: nil}) do
    {:unanswerable,
     "this receipt carries no AshA2A.SemanticSubject: the command that produced it was not " <>
       "bound to a semantic graph, projection, or manufacture digest"}
  end

  defp answer_subject(%Receipt{semantic_subject: subject}) do
    {:answered,
     %{
       graph_digest: subject.graph_digest,
       projection_digest: subject.projection_digest,
       manufacturer_digest: subject.manufacturer_digest,
       ephemeral?: subject.ephemeral?
     }}
  end

  # ===========================================================================
  # Real shared helpers
  # ===========================================================================

  @doc """
  Real check of one capability on the configured external semantic engine
  (`config :ash_a2a, semantic_engine: MyEngine`).

  Reads the real application environment, resolves the real module, and asks
  `function_exported?/3` for the real function -- returning `{:unmet, _}`
  naming the exact missing function when it is absent.
  """
  @spec engine_capability(atom(), arity()) :: requirement_status()
  def engine_capability(function, arity) do
    case Application.get_env(:ash_a2a, :semantic_engine) do
      nil ->
        {:unmet,
         "no :semantic_engine is configured, so #{function}/#{arity} is unavailable. This " <>
           "repo deliberately implements no Elixir ShEx/SHACL/SPARQL/Datalog/N3 engine; the " <>
           "expected provider is an external engine (e.g. praxis-graphlaw compiled to wasm) " <>
           "wired in as `config :ash_a2a, semantic_engine: MyEngine`."}

      module when is_atom(module) ->
        if Code.ensure_loaded?(module) and function_exported?(module, function, arity) do
          :met
        else
          {:unmet,
           "configured :semantic_engine #{inspect(module)} does not export " <>
             "#{function}/#{arity}"}
        end
    end
  end

  defp planning_bound(key, label) do
    bounds = Application.get_env(:ash_a2a, :planning_bounds, [])
    value = if is_list(bounds), do: Keyword.get(bounds, key), else: Map.get(bounds, key)

    cond do
      is_integer(value) and value > 0 ->
        :met

      is_nil(value) ->
        {:unmet,
         "no #{label} bound is configured (:ash_a2a, :planning_bounds[#{inspect(key)}]) and no " <>
           "code path consults one, so #{label} is unbounded by construction"}

      true ->
        {:unmet, "#{label} bound #{inspect(value)} is not a positive integer"}
    end
  end

  defp sample_source, do: Source.new(@sample_text, id: @sample_source_id)

  defp sample_ir_map(opts \\ []) do
    predicate = Keyword.get(opts, :predicate, "schema:agent")

    %{
      "authority" => "none",
      "goals" => [
        %{
          "id" => "g1",
          "kind" => "goal",
          "description" => "deliver the quarterly report",
          "source_quote" => "deliver the quarterly report"
        }
      ],
      "entities" => [
        %{
          "id" => "e1",
          "kind" => "entity",
          "type" => "schema:Person",
          "label" => "The analyst",
          "source_quote" => "The analyst"
        }
      ],
      "relations" => [
        %{
          "id" => "r1",
          "kind" => "relation",
          "subject" => "e1",
          "predicate" => predicate,
          "object" => "g1",
          "source_quote" => "The analyst reviews the draft"
        }
      ]
    }
  end

  defp ungrounded_ir_map do
    map = sample_ir_map()

    Map.put(map, "observations", [
      %{
        "id" => "o1",
        "kind" => "observation",
        "description" => "the report was already approved by the board",
        "source_quote" => "the report was already approved by the board"
      }
    ])
  end

  defp sample_admitted_ir(opts \\ []) do
    with {:ok, ir} <- IR.from_map(@sample_source_id, sample_ir_map(opts)) do
      Admission.admit(sample_source(), ir)
    end
  end

  defp sample_ontology(opts \\ []) do
    with {:ok, ir} <- sample_admitted_ir(opts), do: Ontology.from_ir(ir)
  end

  defp subjects_for(%Ontology{triples: triples}, predicate) do
    triples
    |> Enum.filter(&(&1.predicate == predicate))
    |> MapSet.new(& &1.subject)
  end

  defp digest_opts do
    [
      graph_digest: "sha256:" <> String.duplicate("a", 64),
      projection_digest: "sha256:" <> String.duplicate("b", 64),
      manufacturer_digest: "sha256:" <> String.duplicate("c", 64)
    ]
  end

  @principal_id "sa2a-conformance-principal"

  defp conformance_command(command_id, opts) do
    capability_id = Keyword.get(opts, :capability_id, capability_id(:create))
    principal = Identity.principal(@principal_id)

    authority =
      case Keyword.get(opts, :authority?, true) do
        true -> conformance_authority(principal, capability_id)
        false -> nil
        %Authority{} = explicit -> explicit
      end

    Command.new(capability_id,
      command_id: command_id,
      agent_id: "sa2a-conformance",
      principal_id: @principal_id,
      task_id: Keyword.get(opts, :task_id),
      authority: authority,
      semantic_subject: Keyword.get(opts, :semantic_subject),
      input: Keyword.get(opts, :input, %{})
    )
  end

  # A DETERMINISTIC token id, not `Authority.new/3`'s default fresh UUIDv7.
  # `AshA2A.Command.fingerprint/1` really hashes `authority.token_id`, so a
  # fresh random token per call would make two runs of the SAME command_id
  # with identical content fingerprint differently and be refused
  # `:command_conflict` instead of recognized as a real replay -- which would
  # silently break `check_replay_evidence/0` and make repeated runs of
  # `requirement_results/0` in one VM fail for a reason that has nothing to do
  # with conformance.
  defp conformance_authority(principal, capability_id) do
    Authority.new(principal, capability_id,
      source: :sa2a_conformance,
      token_id: "sa2a-conformance-token:" <> capability_id
    )
  end

  defp authorized_run(command_id, opts \\ []) do
    command_id
    |> conformance_command(Keyword.put(opts, :authority?, true))
    |> CommandBus.run(probe_message(), Resource)
  end

  defp run_unauthorized(action, command_id, semantic_subject \\ nil) do
    command_id
    |> conformance_command(
      authority?: false,
      capability_id: capability_id(action),
      semantic_subject: semantic_subject
    )
    |> CommandBus.run(probe_message(), Resource)
  end

  defp run_mismatched_authority(command_id) do
    other = Identity.principal("sa2a-conformance-someone-else")
    authority = Authority.new(other, capability_id(:create), source: :sa2a_conformance)

    command_id
    |> conformance_command(authority?: authority)
    |> CommandBus.run(probe_message(), Resource)
  end

  defp run_expired_authority(command_id) do
    principal = Identity.principal(@principal_id)

    authority =
      Authority.new(principal, capability_id(:create),
        source: :sa2a_conformance,
        expires_at: DateTime.add(DateTime.utc_now(), -3600, :second)
      )

    command_id
    |> conformance_command(authority?: authority)
    |> CommandBus.run(probe_message(), Resource)
  end

  defp capability_id(action) do
    Resource
    |> Info.capability_index()
    |> List.wrap()
    |> Enum.find(&(&1.action == action))
    |> case do
      nil -> "sa2a-conformance:missing-#{action}"
      skill -> skill.id
    end
  end

  defp probe_message, do: A2A.Message.new_user([A2A.Part.Data.new(%{})])

  defp unique, do: System.unique_integer([:positive, :monotonic])

  # -- static analysis over real compiled BEAM abstract code --

  @doc """
  Every **literally named** remote-call target module appearing in `module`'s
  real compiled BEAM abstract code, sorted and deduplicated.

  Returns `{:error, reason}` when abstract code is unavailable (a stripped
  beam, a preloaded module, a cover-compiled module) -- never a guess.

  This function sees only call sites whose module is an atom literal in the
  AST. A call whose module is a variable, or an `apply/3` whose module
  argument is computed, names no module here and contributes nothing. That is
  a real blind spot, not a rounding error, so it is reported separately
  rather than left implicit -- see `dynamic_call_sites/1`.
  """
  @spec remote_call_targets(module()) :: {:ok, [module()]} | {:error, term()}
  def remote_call_targets(module) do
    with {:ok, forms} <- abstract_code(module) do
      {:ok, forms |> collect_remote_modules() |> Enum.uniq() |> Enum.sort()}
    end
  end

  @doc """
  Every call site in `module`'s real compiled BEAM abstract code whose callee
  module is **not** decidable by reading the AST.

  Returns `{:ok, [{kind, line}]}` where `kind` is:

    * `:variable_module` -- `Mod.fun(...)` where `Mod` is a variable or any
      other non-literal expression.
    * `:dynamic_apply` -- `apply(M, F, A)` (`:erlang.apply/3`, which is what
      `Kernel.apply/3` compiles to) whose module argument is not an atom
      literal. `apply/2` on a fun value is included for the same reason.
    * `:dynamic_make_fun` -- `:erlang.make_fun/3` with a non-literal module,
      the shape a captured `&Mod.fun/1` takes when `Mod` is computed.

  Returns `{:error, reason}` when abstract code is unavailable.

  Resolving these targets is **not** soundly decidable by AST inspection --
  the module is a runtime value. Detecting that they *exist* is, which is
  what this does, and is what lets `check_no_llm_on_production_do_path/0`
  answer `:unverifiable` instead of a false `:met`.
  """
  @spec dynamic_call_sites(module()) :: {:ok, [{atom(), non_neg_integer()}]} | {:error, term()}
  def dynamic_call_sites(module) do
    with {:ok, forms} <- abstract_code(module) do
      {:ok, forms |> collect_dynamic_sites() |> Enum.uniq() |> Enum.sort()}
    end
  end

  defp abstract_code(module) do
    with path when is_list(path) <- :code.which(module),
         {:ok, {^module, [abstract_code: {:raw_abstract_v1, forms}]}} <-
           :beam_lib.chunks(path, [:abstract_code]) do
      {:ok, forms}
    else
      other -> {:error, other}
    end
  end

  defp collect_remote_modules({:call, _anno, {:remote, _, {:atom, _, module}, _fun}, args}),
    do: [module | collect_remote_modules(args)]

  defp collect_remote_modules(tuple) when is_tuple(tuple),
    do: tuple |> Tuple.to_list() |> collect_remote_modules()

  defp collect_remote_modules(list) when is_list(list),
    do: Enum.flat_map(list, &collect_remote_modules/1)

  defp collect_remote_modules(_other), do: []

  # `:erlang.apply/3` with a literal module is just a literal remote call
  # written the long way, and `collect_remote_modules/1` already sees the
  # `:erlang` target; it is the non-literal module argument that is opaque.
  defp collect_dynamic_sites(
         {:call, anno, {:remote, _, {:atom, _, :erlang}, {:atom, _, :apply}}, [m | _] = args}
       ) do
    sites = if literal_module?(m), do: [], else: [{:dynamic_apply, line(anno)}]
    sites ++ collect_dynamic_sites(args)
  end

  defp collect_dynamic_sites(
         {:call, anno, {:remote, _, {:atom, _, :erlang}, {:atom, _, :apply}}, args}
       ),
       do: [{:dynamic_apply, line(anno)} | collect_dynamic_sites(args)]

  defp collect_dynamic_sites(
         {:call, anno, {:remote, _, {:atom, _, :erlang}, {:atom, _, :make_fun}}, [m | _] = args}
       ) do
    sites = if literal_module?(m), do: [], else: [{:dynamic_make_fun, line(anno)}]
    sites ++ collect_dynamic_sites(args)
  end

  defp collect_dynamic_sites({:call, anno, {:remote, _, mod, _fun}, args}) do
    sites = if literal_module?(mod), do: [], else: [{:variable_module, line(anno)}]
    sites ++ collect_dynamic_sites(args)
  end

  defp collect_dynamic_sites(tuple) when is_tuple(tuple),
    do: tuple |> Tuple.to_list() |> collect_dynamic_sites()

  defp collect_dynamic_sites(list) when is_list(list),
    do: Enum.flat_map(list, &collect_dynamic_sites/1)

  defp collect_dynamic_sites(_other), do: []

  defp literal_module?({:atom, _, _}), do: true
  defp literal_module?(_other), do: false

  defp line(anno) when is_integer(anno), do: anno
  defp line(anno) when is_list(anno), do: Keyword.get(anno, :location, 0)
  defp line({line, _column}), do: line
  defp line(_other), do: 0

  @doc "Whether a module atom names an LLM-bearing module, for the DO-path scan."
  @spec llm_module?(module()) :: boolean()
  def llm_module?(module) when is_atom(module) do
    name = Atom.to_string(module)

    String.contains?(name, "Llm") or String.contains?(name, "LLM") or
      String.starts_with?(name, "Elixir.AshA2A.Providers.") or
      name in [
        "Elixir.AshA2A.Semantic.Compiler",
        "Elixir.AshA2A.Planning.SemanticSynthesis"
      ]
  end

  # -- invariant result constructors --

  defp ok(id, formula, scope, detail),
    do: %{id: id, formula: formula, status: :ok, scope: scope, detail: detail}

  defp violated(id, formula, detail),
    do: %{id: id, formula: formula, status: :violated, scope: :witnessed, detail: detail}

  defp unverifiable(id, formula, detail),
    do: %{id: id, formula: formula, status: :unverifiable, scope: :none, detail: detail}
end
