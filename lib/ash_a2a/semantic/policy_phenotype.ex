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

  @vocabulary_provenance "https://arxiv.org/abs/2609.29423"

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
          | :invalid_policy_phenotype_transport
          | :policy_phenotype_digest_mismatch
          | :phenotype_authority_smuggling
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

  @doc "Canonical transport map. It describes behavior and explicitly grants nothing."
  @spec to_map(t()) :: map()
  def to_map(%__MODULE__{} = phenotype) do
    %{
      "capability_iri" => phenotype.capability_iri,
      "policy_family" => phenotype.policy_family,
      "conditionable_axes" =>
        Map.new(phenotype.conditionable_axes, fn {axis, %{min: min, max: max}} ->
          {axis, %{"min" => min, "max" => max}}
        end),
      "condition" => phenotype.condition,
      "reaction_norms" =>
        Map.new(phenotype.reaction_norms, fn {axis, norm} ->
          value =
            %{"slope" => norm.slope}
            |> maybe_put("reference_cue", Map.get(norm, :reference_cue))

          {axis, value}
        end),
      "evidence_refs" => phenotype.evidence_refs,
      "authority_semantics" => %{
        "candidate_only" => true,
        "phenotype_has_authority" => false,
        "execution_authority" => "external_command_bus_brce"
      }
    }
  end

  @doc "Canonical term digest of to_map/1."
  @spec digest(t()) :: String.t()
  def digest(%__MODULE__{} = phenotype) do
    AshA2A.Semantic.CanonicalTermDigest.digest(to_map(phenotype))
  end

  @doc "Parse the canonical transport map and optionally verify its expected digest."
  @spec from_map(map(), String.t() | nil) ::
          {:ok, t()} | {:error, %{code: refusal_code(), detail: term()}}
  def from_map(map, expected_digest \\ nil)

  def from_map(map, expected_digest) when is_map(map) do
    with :ok <- reject_authority_smuggling(map),
         {:ok, phenotype} <-
           new(
             capability_iri: value(map, "capability_iri"),
             policy_family: value(map, "policy_family"),
             conditionable_axes: decode_axes(value(map, "conditionable_axes", %{})),
             condition: Map.new(value(map, "condition", %{})),
             reaction_norms: decode_reaction_norms(value(map, "reaction_norms", %{})),
             evidence_refs: List.wrap(value(map, "evidence_refs", []))
           ),
         :ok <- verify_expected_digest(phenotype, expected_digest) do
      {:ok, phenotype}
    end
  rescue
    _error -> refuse(:invalid_policy_phenotype_transport, map)
  end

  def from_map(other, _expected_digest),
    do: refuse(:invalid_policy_phenotype_transport, other)

  @doc "A phenotype is a declaration/candidate, never a grant."
  @spec grant?(t()) :: false
  def grant?(%__MODULE__{}), do: false

  @doc "Execution remains outside this declaration on the existing receipted DO path."
  @spec actuation_boundary() :: :external_command_bus_brce
  def actuation_boundary, do: :external_command_bus_brce

  @doc "Provenance for the temperament vocabulary, not evidence for a specific phenotype value."
  @spec vocabulary_provenance() :: String.t()
  def vocabulary_provenance, do: @vocabulary_provenance

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

  defp value(map, key, default \\ nil) do
    Map.get(map, key, Map.get(map, String.to_existing_atom(key), default))
  rescue
    ArgumentError -> Map.get(map, key, default)
  end

  defp decode_axes(axes) when is_map(axes) do
    Map.new(axes, fn {axis, range} ->
      {to_string(axis),
       %{
         min: value(range, "min"),
         max: value(range, "max")
       }}
    end)
  end

  defp decode_axes(other), do: other

  defp decode_reaction_norms(norms) when is_map(norms) do
    Map.new(norms, fn {axis, norm} ->
      decoded = %{slope: value(norm, "slope")}

      decoded =
        case value(norm, "reference_cue", :missing) do
          :missing -> decoded
          reference -> Map.put(decoded, :reference_cue, reference)
        end

      {to_string(axis), decoded}
    end)
  end

  defp decode_reaction_norms(other), do: other

  defp reject_authority_smuggling(map) do
    expected_semantics = %{
      "candidate_only" => true,
      "phenotype_has_authority" => false,
      "execution_authority" => "external_command_bus_brce"
    }

    semantics = value(map, "authority_semantics", expected_semantics)

    if semantics != expected_semantics do
      refuse(:phenotype_authority_smuggling, {:authority_semantics, semantics})
    else
      forbidden =
        ~w(authority permission execution_grant execution_authority grant token credential)

      payload =
        map
        |> Map.delete("authority_semantics")
        |> Map.delete(:authority_semantics)

      found =
        payload
        |> transport_keys()
        |> Enum.find(fn key -> String.downcase(String.trim(key)) in forbidden end)

      if found == nil,
        do: :ok,
        else: refuse(:phenotype_authority_smuggling, found)
    end
  end

  defp transport_keys(value) when is_map(value) do
    Enum.flat_map(value, fn {key, nested} -> [to_string(key) | transport_keys(nested)] end)
  end

  defp transport_keys(value) when is_list(value), do: Enum.flat_map(value, &transport_keys/1)
  defp transport_keys(_value), do: []

  defp verify_expected_digest(_phenotype, nil), do: :ok

  defp verify_expected_digest(phenotype, expected_digest) when is_binary(expected_digest) do
    actual = digest(phenotype)

    if actual == expected_digest,
      do: :ok,
      else:
        refuse(:policy_phenotype_digest_mismatch, %{
          expected: expected_digest,
          actual: actual
        })
  end

  defp verify_expected_digest(_phenotype, other),
    do: refuse(:invalid_policy_phenotype_transport, {:expected_digest, other})

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

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

    case Enum.find(axes, &forbidden_axis?/1) do
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

  defp forbidden_axis?(axis) when is_binary(axis) do
    axis
    |> String.trim()
    |> String.downcase()
    |> then(&MapSet.member?(@forbidden_axes, &1))
  end

  defp forbidden_axis?(_axis), do: false

  defp clamp(value, min, _max) when value < min, do: min
  defp clamp(value, _min, max) when value > max, do: max
  defp clamp(value, _min, _max), do: value

  defp refuse(code, detail), do: {:error, %{code: code, detail: detail}}
end
