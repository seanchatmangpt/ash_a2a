defmodule AshA2A.Semantic.Iri do
  @moduledoc """
  IRI validation and the public-ontology-first resolution sequence
  (RFC-SA2A-001 S7.1, S7.2).

  `AshA2A.Semantic.Vocabulary` is this repo's real prior-art-first *prefix*
  registry, and it is kept exactly as it is. Its `local/1`, however, mints
  `urn:ash-a2a:semantic:<slug>` from any string with **no provenance, no
  version and no admission** -- a private term can appear from nothing. That
  minting path is the gap this module closes.

  ## The five-step sequence (S7.2)

  `resolve/2` runs the RFC's ordered sequence and records which steps were
  actually attempted, so the discipline is auditable rather than asserted:

    1. search admitted public semantic sources for an exact concept
    2. reuse the existing public IRI if sufficient
    3. search for an equivalent or composable public representation
    4. express explicit mappings where multiple public models are required
    5. mint a private IRI **only** if genuinely absent or organization-private

  Step 5 is not reachable by default. When step 1 found an exact public match
  and the caller has not declared, in writing, *why* that public term is
  insufficient, minting is refused with `:private_mint_refused_public_available`.
  That refusal is the operational content of "public first".

  ## A private term is not mintable without its required fields

  `AshA2A.Semantic.Iri.PrivateTerm` carries `@enforce_keys` for all seven
  fields S7.2 requires -- provenance, scope, owning namespace, definition,
  mappings, version, admission receipt -- so a private term missing any of them
  cannot be constructed at all, and `mint_private/1` additionally refuses
  placeholder values (empty strings, `"latest"`, an empty search record).

  The `searched_sources`/`public_absence_reason` pair inside `provenance` is
  what encodes "genuinely absent": an empty search record is
  `:private_mint_search_unrecorded`, not a mint.
  """

  alias AshA2A.Semantic.TermRegistry

  @type refusal :: %{code: atom(), detail: String.t()}
  @type outcome ::
          :reused_public_iri
          | :reused_equivalent_public_iri
          | :composed_public_models
          | :minted_private_iri

  defmodule Resolution do
    @moduledoc """
    The audited result of one `AshA2A.Semantic.Iri.resolve/2` run.

    `steps_attempted` is the real ordered list of S7.2 steps that executed, and
    `exact_matches`/`equivalent_matches` are the real search results those steps
    produced -- not a claim that the sequence was followed.
    """

    @enforce_keys [:step, :outcome, :steps_attempted]
    defstruct [
      :step,
      :outcome,
      :iri,
      :private_term,
      steps_attempted: [],
      iris: [],
      mappings: [],
      exact_matches: [],
      equivalent_matches: []
    ]

    @type t :: %__MODULE__{}
  end

  defmodule PrivateTerm do
    @moduledoc """
    A private semantic term, mintable only with every field S7.2 requires.

    Constructing this struct without provenance, scope, owning namespace,
    definition, mappings, version or admission receipt raises -- the fields are
    `@enforce_keys`, not documentation.
    """

    @enforce_keys [
      :iri,
      :label,
      :definition,
      :scope,
      :owning_namespace,
      :version,
      :provenance,
      :mappings,
      :admission_receipt
    ]
    defstruct [
      :iri,
      :label,
      :definition,
      :scope,
      :owning_namespace,
      :version,
      :provenance,
      :mappings,
      :admission_receipt
    ]

    @type t :: %__MODULE__{}
  end

  # RFC 3986 excluded characters plus whitespace: an IRI may never contain them
  # unescaped. This is a real syntax check, not a URI parser.
  @excluded ~c"<>\"{}|\\^`"
  @scheme_pattern ~r/^[A-Za-z][A-Za-z0-9+.\-]*$/
  @placeholder_versions ["", "latest", "LATEST", "head", "HEAD", "main", "master", "*"]
  @private_scopes [:organization_private, :deployment_private]
  @mapping_kinds [:exact_match, :close_match, :broad_match, :narrow_match, :related_match]

  @doc """
  Validates an absolute IRI.

  Checks: binary, non-empty, an RFC 3986-shaped scheme, a non-empty
  scheme-specific part, and no unescaped excluded/whitespace/control
  characters.
  """
  @spec validate(term()) :: {:ok, String.t()} | {:error, refusal()}
  def validate(value) when is_binary(value) do
    trimmed = String.trim(value)

    cond do
      trimmed == "" ->
        {:error, refusal(:iri_empty, "IRI is empty")}

      trimmed != value ->
        {:error,
         refusal(:iri_invalid_characters, "IRI #{inspect(value)} has leading/trailing whitespace")}

      has_excluded?(value) ->
        {:error,
         refusal(
           :iri_invalid_characters,
           "IRI #{inspect(value)} contains whitespace, a control character, or one of " <>
             "the RFC 3986 excluded characters #{inspect(List.to_string(@excluded))}"
         )}

      true ->
        validate_absolute(value)
    end
  end

  def validate(value),
    do: {:error, refusal(:iri_not_a_string, "IRI must be a binary, got #{inspect(value)}")}

  @doc "True when `validate/1` succeeds."
  @spec valid?(term()) :: boolean()
  def valid?(value), do: match?({:ok, _}, validate(value))

  @doc """
  Classifies an IRI as `:public` or `:private` against an admitted index.

  **Membership in the real admitted index is the only route to `:public`.**
  An IRI under a known private namespace is `:private`; anything else is
  `:unknown` -- which is deliberately not the same as public.

  ## Why namespace prefix is not membership

  `TermRegistry.in_admitted_namespace?/2` is a bare `String.starts_with?/2`
  prefix test against the namespaces of the admitted sources. An earlier
  revision accepted it as a second route to `:public`, which made the
  classification a *syntactic* test rather than an index lookup, and so
  classified an invented term as public whenever its inventor spelled it
  under an admitted prefix:

      TermRegistry.member?(index, "…skos/core#totallyInventedTerm")  -> false
      classify("…skos/core#totallyInventedTerm", index)              -> :public

  That is exactly the S7.3 mint-and-use evasion the public-first sequence
  exists to refuse, achieved by choosing a namespace. A term is public
  because it is really in an admitted, digest-pinned public ontology
  document, not because its IRI begins with a familiar string.

  The namespace test is still meaningful, and still available, as a
  *provenance* signal -- see `admitted_namespace_but_unknown_term?/2`, which
  names this case for a refusal receipt instead of laundering it into
  `:public`.
  """
  @spec classify(String.t(), TermRegistry.t() | nil) :: :public | :private | :unknown
  def classify(iri, index \\ nil)

  def classify(iri, index) when is_binary(iri) do
    cond do
      index != nil and TermRegistry.member?(index, iri) -> :public
      String.starts_with?(iri, "urn:ash-a2a:") -> :private
      String.starts_with?(iri, "urn:") -> :private
      true -> :unknown
    end
  end

  @doc """
  True when `iri` sits under an admitted namespace but is **not** a term in
  the admitted index -- an invented term wearing a public prefix.

  This is the case `classify/2` used to mislabel `:public`. It is worth
  naming rather than merely refusing: "sits under an admitted namespace but
  is not a term in the pinned document" tells a caller something actionable
  that a bare `:unknown` does not.
  """
  @spec admitted_namespace_but_unknown_term?(String.t(), TermRegistry.t() | nil) :: boolean()
  def admitted_namespace_but_unknown_term?(iri, index) when is_binary(iri) do
    index != nil and not TermRegistry.member?(index, iri) and
      TermRegistry.in_admitted_namespace?(index, iri)
  end

  def admitted_namespace_but_unknown_term?(_iri, _index), do: false

  @doc """
  Runs the S7.2 public-ontology-first resolution sequence for one concept.

  ## Options

    * `:index` -- an `AshA2A.Semantic.TermRegistry` built from the admitted,
      pinned local ontology cache. Required; without it there is nothing to
      search and the sequence is refused (`:public_index_required`) rather than
      skipped straight to minting.
    * `:sufficient?` -- `true` (default) or `false`. Step 2's explicit
      sufficiency decision for an exact public match.
    * `:accept_equivalent?` -- `true` (default) or `false`. Step 3's decision.
      Step 3 finds equivalents by textual similarity, which is never identity:
      one equivalent is reused only when `:mappings` names exactly one of them
      with an admission receipt; otherwise `:equivalent_requires_admitted_mapping`.
    * `:composition` -- a list of two or more public IRIs when the concept
      genuinely needs several public models. Triggers step 4, which requires an
      explicit, admitted mapping (carrying `:admission_receipt`) for each
      composed IRI (`:composition_mapping_unadmitted` otherwise).
    * `:mappings` -- explicit mappings used by steps 3 and 4.
    * `:private_term` -- an `%AshA2A.Semantic.Iri.PrivateTerm{}` (or the
      attribute map for one) used by step 5.
    * `:public_insufficient_reason` -- a non-empty written reason. Required
      before step 5 may run when step 1 or 3 found any public candidate.
  """
  @spec resolve(String.t() | map(), keyword()) :: {:ok, Resolution.t()} | {:error, refusal()}
  def resolve(concept, opts \\ [])

  def resolve(label, opts) when is_binary(label), do: resolve(%{label: label}, opts)

  def resolve(%{} = concept, opts) do
    result = do_resolve(concept, opts)

    # RFC-SA2A-002 §12 attempt evidence, emitted where the resolution is decided.
    :telemetry.execute([:ash_a2a, :semantic, :iri, :resolve], %{}, %{
      outcome:
        with({:ok, %Resolution{outcome: outcome}} <- result, do: outcome, else: (_ -> :refused)),
      step: with({:ok, %Resolution{step: step}} <- result, do: step, else: (_ -> nil)),
      code: with({:error, %{code: code}} <- result, do: code, else: (_ -> nil))
    })

    result
  end

  defp do_resolve(concept, opts) do
    label = concept[:label] || concept["label"]

    case Keyword.get(opts, :index) do
      %TermRegistry{} = index when is_binary(label) and label != "" ->
        run_sequence(label, index, opts)

      %TermRegistry{} ->
        {:error, refusal(:concept_label_missing, "concept must carry a non-empty :label")}

      _ ->
        {:error,
         refusal(
           :public_index_required,
           "resolve/2 requires :index (an AshA2A.Semantic.TermRegistry over the admitted, " <>
             "pinned local ontology cache) -- public search cannot be skipped on the way to minting"
         )}
    end
  end

  @doc """
  Mints a private IRI, and refuses to do so without every S7.2 required field.

  Accepts a `%PrivateTerm{}` or the attribute map for one. A map missing any
  required key is refused with `:private_term_incomplete` naming the exact
  missing fields (rather than raising the `@enforce_keys` error), so callers
  get a typed refusal on the normal path.
  """
  @spec mint_private(PrivateTerm.t() | map()) :: {:ok, PrivateTerm.t()} | {:error, refusal()}
  def mint_private(term) do
    result = do_mint_private(term)

    # RFC-SA2A-002 §12 attempt evidence, emitted where the mint is decided.
    :telemetry.execute([:ash_a2a, :semantic, :iri, :mint_private], %{}, %{
      outcome: if(match?({:ok, _}, result), do: :minted, else: :refused),
      code: with({:error, %{code: code}} <- result, do: code, else: (_ -> nil))
    })

    result
  end

  defp do_mint_private(%PrivateTerm{} = term) do
    with {:ok, iri} <- validate(term.iri),
         :ok <- check_private_scope(term.scope),
         :ok <- check_owning_namespace(term, iri),
         :ok <- check_non_empty(term.label, :label),
         :ok <- check_non_empty(term.definition, :definition),
         :ok <- check_version(term.version),
         :ok <- check_provenance(term.provenance),
         :ok <- check_mappings(term.mappings),
         :ok <- check_receipt(term.admission_receipt) do
      {:ok, %{term | iri: iri}}
    end
  end

  defp do_mint_private(%{} = attrs) do
    required = PrivateTerm.__struct__() |> Map.from_struct() |> Map.keys()

    missing =
      Enum.filter(required, fn key ->
        is_nil(Map.get(attrs, key)) and is_nil(Map.get(attrs, Atom.to_string(key)))
      end)

    if missing == [] do
      normalized =
        Enum.reduce(required, %{}, fn key, acc ->
          Map.put(acc, key, Map.get(attrs, key) || Map.get(attrs, Atom.to_string(key)))
        end)

      do_mint_private(struct!(PrivateTerm, normalized))
    else
      {:error,
       refusal(
         :private_term_incomplete,
         "a private term is not mintable without " <>
           "#{missing |> Enum.sort() |> Enum.map_join(", ", &inspect/1)} (RFC S7.2 requires " <>
           "provenance, scope, owning namespace, definition, mappings, version and an " <>
           "admission receipt)"
       )}
    end
  end

  defp do_mint_private(other),
    do:
      {:error,
       refusal(
         :private_term_incomplete,
         "expected a PrivateTerm or attribute map, got #{inspect(other)}"
       )}

  @doc "Allowed SKOS-aligned mapping kinds for a private term's declared mappings."
  @spec mapping_kinds() :: [atom()]
  def mapping_kinds, do: @mapping_kinds

  # -- the five steps ---------------------------------------------------------

  defp run_sequence(label, index, opts) do
    # Step 1: search admitted public semantic sources for an exact concept.
    exact = TermRegistry.search_exact(index, label)
    attempted = [1]

    cond do
      # Step 2: reuse the existing public IRI if sufficient.
      match?([_], exact) and Keyword.get(opts, :sufficient?, true) ->
        {:ok,
         %Resolution{
           step: 2,
           outcome: :reused_public_iri,
           iri: hd(exact),
           steps_attempted: attempted ++ [2],
           exact_matches: exact
         }}

      true ->
        continue_after_reuse(label, index, opts, exact, attempted ++ [2])
    end
  end

  defp continue_after_reuse(label, index, opts, exact, attempted) do
    # Step 3: search for an equivalent or composable public representation.
    equivalent = TermRegistry.search_equivalent(index, label)
    attempted = attempted ++ [3]

    cond do
      equivalent != [] and Keyword.get(opts, :accept_equivalent?, true) and
          Keyword.get(opts, :composition) == nil ->
        adopt_equivalent(equivalent, Keyword.get(opts, :mappings, []), exact, attempted)

      true ->
        continue_after_equivalent(index, opts, exact, equivalent, attempted)
    end
  end

  # Step 3 search is textual (label/local-name containment), so its results are
  # candidates, never identity: `label_A ~ label_B` does not imply
  # `meaning_A == meaning_B` (RFC S47, RFC-SA2A-002 §51 SA2A-NS-003). One
  # equivalent is reused only when an explicit, admitted mapping names it.
  defp adopt_equivalent(equivalent, mappings, exact, attempted) do
    admitted =
      Enum.filter(List.wrap(mappings), fn mapping ->
        is_map(mapping) and (mapping[:target] || mapping["target"]) in equivalent and
          check_receipt(mapping[:admission_receipt] || mapping["admission_receipt"]) == :ok
      end)

    case admitted |> Enum.map(&(&1[:target] || &1["target"])) |> Enum.uniq() do
      [iri] ->
        with :ok <- check_mappings(admitted) do
          {:ok,
           %Resolution{
             step: 3,
             outcome: :reused_equivalent_public_iri,
             iri: iri,
             mappings: admitted,
             steps_attempted: attempted,
             exact_matches: exact,
             equivalent_matches: equivalent
           }}
        end

      named ->
        {:error,
         refusal(
           :equivalent_requires_admitted_mapping,
           "step 3 found public terms only by textual similarity (" <>
             Enum.join(equivalent, ", ") <>
             "); similarity is not semantic identity, so exactly one of them must be named by " <>
             "an explicit mapping carrying an admission receipt (admitted mappings named " <>
             "#{length(named)}), or pass accept_equivalent?: false"
         )}
    end
  end

  defp continue_after_equivalent(index, opts, exact, equivalent, attempted) do
    case Keyword.get(opts, :composition) do
      composition when is_list(composition) and length(composition) > 1 ->
        # Step 4: express explicit mappings where multiple public models are required.
        compose(
          index,
          composition,
          Keyword.get(opts, :mappings, []),
          exact,
          equivalent,
          attempted ++ [4]
        )

      nil ->
        mint_step(opts, exact, equivalent, attempted)

      other ->
        {:error,
         refusal(
           :composition_requires_multiple_models,
           ":composition must list two or more public IRIs, got #{inspect(other)}"
         )}
    end
  end

  defp compose(index, composition, mappings, exact, equivalent, attempted) do
    with :ok <- all_public?(index, composition),
         :ok <- mappings_cover(composition, mappings) do
      {:ok,
       %Resolution{
         step: 4,
         outcome: :composed_public_models,
         iris: composition,
         mappings: mappings,
         steps_attempted: attempted,
         exact_matches: exact,
         equivalent_matches: equivalent
       }}
    end
  end

  defp mint_step(opts, exact, equivalent, attempted) do
    candidates = exact ++ equivalent
    reason = Keyword.get(opts, :public_insufficient_reason)

    cond do
      candidates != [] and not written_reason?(reason) ->
        {:error,
         refusal(
           :private_mint_refused_public_available,
           "refusing to mint a private IRI: public search found " <>
             "#{candidates |> Enum.sort() |> Enum.map_join(", ", & &1)}. RFC S7.2 permits minting " <>
             "only when a public term is genuinely absent or the concept is organization-private; " <>
             "supply :public_insufficient_reason in writing to record why reuse fails"
         )}

      Keyword.get(opts, :private_term) == nil ->
        {:error,
         refusal(
           :private_term_incomplete,
           "step 5 requires :private_term (provenance, scope, owning namespace, definition, " <>
             "mappings, version, admission receipt)"
         )}

      true ->
        case do_mint_private(Keyword.fetch!(opts, :private_term)) do
          {:ok, term} ->
            {:ok,
             %Resolution{
               step: 5,
               outcome: :minted_private_iri,
               iri: term.iri,
               private_term: term,
               steps_attempted: attempted ++ [5],
               exact_matches: exact,
               equivalent_matches: equivalent
             }}

          {:error, _} = error ->
            error
        end
    end
  end

  # -- validation internals ---------------------------------------------------

  defp validate_absolute(value) do
    case String.split(value, ":", parts: 2) do
      [scheme, rest] when rest != "" ->
        if Regex.match?(@scheme_pattern, scheme) do
          {:ok, value}
        else
          {:error,
           refusal(
             :iri_invalid_scheme,
             "IRI #{inspect(value)} has invalid scheme #{inspect(scheme)}"
           )}
        end

      _ ->
        {:error,
         refusal(
           :iri_not_absolute,
           "IRI #{inspect(value)} is not absolute: an absolute IRI needs a scheme and a " <>
             "non-empty scheme-specific part"
         )}
    end
  end

  defp has_excluded?(value) do
    value
    |> String.to_charlist()
    |> Enum.any?(fn char -> char <= 0x20 or char == 0x7F or char in @excluded end)
  end

  defp check_private_scope(scope) when scope in @private_scopes, do: :ok

  defp check_private_scope(scope),
    do:
      {:error,
       refusal(
         :private_term_scope_invalid,
         "a minted term's scope must be one of #{inspect(@private_scopes)} (a public scope is " <>
           "not mintable -- reuse the public IRI), got #{inspect(scope)}"
       )}

  defp check_owning_namespace(term, iri) do
    with {:ok, namespace} <- validate(term.owning_namespace) do
      if String.starts_with?(iri, namespace) do
        :ok
      else
        {:error,
         refusal(
           :private_term_namespace_mismatch,
           "minted IRI #{iri} is not inside its declared owning namespace #{namespace}"
         )}
      end
    end
  end

  defp check_non_empty(value, field) when is_binary(value) do
    if String.trim(value) == "" do
      {:error, refusal(:private_term_incomplete, "#{inspect(field)} must be a non-empty string")}
    else
      :ok
    end
  end

  defp check_non_empty(value, field),
    do:
      {:error,
       refusal(
         :private_term_incomplete,
         "#{inspect(field)} must be a string, got #{inspect(value)}"
       )}

  defp check_version(version) when is_binary(version) do
    if version in @placeholder_versions do
      {:error,
       refusal(
         :private_term_version_unpinned,
         "version #{inspect(version)} is a moving pointer, not a pin (RFC S45 requires an " <>
           "immutable revision identity)"
       )}
    else
      :ok
    end
  end

  defp check_version(version),
    do:
      {:error,
       refusal(
         :private_term_version_unpinned,
         "version must be a string, got #{inspect(version)}"
       )}

  defp check_provenance(%{} = provenance) do
    searched = provenance[:searched_sources] || provenance["searched_sources"]
    reason = provenance[:public_absence_reason] || provenance["public_absence_reason"]

    cond do
      not (is_list(searched) and searched != []) ->
        {:error,
         refusal(
           :private_mint_search_unrecorded,
           "provenance must record :searched_sources -- a non-empty list of the admitted public " <>
             "sources actually searched before minting (RFC S7.2 step 1)"
         )}

      not written_reason?(reason) ->
        {:error,
         refusal(
           :private_mint_search_unrecorded,
           "provenance must record :public_absence_reason in writing: why no public term was " <>
             "sufficient (RFC S7.2 step 5)"
         )}

      true ->
        :ok
    end
  end

  defp check_provenance(provenance),
    do:
      {:error,
       refusal(
         :private_term_incomplete,
         "provenance must be a map carrying :searched_sources and :public_absence_reason, got " <>
           inspect(provenance)
       )}

  defp check_mappings(mappings) when is_list(mappings) do
    Enum.reduce_while(mappings, :ok, fn mapping, :ok ->
      target = mapping[:target] || mapping["target"]
      kind = mapping[:kind] || mapping["kind"]

      cond do
        not valid?(target) ->
          {:halt,
           {:error,
            refusal(
              :private_term_mapping_invalid,
              "mapping target is not a valid IRI: #{inspect(target)}"
            )}}

        kind not in @mapping_kinds ->
          {:halt,
           {:error,
            refusal(
              :private_term_mapping_invalid,
              "mapping kind #{inspect(kind)} must be one of #{inspect(@mapping_kinds)}"
            )}}

        true ->
          {:cont, :ok}
      end
    end)
  end

  defp check_mappings(mappings),
    do:
      {:error,
       refusal(
         :private_term_incomplete,
         "mappings must be a list (an empty list is an explicit declaration that no public " <>
           "equivalent exists), got #{inspect(mappings)}"
       )}

  defp check_receipt(%AshA2A.Receipt{receipt_id: id, fingerprint: fp})
       when not is_nil(id) and not is_nil(fp),
       do: :ok

  defp check_receipt(%{} = receipt) do
    id = receipt[:receipt_id] || receipt["receipt_id"]
    fingerprint = receipt[:fingerprint] || receipt["fingerprint"]

    if is_binary(id) and id != "" and is_binary(fingerprint) and fingerprint != "" do
      :ok
    else
      {:error,
       refusal(
         :private_term_receipt_missing,
         "admission_receipt must carry a non-empty :receipt_id and :fingerprint (or be an " <>
           "%AshA2A.Receipt{}), got #{inspect(receipt)}"
       )}
    end
  end

  defp check_receipt(receipt),
    do:
      {:error,
       refusal(
         :private_term_receipt_missing,
         "admission_receipt must be an %AshA2A.Receipt{} or a map with :receipt_id and " <>
           ":fingerprint, got #{inspect(receipt)}"
       )}

  defp all_public?(index, iris) do
    case Enum.reject(iris, &TermRegistry.member?(index, &1)) do
      [] ->
        :ok

      missing ->
        {:error,
         refusal(
           :composition_requires_admitted_models,
           "composed IRIs are not in the admitted public index: " <>
             Enum.map_join(Enum.sort(missing), ", ", & &1)
         )}
    end
  end

  defp mappings_cover(composition, mappings) do
    covered = MapSet.new(mappings, fn m -> m[:target] || m["target"] end)

    case Enum.reject(composition, &MapSet.member?(covered, &1)) do
      [] ->
        with :ok <- check_mappings(mappings), do: mappings_admitted(mappings)

      uncovered ->
        {:error,
         refusal(
           :composition_mappings_required,
           "RFC S7.2 step 4 requires an explicit mapping for every composed public model; " <>
             "missing mappings for " <> Enum.map_join(Enum.sort(uncovered), ", ", & &1)
         )}
    end
  end

  # RFC-SA2A-002 §51: explicit mappings are admitted before cross-identity
  # composition -- a mapping without an admission receipt is an assertion.
  defp mappings_admitted(mappings) do
    case Enum.reject(
           mappings,
           &(check_receipt(&1[:admission_receipt] || &1["admission_receipt"]) == :ok)
         ) do
      [] ->
        :ok

      unadmitted ->
        {:error,
         refusal(
           :composition_mapping_unadmitted,
           "RFC S7.2 step 4 composes public models only through admitted mappings; no admission " <>
             "receipt on the mapping(s) to " <>
             Enum.map_join(unadmitted, ", ", &inspect(&1[:target] || &1["target"]))
         )}
    end
  end

  @doc false
  def __sa2a_refusal_codes__,
    do: %{
      equivalent_requires_admitted_mapping: :refused_namespace,
      composition_mapping_unadmitted: :refused_namespace
    }

  defp written_reason?(reason), do: is_binary(reason) and String.trim(reason) != ""

  defp refusal(code, detail), do: %{code: code, detail: detail}
end
