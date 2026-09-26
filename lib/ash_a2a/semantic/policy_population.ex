defmodule AshA2A.Semantic.PolicyPopulation do
  @moduledoc """
  Candidate-only weighted population of policy phenotypes.

  The population, not one controller instance, is the design object. This
  module carries that object across SA2A without conflating behavioral
  distribution with capability authority.

  Population kinds:

    * :homogeneous -- exactly one phenotype
    * :incidental -- observed variation, not deliberately designed
    * :engineered -- deliberately selected static distribution
    * :adaptive -- phenotypes carry reaction norms and may be conditioned

  A population never grants anything. Consequence remains behind the existing
  CommandBus/BRCE boundary.
  """

  alias AshA2A.Semantic.CanonicalTermDigest
  alias AshA2A.Semantic.PolicyPhenotype

  @kinds [:homogeneous, :incidental, :engineered, :adaptive]

  @enforce_keys [:kind, :members]
  defstruct [:kind, :members, evidence_refs: []]

  @type kind :: :homogeneous | :incidental | :engineered | :adaptive
  @type member :: %{required(:phenotype) => PolicyPhenotype.t(), required(:weight) => number()}

  @type t :: %__MODULE__{
          kind: kind(),
          members: [member()],
          evidence_refs: [String.t()]
        }

  @type refusal_code ::
          :invalid_policy_population
          | :invalid_population_kind
          | :population_requires_member
          | :homogeneous_population_requires_one_phenotype
          | :adaptive_population_requires_reaction_norm
          | :invalid_population_weight
          | :policy_population_digest_mismatch
          | :population_authority_smuggling

  @spec new(kind(), [member() | {PolicyPhenotype.t(), number()}], keyword()) ::
          {:ok, t()} | {:error, %{code: refusal_code(), detail: term()}}
  def new(kind, members, opts \\ [])

  def new(kind, members, opts) when is_list(members) and is_list(opts) do
    with {:ok, kind} <- normalize_kind(kind),
         {:ok, members} <- normalize_members(members),
         :ok <- validate_kind_members(kind, members) do
      {:ok,
       %__MODULE__{
         kind: kind,
         members: members,
         evidence_refs: List.wrap(Keyword.get(opts, :evidence_refs, []))
       }}
    end
  end

  def new(_kind, _members, _opts),
    do: refuse(:invalid_policy_population, :expected_kind_members_and_keyword_options)

  @doc "Population kinds admitted by this profile."
  @spec kinds() :: [kind()]
  def kinds, do: @kinds

  @doc "Normalized positive member weights in declared member order."
  @spec normalized_weights(t()) :: [float()]
  def normalized_weights(%__MODULE__{members: members}) do
    total = Enum.reduce(members, 0.0, fn %{weight: weight}, acc -> acc + weight end)
    Enum.map(members, fn %{weight: weight} -> weight / total end)
  end

  @doc """
  Weighted geometric disparity plus inverse-Simpson effective complexity.

  Disparity and complexity remain separate because member count alone does not
  measure how behaviorally different the members actually are.
  """
  @spec diversity(t()) :: %{disparity: float(), complexity: float()}
  def diversity(%__MODULE__{} = population) do
    weights = normalized_weights(population)

    indexed =
      population.members
      |> Enum.with_index()
      |> Enum.map(fn {%{phenotype: phenotype}, index} ->
        {phenotype.condition, Enum.at(weights, index)}
      end)

    {weighted_distance, pair_weight} =
      indexed
      |> Enum.with_index()
      |> Enum.reduce({0.0, 0.0}, fn {{left_condition, left_weight}, left_index},
                                    {distance_acc, weight_acc} ->
        indexed
        |> Enum.drop(left_index + 1)
        |> Enum.reduce({distance_acc, weight_acc}, fn {right_condition, right_weight},
                                                     {inner_distance, inner_weight} ->
          distance = condition_distance(left_condition, right_condition)
          weight = left_weight * right_weight
          {inner_distance + weight * distance, inner_weight + weight}
        end)
      end)

    disparity =
      if pair_weight == 0.0,
        do: 0.0,
        else: weighted_distance / pair_weight

    complexity =
      1.0 /
        Enum.reduce(weights, 0.0, fn weight, acc ->
          acc + weight * weight
        end)

    %{disparity: disparity, complexity: complexity}
  end

  @doc "Apply each member phenotype's reaction norm for one environmental cue."
  @spec condition(t(), number()) ::
          {:ok, t()} | {:error, %{code: atom(), detail: term()}}
  def condition(%__MODULE__{kind: :adaptive} = population, cue) when is_number(cue) do
    population.members
    |> Enum.reduce_while({:ok, []}, fn %{phenotype: phenotype, weight: weight}, {:ok, acc} ->
      case PolicyPhenotype.condition(phenotype, cue) do
        {:ok, conditioned} ->
          {:cont, {:ok, [%{phenotype: conditioned, weight: weight} | acc]}}

        {:error, _} = error ->
          {:halt, error}
      end
    end)
    |> case do
      {:ok, members} ->
        {:ok, %{population | members: Enum.reverse(members)}}

      {:error, _} = error ->
        error
    end
  end

  def condition(%__MODULE__{} = population, cue) when is_number(cue),
    do: {:ok, population}

  def condition(%__MODULE__{}, other),
    do: refuse(:invalid_policy_population, {:cue_must_be_numeric, other})

  @doc "Canonical transport representation. No member can carry a grant."
  @spec to_map(t()) :: map()
  def to_map(%__MODULE__{} = population) do
    %{
      "kind" => Atom.to_string(population.kind),
      "members" =>
        Enum.map(population.members, fn %{phenotype: phenotype, weight: weight} ->
          %{
            "phenotype" => PolicyPhenotype.to_map(phenotype),
            "phenotype_digest" => PolicyPhenotype.digest(phenotype),
            "weight" => weight
          }
        end),
      "evidence_refs" => population.evidence_refs,
      "diversity" =>
        population
        |> diversity()
        |> Map.new(fn {key, value} -> {Atom.to_string(key), value} end),
      "authority_semantics" => %{
        "candidate_only" => true,
        "population_has_authority" => false,
        "execution_authority" => "external_command_bus_brce"
      }
    }
  end

  @doc "Canonical term identity of the entire population."
  @spec digest(t()) :: String.t()
  def digest(%__MODULE__{} = population), do: CanonicalTermDigest.digest(to_map(population))

  @doc "Decode the canonical map and optionally verify the expected population digest."
  @spec from_map(map(), String.t() | nil) ::
          {:ok, t()} | {:error, %{code: atom(), detail: term()}}
  def from_map(map, expected_digest \\ nil)

  def from_map(map, expected_digest) when is_map(map) do
    with :ok <- reject_authority_smuggling(map),
         {:ok, kind} <- normalize_kind(value(map, "kind")),
         {:ok, members} <- decode_members(value(map, "members", [])),
         {:ok, population} <-
           new(kind, members, evidence_refs: List.wrap(value(map, "evidence_refs", []))),
         :ok <- verify_expected_digest(population, expected_digest) do
      {:ok, population}
    end
  rescue
    _error -> refuse(:invalid_policy_population, map)
  end

  def from_map(other, _expected_digest), do: refuse(:invalid_policy_population, other)

  @doc "A population is candidate state, never an authority grant."
  @spec grant?(t()) :: false
  def grant?(%__MODULE__{}), do: false

  @spec standing(t()) :: :candidate
  def standing(%__MODULE__{}), do: :candidate

  @spec actuation_boundary() :: :external_command_bus_brce
  def actuation_boundary, do: :external_command_bus_brce

  defp normalize_kind(kind) when kind in @kinds, do: {:ok, kind}

  defp normalize_kind(kind) when is_binary(kind) do
    case kind do
      "homogeneous" -> {:ok, :homogeneous}
      "incidental" -> {:ok, :incidental}
      "engineered" -> {:ok, :engineered}
      "adaptive" -> {:ok, :adaptive}
      other -> refuse(:invalid_population_kind, other)
    end
  end

  defp normalize_kind(other), do: refuse(:invalid_population_kind, other)

  defp normalize_members(members) do
    members
    |> Enum.reduce_while({:ok, []}, fn member, {:ok, acc} ->
      case normalize_member(member) do
        {:ok, normalized} -> {:cont, {:ok, [normalized | acc]}}
        {:error, _} = error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, normalized} -> {:ok, Enum.reverse(normalized)}
      {:error, _} = error -> error
    end
  end

  defp normalize_member(%{phenotype: %PolicyPhenotype{} = phenotype, weight: weight})
       when is_number(weight) and weight > 0,
       do: {:ok, %{phenotype: phenotype, weight: weight * 1.0}}

  defp normalize_member({%PolicyPhenotype{} = phenotype, weight})
       when is_number(weight) and weight > 0,
       do: {:ok, %{phenotype: phenotype, weight: weight * 1.0}}

  defp normalize_member(member), do: refuse(:invalid_population_weight, member)

  defp validate_kind_members(_kind, []), do: refuse(:population_requires_member, [])

  defp validate_kind_members(:homogeneous, members) when length(members) != 1,
    do: refuse(:homogeneous_population_requires_one_phenotype, length(members))

  defp validate_kind_members(:adaptive, members) do
    if Enum.all?(members, fn %{phenotype: phenotype} ->
         map_size(phenotype.reaction_norms) > 0
       end),
      do: :ok,
      else: refuse(:adaptive_population_requires_reaction_norm, :member_without_reaction_norm)
  end

  defp validate_kind_members(_kind, _members), do: :ok

  defp decode_members(members) when is_list(members) do
    members
    |> Enum.reduce_while({:ok, []}, fn member, {:ok, acc} ->
      with true <- is_map(member),
           phenotype_map when is_map(phenotype_map) <- value(member, "phenotype"),
           expected when is_binary(expected) <- value(member, "phenotype_digest"),
           weight when is_number(weight) <- value(member, "weight"),
           {:ok, phenotype} <- PolicyPhenotype.from_map(phenotype_map, expected),
           {:ok, normalized} <- normalize_member({phenotype, weight}) do
        {:cont, {:ok, [normalized | acc]}}
      else
        {:error, _} = error -> {:halt, error}
        other -> {:halt, refuse(:invalid_policy_population, {:member, other})}
      end
    end)
    |> case do
      {:ok, decoded} -> {:ok, Enum.reverse(decoded)}
      {:error, _} = error -> error
    end
  end

  defp decode_members(other), do: refuse(:invalid_policy_population, {:members, other})

  defp reject_authority_smuggling(map) do
    expected = %{
      "candidate_only" => true,
      "population_has_authority" => false,
      "execution_authority" => "external_command_bus_brce"
    }

    semantics = value(map, "authority_semantics", expected)

    if semantics != expected do
      refuse(:population_authority_smuggling, {:authority_semantics, semantics})
    else
      forbidden =
        ~w(authority permission execution_grant execution_authority grant token credential)

      payload =
        map
        |> Map.delete("authority_semantics")
        |> Map.delete(:authority_semantics)

      case payload
           |> population_transport_keys()
           |> Enum.find(fn key -> String.downcase(String.trim(key)) in forbidden end) do
        nil -> :ok
        found -> refuse(:population_authority_smuggling, found)
      end
    end
  end

  defp verify_expected_digest(_population, nil), do: :ok

  defp verify_expected_digest(population, expected) when is_binary(expected) do
    actual = digest(population)

    if actual == expected,
      do: :ok,
      else: refuse(:policy_population_digest_mismatch, %{expected: expected, actual: actual})
  end

  defp verify_expected_digest(_population, other),
    do: refuse(:invalid_policy_population, {:expected_digest, other})

  defp condition_distance(left, right) do
    axes =
      left
      |> Map.keys()
      |> Kernel.++(Map.keys(right))
      |> Enum.uniq()

    axes
    |> Enum.reduce(0.0, fn axis, acc ->
      delta = Map.get(left, axis, 0.0) - Map.get(right, axis, 0.0)
      acc + delta * delta
    end)
    |> :math.sqrt()
  end

  defp value(map, key, default \\ nil) do
    Map.get(map, key, Map.get(map, String.to_existing_atom(key), default))
  rescue
    ArgumentError -> Map.get(map, key, default)
  end

  defp population_transport_keys(value) when is_map(value) do
    Enum.flat_map(value, fn {key, nested} ->
      string_key = to_string(key)

      cond do
        string_key == "authority_semantics" -> []
        string_key == "phenotype" -> [string_key]
        true -> [string_key | population_transport_keys(nested)]
      end
    end)
  end

  defp population_transport_keys(value) when is_list(value),
    do: Enum.flat_map(value, &population_transport_keys/1)

  defp population_transport_keys(_value), do: []

  defp refuse(code, detail), do: {:error, %{code: code, detail: detail}}
end
