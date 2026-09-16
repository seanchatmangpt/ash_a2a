defmodule AshA2A.Semantic.AgentCard do
  @moduledoc """
  RFC-SA2A-001 S10 -- a semantic capability declaration.

  ## A declaration is not a grant

  This is the single most important property of this struct and it is
  enforced, not merely stated. A `%AshA2A.Semantic.AgentCard{}` says
  "machinery exists here with this shape". It says nothing about whether the
  reader may invoke it. `grant?/1` returns `false` unconditionally,
  `standing/1` returns `:declaration`, and the struct carries no authority
  token, no capability handle and no credential of any kind. A peer that
  reads a declaration and proceeds to act has not been authorized by this
  module -- `AshA2A.Authority` and `AshA2A.CommandBus` are the only things
  that authorize anything, and neither consults this struct.

  `authority_requirement` states what a caller would need. Stating a
  requirement is the opposite of satisfying it.

  ## Derivation, not a parallel registry

  Every field that can be derived is derived from the real compiled
  `AshA2A.CapabilityIndex` (which is itself derived from
  `Ash.Resource.Info.public_actions/1`). `from_capability_index/2` takes real
  `AshA2A.Skill` structs -- the same ones `AshA2A.Info.agent_card/2` projects
  onto the wire card -- so a semantic declaration and an A2A skill can never
  drift apart by construction. There is no second hand-authored capability
  model here.

  ## The declared properties

    * `capability_iri` -- stable IRI identity, derived from the canonical
      `{resource, action}` capability id.
    * `input_shape` / `output_shape` -- SHACL shape IRIs naming the shapes a
      caller's input graph and this capability's output graph are expected
      to satisfy. Shapes are *named* here and *checked* by GraphLaw; this
      module never validates anything itself.
    * `preconditions` / `effects` -- HDDL-shaped predicate terms, carried
      through from real declared `AshA2A.HddlOperator` entries where present.
    * `consequence_class` -- the real `AshA2A.Skill.consequence` value
      (`:observe` / `:change` / `:external_do` / `:unknown`). Never guessed.
    * `authority_requirement` -- what a caller would have to hold. `:none`
      for `:observe`; `:command_bus_admission` for everything consequence-
      bearing; `:unclassified` for `:unknown`, which fails closed downstream.
    * `receipt_class` -- what a real execution would emit: `:none` for an
      observation, `:command_receipt` for a consequence.
    * `planner_compatibility` -- which planners can consume this capability;
      `[:hddl]` only when real HDDL operators are declared.
    * `cost_envelope` -- declared resource bound. `:unbounded` when no real
      bound was declared, rather than a fabricated number.
    * `semantic_basis` -- what the declaration is grounded in. Here:
      canonical Ash introspection.
    * `version` -- the profile version this declaration was cut against.
  """

  alias AshA2A.CapabilityIndex.Compiler
  alias AshA2A.Semantic.Extension

  @enforce_keys [
    :capability_iri,
    :input_shape,
    :output_shape,
    :preconditions,
    :effects,
    :consequence_class,
    :authority_requirement,
    :receipt_class,
    :planner_compatibility,
    :cost_envelope,
    :semantic_basis,
    :version
  ]
  defstruct [
    :capability_iri,
    :input_shape,
    :output_shape,
    :preconditions,
    :effects,
    :consequence_class,
    :authority_requirement,
    :receipt_class,
    :planner_compatibility,
    :cost_envelope,
    :semantic_basis,
    :version
  ]

  @type authority_requirement :: :none | :command_bus_admission | :unclassified
  @type receipt_class :: :none | :command_receipt

  @type t :: %__MODULE__{
          capability_iri: String.t(),
          input_shape: String.t(),
          output_shape: String.t(),
          preconditions: [String.t()],
          effects: [String.t()],
          consequence_class: AshA2A.Skill.consequence(),
          authority_requirement: authority_requirement(),
          receipt_class: receipt_class(),
          planner_compatibility: [atom()],
          cost_envelope: :unbounded | %{optional(atom()) => term()},
          semantic_basis: String.t(),
          version: String.t()
        }

  @iri_base "urn:sa2a:capability:"
  @shape_base "urn:sa2a:shape:"

  @doc """
  Builds semantic declarations for every capability of a real resource or
  domain carrying the `AshA2A` extension.

  Derives from `AshA2A.Info.capability_index/1`. Returns `[]` when the module
  has no compiled index rather than raising, so a peer probing an ordinary
  A2A agent gets an empty declaration set instead of an exception.

  The Spark guard is load-bearing, not defensive decoration:
  `AshA2A.Info.capability_index/1` reaches
  `Spark.Dsl.Extension.persisted!/3`, which raises `ArgumentError` for a
  module that is not a Spark DSL module at all -- measured, not assumed
  (`test/ash_a2a_semantic_agent_card_test.exs` asserts the `[]` result this
  guard produces).
  """
  @spec for_subject(module()) :: [t()]
  def for_subject(resource_or_domain) do
    if spark_dsl?(resource_or_domain) do
      resource_or_domain
      |> AshA2A.Info.capability_index()
      |> List.wrap()
      |> from_capability_index()
    else
      []
    end
  end

  defp spark_dsl?(module) when is_atom(module) do
    Code.ensure_loaded?(module) and function_exported?(module, :spark_dsl_config, 0)
  end

  defp spark_dsl?(_), do: false

  @doc "Projects real compiled `AshA2A.Skill` structs into declarations."
  @spec from_capability_index([AshA2A.Skill.t()], keyword()) :: [t()]
  def from_capability_index(skills, opts \\ []) when is_list(skills) do
    skills
    |> Enum.map(&from_skill(&1, opts))
    |> Enum.sort_by(& &1.capability_iri)
  end

  @doc "Projects one real compiled `AshA2A.Skill` into a declaration."
  @spec from_skill(AshA2A.Skill.t(), keyword()) :: t()
  def from_skill(%AshA2A.Skill{} = skill, opts \\ []) do
    id = skill.id || Compiler.capability_id(skill.resource, skill.action)
    consequence = skill.consequence || :unknown
    operators = List.wrap(skill.hddl_operators)

    %__MODULE__{
      capability_iri: capability_iri(id),
      input_shape: shape_iri(id, "input"),
      output_shape: shape_iri(id, "output"),
      preconditions: operator_terms(operators, [:preconditions]),
      effects: operator_terms(operators, [:add_effects, :delete_effects]),
      consequence_class: consequence,
      authority_requirement: authority_requirement(consequence),
      receipt_class: receipt_class(consequence),
      planner_compatibility: planner_compatibility(operators),
      cost_envelope: Keyword.get(opts, :cost_envelope, :unbounded),
      semantic_basis: "ash:public_actions via AshA2A.CapabilityIndex.Compiler",
      version: Keyword.get(opts, :version, Extension.profile_version())
    }
  end

  @doc """
  A declaration never grants anything. Always `false`.

  Present as a real function rather than a sentence in a moduledoc so a
  caller can assert on it and a reader can grep for it.
  """
  @spec grant?(t()) :: false
  def grant?(%__MODULE__{}), do: false

  @doc "The standing a declaration carries: `:declaration`. Never `:admitted`."
  @spec standing(t()) :: :declaration
  def standing(%__MODULE__{}), do: :declaration

  @doc """
  Deterministic RDF projection of a declaration, as Turtle.

  This is what crosses the wire and what a peer's GraphLaw engine actually
  reads. Terms are emitted in a fixed field order so the Turtle text is
  byte-stable for a given declaration; graph identity itself is GraphLaw's
  job (`graph_hash/1`), not this function's.
  """
  @spec to_turtle([t()] | t()) :: String.t()
  def to_turtle(%__MODULE__{} = declaration), do: to_turtle([declaration])

  def to_turtle(declarations) when is_list(declarations) do
    body =
      declarations
      |> Enum.sort_by(& &1.capability_iri)
      |> Enum.map_join("\n", &declaration_turtle/1)

    """
    @prefix sa2a: <urn:sa2a:vocab#> .
    @prefix rdf: <http://www.w3.org/1999/02/22-rdf-syntax-ns#> .

    #{body}
    """
  end

  defp declaration_turtle(%__MODULE__{} = declaration) do
    lines =
      [
        {"sa2a:inputShape", "<#{declaration.input_shape}>"},
        {"sa2a:outputShape", "<#{declaration.output_shape}>"},
        {"sa2a:consequenceClass", quoted(declaration.consequence_class)},
        {"sa2a:authorityRequirement", quoted(declaration.authority_requirement)},
        {"sa2a:receiptClass", quoted(declaration.receipt_class)},
        {"sa2a:semanticBasis", quoted(declaration.semantic_basis)},
        {"sa2a:version", quoted(declaration.version)},
        {"sa2a:costEnvelope", quoted(declaration.cost_envelope)},
        {"sa2a:grantsAuthority", "false"}
      ] ++
        Enum.map(declaration.preconditions, &{"sa2a:precondition", quoted(&1)}) ++
        Enum.map(declaration.effects, &{"sa2a:effect", quoted(&1)}) ++
        Enum.map(declaration.planner_compatibility, &{"sa2a:plannerCompatibility", quoted(&1)})

    predicates = Enum.map_join(lines, " ;\n", fn {p, o} -> "  #{p} #{o}" end)

    "<#{declaration.capability_iri}> rdf:type sa2a:CapabilityDeclaration ;\n#{predicates} .\n"
  end

  defp quoted(value) do
    escaped =
      value
      |> to_string()
      |> String.replace("\\", "\\\\")
      |> String.replace("\"", "\\\"")
      |> String.replace("\n", "\\n")

    "\"#{escaped}\""
  end

  defp capability_iri(id), do: @iri_base <> slug(id)
  defp shape_iri(id, kind), do: @shape_base <> slug(id) <> ":" <> kind

  defp slug(value) do
    value |> to_string() |> String.replace(~r/[^A-Za-z0-9_.:-]+/u, "_")
  end

  # `:observe` needs no authority: it never reaches the CommandBus DO
  # boundary. `:unknown` is deliberately NOT mapped to `:none` -- an
  # unclassified generic action must never become the route by which a real
  # consequence bypasses admission (see `AshA2A.Skill`'s own @moduledoc).
  defp authority_requirement(:observe), do: :none
  defp authority_requirement(:change), do: :command_bus_admission
  defp authority_requirement(:external_do), do: :command_bus_admission
  defp authority_requirement(_), do: :unclassified

  defp receipt_class(:observe), do: :none
  defp receipt_class(:change), do: :command_receipt
  defp receipt_class(:external_do), do: :command_receipt
  defp receipt_class(_), do: :command_receipt

  defp planner_compatibility([]), do: []
  defp planner_compatibility(_operators), do: [:hddl]

  # `AshA2A.HddlOperator` carries `preconditions`, `add_effects` and
  # `delete_effects` as real `{predicate, args}` fact tuples. Effects are the
  # union of add and delete; the sign is preserved in the rendered term so a
  # planner reading the declaration can tell them apart.
  defp operator_terms(operators, fields) do
    fields
    |> Enum.flat_map(fn field ->
      operators
      |> Enum.flat_map(fn operator -> operator |> Map.get(field, []) |> List.wrap() end)
      |> Enum.map(&term_to_string(&1, field))
    end)
    |> Enum.uniq()
    |> Enum.sort()
  end

  defp term_to_string(term, field) do
    prefix = if field == :delete_effects, do: "not ", else: ""
    prefix <> fact_to_string(term)
  end

  defp fact_to_string({predicate, args}) when is_atom(predicate) and is_list(args),
    do: "(#{predicate}#{Enum.map_join(args, "", fn arg -> " #{arg}" end)})"

  defp fact_to_string(term) when is_binary(term), do: term
  defp fact_to_string(term) when is_atom(term), do: to_string(term)
  defp fact_to_string(term), do: inspect(term)
end
