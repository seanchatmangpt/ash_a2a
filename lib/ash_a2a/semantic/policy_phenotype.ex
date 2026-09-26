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

  # Tokens that make an axis authority-bearing wherever they appear inside a
  # normalized name (`execution-grant`, `grant_level`, `permissions`, ...).
  # `do` is refused only as the whole name so ordinary words are unaffected.
  @forbidden_tokens MapSet.new([
                      "authority",
                      "authorities",
                      "authorization",
                      "authorize",
                      "permission",
                      "permissions",
                      "grant",
                      "grants",
                      "lease",
                      "credential",
                      "credentials",
                      "token"
                    ])

  @allowed_options [
    :capability_iri,
    :policy_family,
    :conditionable_axes,
    :condition,
    :reaction_norms,
    :evidence_refs
  ]

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
    with :ok <- validate_options(opts),
         {:ok, conditionable_axes} <- to_axis_map(opts, :conditionable_axes),
         {:ok, condition} <- to_axis_map(opts, :condition),
         {:ok, reaction_norms} <- to_axis_map(opts, :reaction_norms),
         {:ok, evidence_refs} <- to_evidence_refs(Keyword.get(opts, :evidence_refs, [])) do
      phenotype = %__MODULE__{
        capability_iri: Keyword.get(opts, :capability_iri),
        policy_family: Keyword.get(opts, :policy_family),
        conditionable_axes: conditionable_axes,
        condition: condition,
        reaction_norms: reaction_norms,
        evidence_refs: evidence_refs
      }

      validate(phenotype)
    end
  end

  def new(_opts), do: refuse(:invalid_policy_phenotype, :expected_keyword_list)

  defp validate(%__MODULE__{} = phenotype) do
    with :ok <- validate_identity(phenotype),
         :ok <- validate_axis_names(phenotype),
         :ok <- validate_ranges(phenotype.conditionable_axes),
         :ok <- validate_condition(phenotype),
         :ok <- validate_reaction_norms(phenotype),
         :ok <- validate_evidence_refs(phenotype.evidence_refs) do
      {:ok, phenotype}
    end
  end

  @doc """
  Apply the declared reaction norms for `cue`.

  Capability identity, policy family, evidence, and the set of supported axes
  are preserved byte-for-byte. This function changes only the behavioral
  condition map; it performs no dispatch and has no path to CommandBus.
  """
  @spec condition(t(), number()) ::
          {:ok, t()} | {:error, %{code: refusal_code(), detail: term()}}
  def condition(%__MODULE__{} = phenotype, cue) when is_number(cue) do
    with {:ok, phenotype} <- validate(phenotype) do
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

  @doc "Provenance for the temperament vocabulary, not evidence for a specific phenotype value."
  @spec vocabulary_provenance() :: String.t()
  def vocabulary_provenance, do: @vocabulary_provenance

  @doc """
  The normalized form the authority fence and the duplicate-axis check compare.

  NFKC-folded, format characters (Cf) removed, lowercased, every run of
  non-letter/non-digit characters collapsed to one `_`, and leading/trailing
  `_` trimmed. Atoms are normalized by name; other terms are returned as-is.
  """
  @spec normalize_axis_name(term()) :: term()
  def normalize_axis_name(axis), do: normalize_axis(axis)

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

  defp validate_identity(%__MODULE__{
         capability_iri: capability_iri,
         policy_family: policy_family
       })
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

  defp validate_options(opts) do
    with true <- Enum.all?(opts, &match?({key, _} when is_atom(key), &1)),
         keys = Keyword.keys(opts),
         [] <- Enum.reject(keys, &(&1 in @allowed_options)),
         nil <- first_duplicate(keys) do
      :ok
    else
      false -> refuse(:invalid_policy_phenotype, :expected_keyword_list)
      [unknown | _] -> refuse(:invalid_policy_phenotype, {:unknown_option, unknown})
      duplicate -> refuse(:invalid_policy_phenotype, {:duplicate_option, duplicate})
    end
  end

  # Accepts a map or a list of `{axis, value}` pairs. A list naming one axis
  # twice (after normalization) is refused instead of letting `Map.new/1`
  # silently keep the last delivery.
  defp to_axis_map(opts, key) do
    case Keyword.get(opts, key, %{}) do
      %{} = map when not is_struct(map) ->
        refuse_axis_collision(key, Map.keys(map), map)

      list when is_list(list) ->
        if Enum.all?(list, &match?({_, _}, &1)) do
          refuse_axis_collision(key, Enum.map(list, &elem(&1, 0)), list)
        else
          refuse(:invalid_policy_phenotype, {:expected_axis_map, key})
        end

      _other ->
        refuse(:invalid_policy_phenotype, {:expected_axis_map, key})
    end
  end

  defp refuse_axis_collision(key, axes, entries) do
    case first_duplicate(Enum.map(axes, &normalize_axis/1)) do
      nil -> {:ok, Map.new(entries)}
      axis -> refuse(:invalid_policy_phenotype, {:duplicate_axis, key, axis})
    end
  end

  defp to_evidence_refs(refs) when is_list(refs), do: {:ok, refs}
  defp to_evidence_refs(nil), do: {:ok, []}
  defp to_evidence_refs(ref), do: {:ok, [ref]}

  defp validate_evidence_refs(refs) when is_list(refs) do
    case Enum.find(refs, &(not (is_binary(&1) and byte_size(&1) > 0))) do
      nil -> :ok
      ref -> refuse(:invalid_policy_phenotype, {:invalid_evidence_ref, ref})
    end
  end

  defp validate_evidence_refs(refs),
    do: refuse(:invalid_policy_phenotype, {:invalid_evidence_ref, refs})

  defp first_duplicate(items) do
    Enum.reduce_while(items, MapSet.new(), fn item, seen ->
      if MapSet.member?(seen, item),
        do: {:halt, {:dup, item}},
        else: {:cont, MapSet.put(seen, item)}
    end)
    |> case do
      {:dup, item} -> item
      _seen -> nil
    end
  end

  defp forbidden_axis?(axis) when is_binary(axis) or is_atom(axis) do
    normalized = normalize_axis(axis)
    tokens = String.split(normalized, "_", trim: true)

    MapSet.member?(@forbidden_axes, normalized) or
      MapSet.member?(@forbidden_axes, Enum.join(tokens, "_")) or
      Enum.any?(tokens, &MapSet.member?(@forbidden_tokens, &1))
  end

  defp forbidden_axis?(_axis), do: false

  # NFKC-folds compatibility forms (fullwidth letters), drops invisible
  # format characters (zero-width space/joiner, BOM, soft hyphen), and maps
  # every run of non-alphanumeric separators to one `_`, so `Execution-Grant`,
  # `execution grant`, `auth\u200Bority` and `ＡＵＴＨＯＲＩＴＹ` normalize to the
  # same name the fence checks.
  defp normalize_axis(axis) when is_atom(axis), do: axis |> Atom.to_string() |> normalize_axis()

  defp normalize_axis(axis) when is_binary(axis) do
    cond do
      ascii?(axis) -> fold_ascii(axis, <<>>)
      String.valid?(axis) -> normalize_unicode(axis)
      true -> axis
    end
  end

  defp normalize_axis(axis), do: axis

  # Fast path (every default axis and almost every real one): one pass over
  # the bytes, no regex, no Unicode tables. Lowercases A-Z, keeps a-z/0-9,
  # collapses any other run of bytes to a single `_`, trims `_` at both ends.
  defp ascii?(<<c, rest::binary>>) when c < 128, do: ascii?(rest)
  defp ascii?(<<>>), do: true
  defp ascii?(_), do: false

  defp fold_ascii(<<c, rest::binary>>, acc) when c in ?a..?z or c in ?0..?9,
    do: fold_ascii(rest, <<acc::binary, c>>)

  defp fold_ascii(<<c, rest::binary>>, acc) when c in ?A..?Z,
    do: fold_ascii(rest, <<acc::binary, c + 32>>)

  defp fold_ascii(<<_c, rest::binary>>, <<>>), do: fold_ascii(rest, <<>>)

  defp fold_ascii(<<_c, rest::binary>>, acc) do
    if :binary.last(acc) == ?_,
      do: fold_ascii(rest, acc),
      else: fold_ascii(rest, <<acc::binary, ?_>>)
  end

  defp fold_ascii(<<>>, acc), do: String.trim_trailing(acc, "_")

  # Slow path for non-ASCII names only: NFKC folds compatibility forms,
  # format characters (Cf) are dropped, then the ASCII fold applies to the
  # letters/digits that remain; other letters are kept as-is (lowercased).
  defp normalize_unicode(axis) do
    axis
    |> :unicode.characters_to_nfkc_binary()
    |> String.replace(~r/[\p{Cf}]/u, "")
    |> String.downcase()
    |> String.replace(~r/[^\p{L}\p{N}]+/u, "_")
    |> String.trim("_")
  end

  defp clamp(value, min, _max) when value < min, do: min
  defp clamp(value, _min, max) when value > max, do: max
  defp clamp(value, _min, _max), do: value

  defp refuse(code, detail), do: {:error, %{code: code, detail: detail}}
end
