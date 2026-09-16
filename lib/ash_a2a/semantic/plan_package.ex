defmodule AshA2A.Semantic.PlanPackage do
  @moduledoc """
  The Plan Package (RFC-SA2A-001 S24) -- the complete, digest-identified
  planning artifact a conforming runtime exchanges.

  ## Construction is gated on S23, structurally

  `from_projection/3` is the only constructor. It takes an
  `AshA2A.Semantic.PlanProjection`, which itself can only be built from an
  admitted `PlanningIR` + admitted `Ontology` pair
  (`PlanProjection.from_admitted/2`). There is deliberately no
  `new/1`-from-a-map. A `%PlanPackage{}` existing therefore carries the
  whole chain as evidence: admitted semantics -> derived projection ->
  package. RFC S23's "a conforming planner operates ONLY over admitted
  planning objects" is enforced by the type of the argument, not by a
  comment.

  `from_projection/3` also re-runs `PlanProjection.verify_self/1` before
  accepting the projection, so a projection that was hand-edited between
  being derived and being packaged (the S27 case) cannot be laundered into
  a package.

  ## Profiles: `:strict` rejects a plan missing PRODUCTION bounds

  RFC S24's hard rule. The bounds below are required under
  `profile: :strict`; a package missing any of them is refused with
  `:plan_package_production_bounds_missing`, whose `detail.missing` names
  every absent field (all of them, not just the first -- a caller fixing a
  plan should not have to iterate one refusal at a time).

  #{Enum.map_join([:max_fan_out, :max_depth, :max_parallelism, :resource_envelope, :consequence_class, :required_capabilities, :authority_requirements, :receipt_obligations], "\n", &"    * `#{&1}`")}

  Under `profile: :permissive` those fields may be `nil` -- that profile
  exists for draft/exploratory planning that is explicitly never eligible
  for a production DO. A permissive package records `profile: :permissive`
  in its own digested content, so a permissive package and a strict package
  that happen to agree on every other field still have **different plan
  digests**. A permissive plan can never be mistaken for, or replayed as, a
  strict one.

  `resource_envelope` is additionally structurally checked under strict:
  it must be a map carrying non-nil `#{inspect([:max_wall_ms, :max_memory_bytes, :max_invocations])}`.
  A present-but-empty envelope is not a bound.

  ## A bound is its CONTENTS, not its container

  Presence alone is not a bound. `[nil]` is a one-element list, so a
  container-only test ("is it non-empty?") accepts it while correctly
  rejecting `[]` -- a plan declaring one nil capability would clear a
  gate a plan declaring no capabilities fails. `enforce_profile/1`
  therefore validates the *contents* of every list-shaped and
  atom-shaped production bound and refuses with
  `:plan_package_bound_contents_invalid`:

    * `required_capabilities` -- every element a non-empty binary
    * `authority_requirements` -- every element a non-empty map
    * `receipt_obligations` -- every element an atom other than `nil`,
      `true`, or `false`
    * `consequence_class` -- an atom other than `nil`/`true`/`false`

  The four ceiling bounds (`max_fan_out`, `max_depth`, `max_parallelism`,
  `resource_envelope`) already validated their contents via
  `positive_bounds/1` and `envelope/1` and are unchanged.

  ## Authority

  `standing: :candidate, authority: :none`, unconditionally -- the same
  fence `AshA2A.Planning.candidate_fence/1` applies to every plan candidate.
  `authority_requirements` is a *statement of what would be required*, never
  a grant. A plan package cannot be presented to `AshA2A.CommandBus` in
  place of an `AshA2A.Authority`; see `AshA2A.Semantic.CapabilityComposition`
  for the composition-time version of the same rule.

  ## Plan digest

  `plan_digest` is a `AshA2A.Semantic.CanonicalDigest` over every content
  field (everything except the digest itself). It is a value-level digest:
  two packages built in different processes, with map fields inserted in
  different orders, digest identically.

  `:standing` and `:authority` -- the two fields that *assert* the
  plan-is-not-authority fence -- are content fields like any other. They
  have to be: leaving the fence out of the digest that the tamper check
  (`verify/1`) is computed over would make the fence the one part of the
  package an editor could rewrite without detection. With them included,
  `%{package | standing: :admitted, authority: :full}` fails `verify/1`
  with `:plan_package_manual_edit_not_canonical`.
  """

  alias AshA2A.Semantic.{CanonicalDigest, PlanProjection}

  @enforce_keys [
    :semantic_goal,
    :initial_state_identity,
    :planning_domain_identity,
    :planner_identity,
    :source_graph_digest,
    :projection_digest,
    :plan_digest
  ]
  defstruct [
    :semantic_goal,
    :initial_state_identity,
    :planning_domain_identity,
    :planner_identity,
    :source_graph_digest,
    :projection_digest,
    :plan_digest,
    :consequence_class,
    :max_fan_out,
    :max_depth,
    :max_parallelism,
    :resource_envelope,
    profile: :strict,
    method_identities: [],
    action_identities: [],
    preconditions: [],
    effects: [],
    nondeterministic_outcomes: [],
    required_capabilities: [],
    authority_requirements: [],
    receipt_obligations: [],
    standing: :candidate,
    authority: :none
  ]

  @type profile :: :strict | :permissive

  @typedoc """
  The `AshA2A.HddlOperator.fact()` shape, reused rather than re-invented:
  `{predicate, args}`. `AshA2A.Planning.HddlRenderer` already renders exactly
  this shape to real HDDL, so a package's preconditions/effects are directly
  renderable without translation.
  """
  @type fact :: {atom() | String.t(), [atom() | String.t()]}

  @type resource_envelope :: %{
          optional(:max_wall_ms) => pos_integer() | nil,
          optional(:max_memory_bytes) => pos_integer() | nil,
          optional(:max_invocations) => pos_integer() | nil
        }

  @type t :: %__MODULE__{
          semantic_goal: String.t(),
          initial_state_identity: String.t(),
          planning_domain_identity: String.t(),
          planner_identity: String.t(),
          source_graph_digest: String.t(),
          projection_digest: String.t(),
          plan_digest: String.t(),
          consequence_class: AshA2A.Skill.consequence() | nil,
          max_fan_out: pos_integer() | nil,
          max_depth: pos_integer() | nil,
          max_parallelism: pos_integer() | nil,
          resource_envelope: resource_envelope() | nil,
          profile: profile(),
          method_identities: [String.t()],
          action_identities: [String.t()],
          preconditions: [fact()],
          effects: [fact()],
          nondeterministic_outcomes: [map()],
          required_capabilities: [String.t()],
          authority_requirements: [map()],
          receipt_obligations: [atom()],
          standing: :candidate,
          authority: :none
        }

  @type refusal :: {:error, %{code: atom(), detail: term()}}

  @production_bounds [
    :max_fan_out,
    :max_depth,
    :max_parallelism,
    :resource_envelope,
    :consequence_class,
    :required_capabilities,
    :authority_requirements,
    :receipt_obligations
  ]

  @required_envelope_keys [:max_wall_ms, :max_memory_bytes, :max_invocations]

  @content_fields [
    :semantic_goal,
    :initial_state_identity,
    :planning_domain_identity,
    :planner_identity,
    :source_graph_digest,
    :projection_digest,
    :consequence_class,
    :max_fan_out,
    :max_depth,
    :max_parallelism,
    :resource_envelope,
    :profile,
    :method_identities,
    :action_identities,
    :preconditions,
    :effects,
    :nondeterministic_outcomes,
    :required_capabilities,
    :authority_requirements,
    :receipt_obligations,
    :standing,
    :authority
  ]

  @doc "The exact fields `:strict` requires. Public so a test names them once."
  @spec production_bounds() :: [atom()]
  def production_bounds, do: @production_bounds

  @doc "The keys a strict `resource_envelope` must carry non-nil."
  @spec required_envelope_keys() :: [atom()]
  def required_envelope_keys, do: @required_envelope_keys

  @doc """
  Builds a plan package from a derived projection.

  `planner_identity` is the planner that produced the plan body (for the
  real HDDL path: `"hddl_cli"` plus its version, not the string `"planner"`).

  `opts` supplies the plan body and the bounds:

    * `:profile` -- `:strict` (default) or `:permissive`
    * `:planning_domain_identity` -- defaults to the projection's
      `source_graph_digest`; override when the planning domain is a distinct
      named artifact (an HDDL domain file digest, say)
    * `:method_identities`, `:action_identities` -- `[String.t()]`
    * `:preconditions`, `:effects` -- `[fact()]`
    * `:nondeterministic_outcomes` -- `[map()]`, "where applicable": a fully
      deterministic plan legitimately leaves this `[]`, which is why it is
      not in `production_bounds/0`
    * `:consequence_class` -- `AshA2A.Skill.consequence()`
    * `:required_capabilities` -- `[String.t()]` canonical capability ids
    * `:max_fan_out`, `:max_depth`, `:max_parallelism` -- `pos_integer()`
    * `:resource_envelope` -- map, see `required_envelope_keys/0`
    * `:authority_requirements` -- `[map()]`
    * `:receipt_obligations` -- `[atom()]`

  Refusals: `:plan_package_projection_unverifiable` (the projection failed
  its own S27 self-check; detail carries the projection refusal),
  `:plan_package_semantic_goal_missing` (the projection has no goal to
  package), `:plan_package_production_bounds_missing`,
  `:plan_package_bound_contents_invalid` (a bound present as a non-empty
  container whose *elements* are not real bounds -- `[nil]`),
  `:plan_package_resource_envelope_incomplete`,
  `:plan_package_invalid_bound` (a bound present but not a positive
  integer).
  """
  @spec from_projection(PlanProjection.t(), String.t(), keyword()) :: {:ok, t()} | refusal()
  def from_projection(%PlanProjection{} = projection, planner_identity, opts \\ [])
      when is_binary(planner_identity) and is_list(opts) do
    profile = Keyword.get(opts, :profile, :strict)

    with {:ok, projection} <- verify_projection(projection),
         {:ok, goal} <- semantic_goal(projection) do
      package = build(projection, planner_identity, goal, profile, opts)

      with :ok <- enforce_profile(package) do
        {:ok, %{package | plan_digest: content_digest(package)}}
      end
    end
  end

  @doc """
  Recomputes the package's content digest. Same tamper-check role
  `PlanProjection.content_digest/1` plays: a package whose recomputed digest
  disagrees with its recorded `plan_digest` was edited after manufacture.
  """
  @spec content_digest(t()) :: String.t()
  def content_digest(%__MODULE__{} = package) do
    package
    |> Map.take(@content_fields)
    |> CanonicalDigest.digest()
  end

  @doc """
  `{:ok, package}` iff `plan_digest` still matches the package's content,
  else `:plan_package_manual_edit_not_canonical`.
  """
  @spec verify(t()) :: {:ok, t()} | refusal()
  def verify(%__MODULE__{} = package) do
    recomputed = content_digest(package)

    if recomputed == package.plan_digest do
      {:ok, package}
    else
      error(:plan_package_manual_edit_not_canonical, %{
        recorded: package.plan_digest,
        recomputed: recomputed
      })
    end
  end

  @doc """
  Re-runs the profile gate against an already-built package.

  Separate from `from_projection/3` so a receiving runtime can apply *its
  own* profile to a package built elsewhere: a package manufactured under
  `:permissive` is refused by a strict receiver via
  `enforce_profile(%{package | profile: :strict})`, without that receiver
  having to rebuild the plan.
  """
  @spec enforce_profile(t()) :: :ok | refusal()
  def enforce_profile(%__MODULE__{profile: :permissive}), do: :ok

  def enforce_profile(%__MODULE__{profile: :strict} = package) do
    missing = Enum.filter(@production_bounds, &blank?(Map.fetch!(package, &1)))

    if missing == [] do
      with :ok <- bound_contents(package),
           :ok <- positive_bounds(package) do
        envelope(package.resource_envelope)
      end
    else
      error(:plan_package_production_bounds_missing, %{missing: missing, profile: :strict})
    end
  end

  def enforce_profile(%__MODULE__{profile: other}),
    do: error(:plan_package_unknown_profile, other)

  defp build(projection, planner_identity, goal, profile, opts) do
    %__MODULE__{
      semantic_goal: goal,
      initial_state_identity: projection.planning_ir_fingerprint,
      planning_domain_identity:
        Keyword.get(opts, :planning_domain_identity, projection.source_graph_digest),
      planner_identity: planner_identity,
      source_graph_digest: projection.source_graph_digest,
      projection_digest: projection.projection_digest,
      profile: profile,
      consequence_class: Keyword.get(opts, :consequence_class),
      method_identities: Keyword.get(opts, :method_identities, []),
      action_identities: Keyword.get(opts, :action_identities, []),
      preconditions: Keyword.get(opts, :preconditions, []),
      effects: Keyword.get(opts, :effects, []),
      nondeterministic_outcomes: Keyword.get(opts, :nondeterministic_outcomes, []),
      required_capabilities: Keyword.get(opts, :required_capabilities, []),
      max_fan_out: Keyword.get(opts, :max_fan_out),
      max_depth: Keyword.get(opts, :max_depth),
      max_parallelism: Keyword.get(opts, :max_parallelism),
      resource_envelope: Keyword.get(opts, :resource_envelope),
      authority_requirements: Keyword.get(opts, :authority_requirements, []),
      receipt_obligations: Keyword.get(opts, :receipt_obligations, []),
      plan_digest: "pending"
    }
  end

  defp verify_projection(projection) do
    case PlanProjection.verify_self(projection) do
      {:ok, projection} -> {:ok, projection}
      {:error, detail} -> error(:plan_package_projection_unverifiable, detail)
    end
  end

  defp semantic_goal(%PlanProjection{goals: [goal | _]}) when is_binary(goal) and goal != "",
    do: {:ok, goal}

  defp semantic_goal(_projection), do: error(:plan_package_semantic_goal_missing)

  # A bound is its contents. `blank?/1` above only rules out an empty
  # container; `[nil]` is a non-empty container holding nothing, and a
  # plan declaring one nil capability must not clear a gate that a plan
  # declaring no capabilities fails.
  defp bound_contents(package) do
    invalid =
      Enum.reject(
        [
          {:consequence_class, real_atom?(package.consequence_class)},
          {:required_capabilities,
           every?(package.required_capabilities, &(is_binary(&1) and &1 != ""))},
          {:authority_requirements,
           every?(package.authority_requirements, &(is_map(&1) and map_size(&1) > 0))},
          {:receipt_obligations, every?(package.receipt_obligations, &real_atom?/1)}
        ],
        fn {_field, valid?} -> valid? end
      )

    case invalid do
      [] ->
        :ok

      _ ->
        error(:plan_package_bound_contents_invalid, %{
          fields: Enum.map(invalid, fn {field, _} -> field end),
          detail: "a bound is its contents, not its container: an element-level check failed"
        })
    end
  end

  defp every?(list, predicate) when is_list(list), do: Enum.all?(list, predicate)
  defp every?(_other, _predicate), do: false

  defp real_atom?(value) when value in [nil, true, false], do: false
  defp real_atom?(value), do: is_atom(value)

  defp positive_bounds(package) do
    bad =
      [:max_fan_out, :max_depth, :max_parallelism]
      |> Enum.reject(fn field ->
        value = Map.fetch!(package, field)
        is_integer(value) and value > 0
      end)

    if bad == [], do: :ok, else: error(:plan_package_invalid_bound, %{fields: bad})
  end

  defp envelope(envelope) when is_map(envelope) do
    missing =
      Enum.filter(@required_envelope_keys, fn key ->
        value = Map.get(envelope, key)
        not (is_integer(value) and value > 0)
      end)

    if missing == [] do
      :ok
    else
      error(:plan_package_resource_envelope_incomplete, %{missing: missing})
    end
  end

  defp envelope(other), do: error(:plan_package_resource_envelope_incomplete, %{value: other})

  # `nil` and `[]` are both "absent" for bound purposes: an empty
  # `required_capabilities`/`authority_requirements`/`receipt_obligations`
  # list under strict means the plan declared no capability, no authority
  # requirement, and no receipt obligation -- which is exactly the unbounded
  # plan the strict profile exists to reject, not a satisfied bound.
  defp blank?(nil), do: true
  defp blank?([]), do: true
  defp blank?(map) when is_map(map) and map_size(map) == 0, do: true
  defp blank?(""), do: true
  defp blank?(_value), do: false

  defp error(code, detail \\ nil), do: {:error, %{code: code, detail: detail}}
end
