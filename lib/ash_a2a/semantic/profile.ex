# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshA2A.Semantic.Profile do
  @moduledoc """
  The five RFC-SA2A-001 v26.9.16 conformance profiles (RFC S59), expressed as
  real, individually-checkable requirement lists rather than as labels.

  A profile here is not a badge and not a doc string: it is an ordered list of
  `t:requirement/0` entries, each of which names a real zero-arity function in
  `AshA2A.Semantic.Conformance` that actually executes against this repo's real
  compiled code and returns `:met`, `{:unmet, detail}`, or
  `{:unverifiable, detail}`. `AshA2A.Semantic.Conformance.requirement_results/0`
  runs every one of them; `mix ash_a2a.verify_conformance` prints the outcome.

  ## The five levels, and that they are cumulative

  Levels are strictly cumulative in the order below: claiming `:sa2a_plan`
  claims every `:sa2a_core` and `:sa2a_logic` requirement as well. Use
  `cumulative_requirements/1` (never `requirements/1`, which returns only the
  requirements a level introduces) whenever the question is "does this system
  conform at level L".

    * `:sa2a_core` -- semantic identity, RDF representation, canonical graph
      identity, public-semantics-first, ShEx, SHACL, SPARQL falsifiers,
      provenance, admission receipts, fail-closed. No DO is required at this
      level: a CORE-conformant system may be read-only.
    * `:sa2a_logic` -- adds Safe Finite Datalog, admitted N3 rules,
      deterministic closure, and rule provenance.
    * `:sa2a_plan` -- adds a planning projection, FOND/HDDL, capability
      preconditions/effects, bounded fan-out, a bounded resource envelope, and
      plan admission.
    * `:sa2a_do` -- adds the Authority Broker, BRCE, prepared receipts,
      execution receipts, reconciliation, and replay evidence.
    * `:sa2a_strict` -- adds no runtime semantic invention, meta-admission, an
      admitted Root Manifest, projected ephemeral software, no LLM authority,
      no LLM on the production DO path, no unbounded production planning loop,
      and explicit finite resource bounds.

  ## What a level's status means (deliberately conservative)

  `AshA2A.Semantic.Conformance.level_status/1` reports a level as conformant
  only when its full cumulative requirement set is `:met` -- an
  `{:unverifiable, _}` requirement blocks conformance exactly as hard as an
  `{:unmet, _}` one does. That is intentional: a requirement nobody can check
  yet is not evidence of conformance, and a conformance story that counts
  unverifiable requirements as satisfied manufactures confidence it has not
  earned. Under-claiming here is recoverable; over-claiming corrupts every
  downstream claim built on it.

  ## See also

    * `AshA2A.Semantic.Conformance` -- the real executable checks and the
      RFC S60 invariants.
    * `Mix.Tasks.AshA2a.VerifyConformance` -- the CI-runnable gate.
    * `AshA2A.ArchitectureVerifier` -- the same "real executable checks, not
      documentation" pattern, applied to architecture invariants instead.
  """

  @typedoc "A conformance profile level, in cumulative order."
  @type level :: :sa2a_core | :sa2a_logic | :sa2a_plan | :sa2a_do | :sa2a_strict

  @typedoc """
  One real, individually-checkable profile requirement.

    * `:id` -- stable atom, unique across all levels.
    * `:level` -- the level that INTRODUCES this requirement.
    * `:title` -- the RFC's own name for it.
    * `:rfc_section` -- the RFC-SA2A-001 section it comes from.
    * `:check` -- `{module, function}` naming a real zero-arity function that
      returns `:met | {:unmet, detail} | {:unverifiable, detail}`.
  """
  @type requirement :: %{
          id: atom(),
          level: level(),
          title: String.t(),
          rfc_section: String.t(),
          check: {module(), atom()}
        }

  @levels [:sa2a_core, :sa2a_logic, :sa2a_plan, :sa2a_do, :sa2a_strict]

  @conformance AshA2A.Semantic.Conformance

  @requirements [
    # -- SA2A-CORE ------------------------------------------------------------
    %{
      id: :semantic_identity,
      level: :sa2a_core,
      title: "Semantic identity is exact, content-derived, and distinct from transport identity",
      rfc_section: "S59/S12",
      check: {@conformance, :check_semantic_identity}
    },
    %{
      id: :rdf_representation,
      level: :sa2a_core,
      title: "Admitted semantics are represented as real RDF triples",
      rfc_section: "S59/S11",
      check: {@conformance, :check_rdf_representation}
    },
    %{
      id: :canonical_graph_identity,
      level: :sa2a_core,
      title: "Graph identity is canonical (injective over distinct RDF graphs)",
      rfc_section: "S59/S12",
      check: {@conformance, :check_canonical_graph_identity}
    },
    %{
      id: :public_semantics_first,
      level: :sa2a_core,
      title: "Public ontology terms are preferred over privately invented ones",
      rfc_section: "S59/S13",
      check: {@conformance, :check_public_semantics_first}
    },
    %{
      id: :shex_validation,
      level: :sa2a_core,
      title: "ShEx shape validation is available and applied to admitted graphs",
      rfc_section: "S59/S14",
      check: {@conformance, :check_shex_validation}
    },
    %{
      id: :shacl_validation,
      level: :sa2a_core,
      title: "SHACL constraint validation is available and applied to admitted graphs",
      rfc_section: "S59/S14",
      check: {@conformance, :check_shacl_validation}
    },
    %{
      id: :sparql_falsifiers,
      level: :sa2a_core,
      title: "SPARQL falsifier queries can be run against admitted graphs",
      rfc_section: "S59/S15",
      check: {@conformance, :check_sparql_falsifiers}
    },
    %{
      id: :provenance,
      level: :sa2a_core,
      title: "Every admitted semantic node carries real provenance to its source",
      rfc_section: "S59/S16",
      check: {@conformance, :check_provenance}
    },
    %{
      id: :admission_receipts,
      level: :sa2a_core,
      title: "Admission decisions produce real, replayable receipts",
      rfc_section: "S59/S17",
      check: {@conformance, :check_admission_receipts}
    },
    %{
      id: :fail_closed,
      level: :sa2a_core,
      title: "Unclassified and unauthorized work is refused, never silently dispatched",
      rfc_section: "S59/S18",
      check: {@conformance, :check_fail_closed}
    },

    # -- SA2A-LOGIC -----------------------------------------------------------
    %{
      id: :safe_finite_datalog,
      level: :sa2a_logic,
      title: "Safe, finite, terminating Datalog evaluation",
      rfc_section: "S59/S20",
      check: {@conformance, :check_safe_finite_datalog}
    },
    %{
      id: :admitted_n3_rules,
      level: :sa2a_logic,
      title: "N3 rules are admitted before they may derive anything",
      rfc_section: "S59/S21",
      check: {@conformance, :check_admitted_n3_rules}
    },
    %{
      id: :deterministic_closure,
      level: :sa2a_logic,
      title: "Rule closure is deterministic and reproducible",
      rfc_section: "S59/S22",
      check: {@conformance, :check_deterministic_closure}
    },
    %{
      id: :rule_provenance,
      level: :sa2a_logic,
      title: "Every derived triple records which rule derived it",
      rfc_section: "S59/S23",
      check: {@conformance, :check_rule_provenance}
    },

    # -- SA2A-PLAN ------------------------------------------------------------
    %{
      id: :planning_projection,
      level: :sa2a_plan,
      title: "A formal planning projection is manufactured from admitted semantics",
      rfc_section: "S59/S30",
      check: {@conformance, :check_planning_projection}
    },
    %{
      id: :fond_hddl,
      level: :sa2a_plan,
      title: "FOND/HDDL planning (nondeterministic effects are expressible)",
      rfc_section: "S59/S31",
      check: {@conformance, :check_fond_hddl}
    },
    %{
      id: :capability_preconditions_effects,
      level: :sa2a_plan,
      title: "Every plannable capability declares real preconditions and effects",
      rfc_section: "S59/S32",
      check: {@conformance, :check_capability_preconditions_effects}
    },
    %{
      id: :bounded_fan_out,
      level: :sa2a_plan,
      title: "Planning fan-out is explicitly bounded",
      rfc_section: "S59/S33",
      check: {@conformance, :check_bounded_fan_out}
    },
    %{
      id: :bounded_resource_envelope,
      level: :sa2a_plan,
      title: "Planning runs inside an explicit finite resource envelope",
      rfc_section: "S59/S34",
      check: {@conformance, :check_bounded_resource_envelope}
    },
    %{
      id: :plan_admission,
      level: :sa2a_plan,
      title: "A plan is admitted before it may be selected",
      rfc_section: "S59/S35",
      check: {@conformance, :check_plan_admission}
    },

    # -- SA2A-DO --------------------------------------------------------------
    %{
      id: :authority_broker,
      level: :sa2a_do,
      title: "A real Authority Broker issues, verifies, and revokes authority",
      rfc_section: "S59/S40",
      check: {@conformance, :check_authority_broker}
    },
    %{
      id: :brce,
      level: :sa2a_do,
      title: "BRCE is the only receipted route to consequence",
      rfc_section: "S59/S41",
      check: {@conformance, :check_brce}
    },
    %{
      id: :prepared_receipts,
      level: :sa2a_do,
      title: "A prepared receipt anchor is persisted before DO",
      rfc_section: "S59/S42",
      check: {@conformance, :check_prepared_receipts}
    },
    %{
      id: :execution_receipts,
      level: :sa2a_do,
      title: "Execution produces a real receipt recording the observed outcome",
      rfc_section: "S59/S43",
      check: {@conformance, :check_execution_receipts}
    },
    %{
      id: :reconciliation,
      level: :sa2a_do,
      title: "Outboxed receipts are reconciled into the primary store",
      rfc_section: "S59/S44",
      check: {@conformance, :check_reconciliation}
    },
    %{
      id: :replay_evidence,
      level: :sa2a_do,
      title: "Replay is distinguished from conflict by real content fingerprint",
      rfc_section: "S59/S45",
      check: {@conformance, :check_replay_evidence}
    },

    # -- SA2A-STRICT ----------------------------------------------------------
    %{
      id: :no_runtime_semantic_invention,
      level: :sa2a_strict,
      title: "No private semantic term is invented at runtime without admission",
      rfc_section: "S59/S50",
      check: {@conformance, :check_no_runtime_semantic_invention}
    },
    %{
      id: :meta_admission,
      level: :sa2a_strict,
      title: "The admission rules themselves are admitted (meta-admission)",
      rfc_section: "S59/S51",
      check: {@conformance, :check_meta_admission}
    },
    %{
      id: :admitted_root_manifest,
      level: :sa2a_strict,
      title: "An admitted Root Manifest pins the whole semantic surface",
      rfc_section: "S59/S52",
      check: {@conformance, :check_admitted_root_manifest}
    },
    %{
      id: :projected_ephemeral_software,
      level: :sa2a_strict,
      title: "Running software is a verified projection of an admitted manufacture",
      rfc_section: "S59/S53",
      check: {@conformance, :check_projected_ephemeral_software}
    },
    %{
      id: :no_llm_authority,
      level: :sa2a_strict,
      title: "LLM output can never carry semantic authority",
      rfc_section: "S59/S54",
      check: {@conformance, :check_no_llm_authority}
    },
    %{
      id: :no_llm_on_production_do_path,
      level: :sa2a_strict,
      title: "No LLM call exists on the production DO path",
      rfc_section: "S59/S55",
      check: {@conformance, :check_no_llm_on_production_do_path}
    },
    %{
      id: :no_unbounded_production_planning_loop,
      level: :sa2a_strict,
      title: "No unbounded planning loop can run in production",
      rfc_section: "S59/S56",
      check: {@conformance, :check_no_unbounded_production_planning_loop}
    },
    %{
      id: :explicit_finite_resource_bounds,
      level: :sa2a_strict,
      title: "Every production loop declares explicit finite resource bounds",
      rfc_section: "S59/S57",
      check: {@conformance, :check_explicit_finite_resource_bounds}
    }
  ]

  @doc "The five profile levels, in cumulative order (weakest first)."
  @spec levels() :: [level()]
  def levels, do: @levels

  @doc "Every requirement across every level, in declaration order."
  @spec requirements() :: [requirement()]
  def requirements, do: @requirements

  @doc """
  Only the requirements a level INTRODUCES.

  For a conformance decision use `cumulative_requirements/1` instead -- levels
  are cumulative, and this function deliberately does not include lower levels.
  """
  @spec requirements(level()) :: [requirement()]
  def requirements(level) when level in @levels,
    do: Enum.filter(@requirements, &(&1.level == level))

  @doc """
  Every requirement a claim at `level` is actually responsible for: this
  level's own requirements plus every lower level's.
  """
  @spec cumulative_requirements(level()) :: [requirement()]
  def cumulative_requirements(level) when level in @levels do
    ceiling = index(level)
    Enum.filter(@requirements, &(index(&1.level) <= ceiling))
  end

  @doc "Fetches one requirement by its stable id."
  @spec fetch(atom()) :: {:ok, requirement()} | :error
  def fetch(id) when is_atom(id) do
    case Enum.find(@requirements, &(&1.id == id)) do
      nil -> :error
      requirement -> {:ok, requirement}
    end
  end

  @doc "Zero-based cumulative position of a level (`:sa2a_core` is 0)."
  @spec index(level()) :: non_neg_integer()
  def index(level) when level in @levels, do: Enum.find_index(@levels, &(&1 == level))

  @doc ~S"""
  The RFC's own spelling of a level.

      iex> AshA2A.Semantic.Profile.label(:sa2a_core)
      "SA2A-CORE"
  """
  @spec label(level()) :: String.t()
  def label(level) when level in @levels do
    level |> Atom.to_string() |> String.upcase() |> String.replace("_", "-", global: false)
  end

  @doc ~S"""
  Parses an RFC-spelled or atom-spelled level name, for CLI arguments.

      iex> AshA2A.Semantic.Profile.parse("SA2A-STRICT")
      {:ok, :sa2a_strict}

      iex> AshA2A.Semantic.Profile.parse("sa2a_do")
      {:ok, :sa2a_do}

      iex> AshA2A.Semantic.Profile.parse("sa2a-turbo")
      :error
  """
  @spec parse(String.t() | level()) :: {:ok, level()} | :error
  def parse(level) when level in @levels, do: {:ok, level}

  def parse(value) when is_binary(value) do
    normalized = value |> String.downcase() |> String.replace("-", "_")
    Enum.find_value(@levels, :error, &if(Atom.to_string(&1) == normalized, do: {:ok, &1}))
  end

  def parse(_), do: :error
end
