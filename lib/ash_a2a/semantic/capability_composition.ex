defmodule AshA2A.Semantic.CapabilityProfile do
  @moduledoc """
  The composition-relevant face of one capability (RFC-SA2A-001 S48).

  Reuses `AshA2A.HddlOperator`'s own `{predicate, args}` STRIPS fact shape
  rather than introducing a second one, so a profile can be built directly
  from a compiled `AshA2A.Skill`'s real `hddl_operators` (see
  `AshA2A.Semantic.CapabilityComposition.from_hddl_operator/3`) with no
  translation layer.

  `authority_requirement` is a plain map describing what executing this
  capability would require. It is a *description*, never a grant -- the same
  distinction `AshA2A.Semantic.Admission` already enforces for
  `:authorities` items, whose `mode` must be `"described"`/`"denied"`/
  `"unknown"` and can never be an admitted grant.
  """

  @enforce_keys [:capability_id]
  defstruct [
    :capability_id,
    :consequence,
    preconditions: [],
    add_effects: [],
    delete_effects: [],
    authority_requirement: %{}
  ]

  @type fact :: {atom() | String.t(), [atom() | String.t()]}

  @type t :: %__MODULE__{
          capability_id: String.t(),
          consequence: AshA2A.Skill.consequence() | nil,
          preconditions: [fact()],
          add_effects: [fact()],
          delete_effects: [fact()],
          authority_requirement: map()
        }
end

defmodule AshA2A.Semantic.Composition do
  @moduledoc """
  A lawful two-capability composition (RFC-SA2A-001 S48).

  `authority_requirements` is a map keyed by `capability_id`, holding each
  participant's own requirement **verbatim**. There is deliberately no
  aggregate/rolled-up authority field on this struct: there is no such thing
  as "the composition's authority". Composing c1 and c2 produces something
  whose execution still requires c1's authority for c1's step and c2's
  authority for c2's step, separately, at the moment each step is actually
  presented to `AshA2A.CommandBus`.

  `standing: :candidate, authority: :none`.
  """

  @enforce_keys [:left, :right, :authority_requirements, :resulting_state, :composition_digest]
  defstruct [
    :left,
    :right,
    :authority_requirements,
    :resulting_state,
    :composition_digest,
    consequence_classes: %{},
    standing: :candidate,
    authority: :none
  ]

  @type t :: %__MODULE__{
          left: String.t(),
          right: String.t(),
          authority_requirements: %{String.t() => map()},
          resulting_state: [AshA2A.Semantic.CapabilityProfile.fact()],
          composition_digest: String.t(),
          consequence_classes: %{String.t() => AshA2A.Skill.consequence() | nil},
          standing: :candidate,
          authority: :none
        }
end

