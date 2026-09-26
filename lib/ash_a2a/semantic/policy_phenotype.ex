defmodule AshA2A.Semantic.PolicyPhenotype do
  @moduledoc """
  Candidate-only SA2A declaration for one behavioral realization of a policy.

  A phenotype says how a participant may search, coordinate, explore, or
  communicate while serving a capability. It is deliberately separate from
  `AshA2A.Semantic.AgentCard`: capability truth still comes from the compiled
  Ash capability index, and a phenotype never becomes a capability grant.

  The declaration is transport-neutral and contains no credential, authority
  token, grant, or command handle. `actuation_boundary/0` is a constant
  describing where consequence remains governed: the existing external
  CommandBus/BRCE admission path.

  Reaction norms are linear and bounded:

      value(cue) = baseline + slope * (cue - reference_cue)

  Every result is clamped to the declared axis range. Axis names associated
  with authority are refused so an "initiative" or other behavioral dimension
  cannot be used as a disguised execution permission.
  """

  @forbidden_axes MapSet.new([
                    "authority",
                    "permission",
                    "execution_grant",
                    "execution_authority",
                    "do"
                  ])

  @enforce_keys [:capability_iri, :policy_family]
  defstruct [
    :capability_iri,
    :policy_family,
    conditionable_axes: %{},
    condition: %{},
    reaction_norms: %{},
    evidence_refs: []
  ]

  @type axis_range :: %{required(:min) => number(), required(:max) => number()}

  @type reaction_norm :: %{
          required(:slope) => number(),
          optional(:reference_cue) => number()
        }

  @type t :: %__MODULE__{
          capability_iri: String.t(),
          policy_family: String.t(),
          conditionable_axes: %{optional(String.t()) => axis_range()},
          condition: %{optional(String.t()) => number()},
          reaction_norms: %{optional(String.t()) => reaction_norm()},
          evidence_refs: [String.t()]
        }

  @type refusal_code ::
          :invalid_policy_phenotype
          | :temperament_cannot_encode_authority
          | :invalid_condition_axis_range
          | :unknown_condition_axis
          | :condition_out_of_range
          | :invalid_reaction_norm

  @spec new(keyword()) :: {:ok, t()} | {:error, %{code: refusal_code(), detail: term()}}
  def new(opts) when is_list(opts) do
    phenotype = %__MODULE__{
      capability_iri: Keyword.get(opts, :capability_iri),
      policy_family: Keyword.get(opts, :policy_family),
      conditionable_axes: Map.new(Keyword.get(opts, :conditionable_axes, %{})),
      condition: Map.new(Keyword.get(opts, :condition, %{})),
      reaction_norms: Map.new(Keyword.get(opts, :reaction_norms, %{})),
      evidence_refs: List.wrap(Keyword.get(opts, :evidence_refs, []))
    }

    with :ok <- validate_identity(phenotype),
         :ok <- validate_axis_names(phenotype),
         :ok <- validate_ranges(phenotype.conditionable_axes),
         :ok <- validate_condition(phenotype),
         :ok <- validate_reaction_norms(phenotype) do
      {:ok, phenotype}
    end
  end

  def new(_opts), do: refuse(:invalid_policy_phenotype, :expected_keyword_list)

  @doc """
  Apply the declared reaction norms for `cue`.

  Capability identity, policy family, evidence, and the set of supported axes
  are preserved byte-for-byte. This function changes only the behavioral
  condition map; it performs no dispatch and has no path to CommandBus.
  """
  @spec condition(t(), number()) ::
          {:ok, t()} | {:error, %{code: refusal_code(), detail: term()}}
  def condition(%__MODULE__{} = phenotype, cue) when is_number(cue) do
    with :ok <- validate_axis_names(phenotype),
         :ok <- validate_ranges(phenotype.conditionable_axes),
         :ok <- validate_condition(phenotype),
         :ok <- validate_reaction_norms(phenotype) do
      next_condition =
        Enum.reduce(phenotype.reaction_norms, phenotype.condition, fn
          {axis, %{slope: slope} = norm}, acc ->
            %{min: min, max: max} = Map.fetch!(phenotype.conditionable_axes, axis)
            baseline = Map.get(acc, axis, min)
            reference_cue = Map.get(norm, :reference_cue, 0.0)
            value = baseline + slope * (cue - reference_cue)
            Map.put(acc, axis, clamp(value, min, max))
        end)

      {:ok, %{phenotype | condition: next_condition}}
    end
  end

  def condition(%__MODULE__{}, _cue),
    do: refuse(:invalid_policy_phenotype, :cue_must_be_numeric)

  @doc "A phenotype is a declaration/candidate, never a grant."
  @spec grant?(t()) :: false
  def grant?(%__MODULE__{}), do: false

  @doc "Execution remains outside this declaration on the existing receipted DO path."
  @spec actuation_boundary() :: :external_command_bus_brce
  def actuation_boundary, do: :external_command_bus_brce

  @doc "The supported temperament vocabulary from arXiv:2609.29423."
  @spec default_axes() :: [String.t()]
  def default_axes do
    [
      "boldness",
      "exploration",
      "activity",
      "aggressiveness",
      "sociability",
      "self_model_plasticity",
      "forcefulness",
      "initiative",
      "expressiveness"
    ]
  end

  defp validate_identity(%__MODULE__{capability_iri: capability_iri, policy_family: policy_family})
       when is_binary(capability_iri) and byte_size(capability_iri) > 0 and
              is_binary(policy_family) and byte_size(policy_family) > 0,
       do: :ok

  defp validate_identity(_phenotype),
    do: refuse(:invalid_policy_phenotype, :capability_and_policy_family_required)

  defp validate_axis_names(%__MODULE__{} = phenotype) do
    axes =
      Map.keys(phenotype.conditionable_axes) ++
        Map.keys(phenotype.condition) ++ Map.keys(phenotype.reaction_norms)

    case Enum.find(axes, &MapSet.member?(@forbidden_axes, &1)) do
      nil -> :ok
      axis -> refuse(:temperament_cannot_encode_authority, axis)
    end
  end

  defp validate_ranges(ranges) do
    Enum.reduce_while(ranges, :ok, fn
      {axis, %{min: min, max: max}}, :ok
      when is_binary(axis) and is_number(min) and is_number(max) and min < max ->
        {:cont, :ok}

      {axis, range}, :ok ->
        {:halt, refuse(:invalid_condition_axis_range, {axis, range})}
    end)
  end

  defp validate_condition(%__MODULE__{} = phenotype) do
    Enum.reduce_while(phenotype.condition, :ok, fn
      {axis, value}, :ok when is_binary(axis) and is_number(value) ->
        case Map.fetch(phenotype.conditionable_axes, axis) do
          :error ->
            {:halt, refuse(:unknown_condition_axis, axis)}

          {:ok, %{min: min, max: max}} when value >= min and value <= max ->
            {:cont, :ok}

          {:ok, range} ->
            {:halt, refuse(:condition_out_of_range, {axis, value, range})}
        end

      entry, :ok ->
        {:halt, refuse(:invalid_policy_phenotype, {:invalid_condition, entry})}
    end)
  end

  defp validate_reaction_norms(%__MODULE__{} = phenotype) do
    Enum.reduce_while(phenotype.reaction_norms, :ok, fn
      {axis, %{slope: slope} = norm}, :ok when is_binary(axis) and is_number(slope) ->
        cond do
          not Map.has_key?(phenotype.conditionable_axes, axis) ->
            {:halt, refuse(:unknown_condition_axis, axis)}

          Map.has_key?(norm, :reference_cue) and not is_number(norm.reference_cue) ->
            {:halt, refuse(:invalid_reaction_norm, {axis, norm})}

          true ->
            {:cont, :ok}
        end

      entry, :ok ->
        {:halt, refuse(:invalid_reaction_norm, entry)}
    end)
  end

  defp clamp(value, min, _max) when value < min, do: min
  defp clamp(value, _min, max) when value > max, do: max
  defp clamp(value, _min, _max), do: value

  defp refuse(code, detail), do: {:error, %{code: code, detail: detail}}
end