defmodule AshA2A.Semantic.CapabilityComposition do
  @moduledoc """
  Capability composition (RFC-SA2A-001 S48).

  > Capabilities compose when `Effects(c1)` entails `Preconditions(c2)`.
  > Authority requirements remain INDEPENDENT -- composing two capabilities
  > MUST NOT raise either participant's authority ceiling.

  ## The entailment rule, concretely

  `Effects(c1)` is evaluated as a real STRIPS state transform:

      state' = (state ∪ add_effects(c1)) \\ delete_effects(c1)

  and `Effects(c1)` entails `Preconditions(c2)` iff every fact in
  `preconditions(c2)` is a member of `state'`.

  `state` defaults to `[]`, which is the strict reading of S48: c1's effects
  **alone** must establish c2's preconditions, with no help from an ambient
  world. `compose/3`'s `:initial_state` option supplies a real prior state
  for the weaker, frame-aware reading; the option exists because both
  readings are legitimately used (a planner chaining steps mid-plan has a
  real prior state), but the default is the strict one, so the permissive
  reading is always an explicit choice at the call site.

  Delete effects are honored, and honored *after* adds, so a c1 that both
  adds and deletes the same fact does not spuriously satisfy c2 -- see
  `test/ash_a2a/semantic/capability_composition_test.exs`.

  ## Fact normalization

  A fact's predicate and args are compared as strings, so `{:at, [:room_a]}`
  (the atom shape `AshA2A.HddlOperator` declares in the DSL) and
  `{"at", ["room_a"]}` (the string shape arriving over the A2A wire) are the
  same fact. Without this, a composition that is lawful in the DSL would be
  refused across the wire purely on term representation.

  ## The authority rule, enforced not asserted

  `compose/3` returns `authority_requirements` as a per-participant map
  holding each side's requirement byte-for-byte as declared. Two real
  checks back this:

    * `raises_ceiling?/2` compares a composition's recorded requirement for
      each participant against that participant's own declared requirement
      and returns the participants whose requirement differs. A conforming
      composition returns `[]`.
    * `compose/3` itself refuses with `:composition_authority_ceiling_raised`
      if the requirement it is about to record differs from either
      participant's declaration -- so the invariant is checked on the
      construction path, not only by an external auditor who might not run.

  The consequence classes are likewise kept per-participant
  (`consequence_classes`) rather than rolled up: composing an `:observe`
  with an `:external_do` does not make the pair "mostly observe", and does
  not make the observe step consequence-bearing either.
  """

  alias AshA2A.Semantic.{CanonicalTermDigest, CapabilityProfile, Composition}

  @type fact :: CapabilityProfile.fact()
  @type refusal :: {:error, %{code: atom(), detail: term()}}

  @doc """
  Builds a `CapabilityProfile` from a real compiled `AshA2A.Skill` and one
  of its declared `AshA2A.HddlOperator` entries.

  No translation of the fact shape is performed -- `HddlOperator`'s
  `preconditions`/`add_effects`/`delete_effects` are already the
  `{predicate, args}` tuples this module compares.
  """
  @spec from_hddl_operator(AshA2A.Skill.t(), AshA2A.HddlOperator.t(), keyword()) ::
          CapabilityProfile.t()
  def from_hddl_operator(%AshA2A.Skill{} = skill, %AshA2A.HddlOperator{} = operator, opts \\ []) do
    %CapabilityProfile{
      capability_id: skill.id,
      consequence: skill.consequence,
      preconditions: operator.preconditions,
      add_effects: operator.add_effects,
      delete_effects: operator.delete_effects,
      authority_requirement: Keyword.get(opts, :authority_requirement, %{})
    }
  end

  @doc """
  The real STRIPS transform: `(state ∪ add) \\ delete`, normalized.

  Returns a sorted list of normalized `{predicate, args}` facts so the
  result is deterministic and directly digestible.
  """
  @spec apply_effects([fact()], CapabilityProfile.t()) :: [fact()]
  def apply_effects(state, %CapabilityProfile{} = profile) do
    deletes = MapSet.new(profile.delete_effects, &normalize/1)

    state
    |> MapSet.new(&normalize/1)
    |> MapSet.union(MapSet.new(profile.add_effects, &normalize/1))
    |> MapSet.difference(deletes)
    |> MapSet.to_list()
    |> Enum.sort()
  end

  @doc """
  `true` iff every fact in `preconditions` holds in `state`, after
  normalization.
  """
  @spec entails?([fact()], [fact()]) :: boolean()
  def entails?(state, preconditions) do
    held = MapSet.new(state, &normalize/1)
    Enum.all?(preconditions, &MapSet.member?(held, normalize(&1)))
  end

  @doc """
  Facts in `preconditions` that `state` does not establish -- the detail a
  `:composition_preconditions_unmet` refusal carries.
  """
  @spec unmet([fact()], [fact()]) :: [fact()]
  def unmet(state, preconditions) do
    held = MapSet.new(state, &normalize/1)

    preconditions
    |> Enum.map(&normalize/1)
    |> Enum.reject(&MapSet.member?(held, &1))
    |> Enum.uniq()
    |> Enum.sort()
  end

  @doc """
  Composes `left` then `right`, iff `Effects(left)` entails
  `Preconditions(right)`.

  `opts`:

    * `:initial_state` -- `[fact()]`, default `[]` (the strict S48 reading)

  Refusals:

    * `:composition_preconditions_unmet` -- detail carries `:unmet`, the
      exact facts `right` needed that `left` did not establish, plus the
      `:resulting_state` it did establish
    * `:composition_self_composition` -- `left.capability_id ==
      right.capability_id`; composing a capability with itself is not a
      two-participant composition and its authority accounting is
      degenerate
    * `:composition_authority_ceiling_raised` -- the construction-path
      version of `raises_ceiling?/2`
  """
  @spec compose(CapabilityProfile.t(), CapabilityProfile.t(), keyword()) ::
          {:ok, Composition.t()} | refusal()
  def compose(%CapabilityProfile{} = left, %CapabilityProfile{} = right, opts \\ []) do
    initial_state = Keyword.get(opts, :initial_state, [])

    with :ok <- distinct(left, right) do
      after_left = apply_effects(initial_state, left)

      case unmet(after_left, right.preconditions) do
        [] ->
          resulting_state = apply_effects(after_left, right)

          authority_requirements = %{
            left.capability_id => left.authority_requirement,
            right.capability_id => right.authority_requirement
          }

          composition = %Composition{
            left: left.capability_id,
            right: right.capability_id,
            authority_requirements: authority_requirements,
            consequence_classes: %{
              left.capability_id => left.consequence,
              right.capability_id => right.consequence
            },
            resulting_state: resulting_state,
            composition_digest: "pending"
          }

          case raises_ceiling?(composition, [left, right]) do
            [] ->
              {:ok, %{composition | composition_digest: digest(composition)}}

            raised ->
              error(:composition_authority_ceiling_raised, %{capability_ids: raised})
          end

        unmet ->
          error(:composition_preconditions_unmet, %{
            unmet: unmet,
            resulting_state: after_left,
            left: left.capability_id,
            right: right.capability_id
          })
      end
    end
  end

  @doc """
  Returns the `capability_id`s whose requirement inside `composition`
  differs from their own declared `authority_requirement`.

  `[]` means the composition raised nobody's ceiling -- the S48 invariant
  holds. A non-empty list names exactly which participant's requirement was
  altered by composing.

  Scope it to the composition's own two participants. Handing it a profile
  the composition does not involve reports that profile as a discrepancy
  (the composition records `nil` for it, which differs from its declared
  requirement) -- correct per the contract above, and deliberately not
  softened: a silently-ignored unknown profile would let a caller "verify" a
  composition against capabilities it never checked.
  """
  @spec raises_ceiling?(Composition.t(), [CapabilityProfile.t()]) :: [String.t()]
  def raises_ceiling?(%Composition{} = composition, profiles) when is_list(profiles) do
    profiles
    |> Enum.filter(fn %CapabilityProfile{} = profile ->
      Map.get(composition.authority_requirements, profile.capability_id) !=
        profile.authority_requirement
    end)
    |> Enum.map(& &1.capability_id)
    |> Enum.sort()
  end

  @doc """
  Folds `compose/3` across an ordered chain of profiles, threading the real
  resulting state forward.

  Each adjacent pair is composed under the *frame-aware* reading (the prior
  state is genuinely available by the time the second step runs), which is
  why this takes `:initial_state` once rather than re-applying the strict
  empty-state reading at every hop.

  Returns `{:ok, {compositions, final_state}}`, or the first refusal with
  the failing hop index added as `detail.hop`.
  """
  @spec chain([CapabilityProfile.t()], keyword()) ::
          {:ok, {[Composition.t()], [fact()]}} | refusal()
  def chain([_ | _] = profiles, opts \\ []) do
    initial_state = Keyword.get(opts, :initial_state, [])
    [first | rest] = profiles

    # The accumulator threads the state as it stood *before* `previous` ran,
    # because `compose/3` applies `previous`'s own effects internally. Passing
    # the post-`previous` state here instead would apply those effects twice.
    rest
    |> Enum.with_index()
    |> Enum.reduce_while(
      {:ok, {[], initial_state, first}},
      fn {next, index}, {:ok, {acc, state_before_previous, previous}} ->
        case compose(previous, next, initial_state: state_before_previous) do
          {:ok, composition} ->
            {:cont,
             {:ok, {[composition | acc], apply_effects(state_before_previous, previous), next}}}

          {:error, detail} ->
            {:halt, {:error, Map.put(detail, :hop, index)}}
        end
      end
    )
    |> case do
      {:ok, {acc, state_before_last, last}} ->
        {:ok, {Enum.reverse(acc), apply_effects(state_before_last, last)}}

      {:error, _} = refusal ->
        refusal
    end
  end

  defp distinct(%CapabilityProfile{capability_id: id}, %CapabilityProfile{capability_id: id}),
    do: error(:composition_self_composition, id)

  defp distinct(_left, _right), do: :ok

  defp normalize({predicate, args}) when is_list(args),
    do: {to_string(predicate), Enum.map(args, &to_string/1)}

  defp digest(%Composition{} = composition) do
    CanonicalTermDigest.digest(%{
      left: composition.left,
      right: composition.right,
      authority_requirements: composition.authority_requirements,
      consequence_classes: composition.consequence_classes,
      resulting_state: composition.resulting_state
    })
  end

  defp error(code, detail), do: {:error, %{code: code, detail: detail}}
end
