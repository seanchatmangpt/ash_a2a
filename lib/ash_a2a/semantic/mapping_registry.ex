defmodule AshA2A.Semantic.MappingRegistry do
  @moduledoc """
  Cross-peer semantic identity reconciliation (RFC-SA2A-001 S47).

  > No silent semantic drift: two peers claiming the same capability must
  > reference the same semantic identity or an explicitly admitted mapping.
  > `label_A == label_B` does NOT imply `meaning_A == meaning_B`.

  `reconcile/3` implements exactly that, and the interesting case is the one
  that refuses: two peers whose capability *labels* are identical but whose
  semantic IRIs differ, with no admitted mapping between them, are refused with
  `:semantic_label_collision_unmapped`. Matching labels are never taken as
  evidence of matching meaning.

  A mapping is only usable once it has been **admitted**: `register/2` requires
  an admission receipt (an `%AshA2A.Receipt{}` or a map carrying `:receipt_id`
  and `:fingerprint`), so a mapping cannot be asserted into existence at
  runtime any more than a vocabulary term can (see
  `AshA2A.Semantic.TermRegistry` for the S7.3 sibling rule).

  Mapping kinds are SKOS-aligned prior art (`skos:exactMatch`,
  `skos:closeMatch`, `skos:broadMatch`, `skos:narrowMatch`,
  `skos:relatedMatch`) rather than a bespoke vocabulary, and mappings are
  symmetric in lookup with the direction-appropriate kind returned
  (`:broad_match` one way is `:narrow_match` the other).

  Reconciliation reports the kind it relied on, so a caller that requires exact
  identity can gate on `:same_semantic_identity`/`:exact_match` and treat a
  `:close_match` as insufficient for its own purposes.
  """

  alias AshA2A.Semantic.Iri

  @type refusal :: %{code: atom(), detail: String.t()}
  @type kind :: :exact_match | :close_match | :broad_match | :narrow_match | :related_match

  @enforce_keys [:mappings]
  defstruct mappings: %{}

  @type t :: %__MODULE__{}

  @kinds [:exact_match, :close_match, :broad_match, :narrow_match, :related_match]
  @inverse %{
    exact_match: :exact_match,
    close_match: :close_match,
    related_match: :related_match,
    broad_match: :narrow_match,
    narrow_match: :broad_match
  }

  @doc "An empty registry -- with no admitted mappings, only identical IRIs reconcile."
  @spec new() :: t()
  def new, do: %__MODULE__{mappings: %{}}

  @doc """
  Registers one explicitly admitted mapping between two semantic identities.

  Requires: two valid, distinct IRIs, a SKOS-aligned kind, and an admission
  receipt. Returns `{:ok, registry}` or a typed refusal.
  """
  # Two sibling courts observe this one decision under two independently
  # admitted event names and outcome vocabularies --
  # `executable_world.ex` / `shex_shacl_admission_test.exs` on
  # `[:ash_a2a, :semantic, :mapping, :register]` with `outcome: :admitted |
  # :refused`, `public_semantics_namespace.ex` on
  # `[:ash_a2a, :semantic, :mapping_registry, :register]` with
  # `outcome: :registered | :refused`. Both are real projections of the same
  # `decide_register/2` result below, computed once; neither vocabulary is
  # weakened or renamed to match the other.
  @spec register(t(), term()) :: {:ok, t()} | {:error, refusal()}
  def register(%__MODULE__{} = registry, mapping) do
    result = decide_register(registry, mapping)
    admitted? = match?({:ok, _}, result)
    code = with({:error, %{code: code}} <- result, do: code, else: (_ -> nil))

    # Boundary evidence for independent observers (RFC-SA2A-002 §12): the
    # decision this function just made, never an input to it.
    fields = if is_map(mapping), do: mapping, else: %{}

    :telemetry.execute(
      [:ash_a2a, :semantic, :mapping, :register],
      %{system_time: System.system_time()},
      %{
        source: fields[:source] || fields["source"],
        target: fields[:target] || fields["target"],
        kind: fields[:kind] || fields["kind"],
        outcome: if(admitted?, do: :admitted, else: :refused),
        code: code
      }
    )

    # RFC-SA2A-002 §12 attempt evidence, emitted where mapping admission is decided.
    :telemetry.execute([:ash_a2a, :semantic, :mapping_registry, :register], %{}, %{
      outcome: if(admitted?, do: :registered, else: :refused),
      code: code
    })

    result
  end

  defp decide_register(%__MODULE__{} = registry, %{} = mapping) do
    source = mapping[:source] || mapping["source"]
    target = mapping[:target] || mapping["target"]
    kind = mapping[:kind] || mapping["kind"]
    receipt = mapping[:admission_receipt] || mapping["admission_receipt"]

    with {:ok, source} <- Iri.validate(source),
         {:ok, target} <- Iri.validate(target),
         :ok <- check_distinct(source, target),
         :ok <- check_kind(kind),
         :ok <- check_receipt(receipt) do
      record = %{
        source: source,
        target: target,
        kind: kind,
        admission_receipt: receipt,
        note: mapping[:note] || mapping["note"]
      }

      mappings =
        registry.mappings
        |> Map.put({source, target}, record)
        |> Map.put({target, source}, %{
          record
          | source: target,
            target: source,
            kind: Map.fetch!(@inverse, kind)
        })

      {:ok, %{registry | mappings: mappings}}
    end
  end

  defp decide_register(%__MODULE__{}, other),
    do:
      {:error,
       refusal(
         :semantic_mapping_malformed,
         "mapping must be a map with :source, :target, :kind and :admission_receipt, got " <>
           inspect(other)
       )}

  @doc "Looks up an admitted mapping between two semantic identities."
  @spec lookup(t(), String.t(), String.t()) :: {:ok, map()} | :error
  def lookup(%__MODULE__{mappings: mappings}, a, b), do: Map.fetch(mappings, {a, b})

  @doc "All admitted mappings, de-duplicated by unordered pair and sorted."
  @spec mappings(t()) :: [map()]
  def mappings(%__MODULE__{mappings: mappings}) do
    mappings
    |> Map.values()
    |> Enum.uniq_by(fn %{source: s, target: t} -> Enum.sort([s, t]) end)
    |> Enum.sort_by(fn %{source: s, target: t} -> {s, t} end)
  end

  @doc """
  Reconciles two peers' claims about the same capability (RFC S47).

  Each peer is a map carrying at least `:iri` (its semantic identity) and
  usually `:label` and `:peer_id`.

  Returns:

    * `{:ok, %{outcome: :same_semantic_identity, iri: iri, kind: :exact_match}}`
      when both peers reference the same semantic identity;
    * `{:ok, %{outcome: :admitted_mapping, kind: kind, mapping: mapping}}` when
      an explicitly admitted mapping relates them;
    * `{:error, %{code: :semantic_label_collision_unmapped}}` when the labels
      match but the identities differ and no mapping is admitted -- the S47
      case;
    * `{:error, %{code: :semantic_identity_unmapped}}` when neither labels nor
      identities relate them;
    * `{:error, %{code: :semantic_identity_absent}}` when a peer claims a
      capability without any semantic identity at all.
  """
  @spec reconcile(t(), map(), map()) :: {:ok, map()} | {:error, refusal()}
  def reconcile(%__MODULE__{} = registry, %{} = peer_a, %{} = peer_b) do
    result = do_reconcile(registry, peer_a, peer_b)

    # RFC-SA2A-002 §12 attempt evidence, emitted where the S47 decision is made.
    :telemetry.execute([:ash_a2a, :semantic, :mapping_registry, :reconcile], %{}, %{
      outcome: with({:ok, %{outcome: outcome}} <- result, do: outcome, else: (_ -> :refused)),
      code: with({:error, %{code: code}} <- result, do: code, else: (_ -> nil)),
      labels_match: labels_match?(peer_a, peer_b)
    })

    result
  end

  defp do_reconcile(registry, peer_a, peer_b) do
    with {:ok, iri_a} <- peer_iri(peer_a, :a),
         {:ok, iri_b} <- peer_iri(peer_b, :b) do
      cond do
        iri_a == iri_b ->
          {:ok, %{outcome: :same_semantic_identity, iri: iri_a, kind: :exact_match}}

        match?({:ok, _}, lookup(registry, iri_a, iri_b)) ->
          {:ok, mapping} = lookup(registry, iri_a, iri_b)
          {:ok, %{outcome: :admitted_mapping, kind: mapping.kind, mapping: mapping}}

        labels_match?(peer_a, peer_b) ->
          {:error,
           refusal(
             :semantic_label_collision_unmapped,
             "peers #{peer_ref(peer_a)} and #{peer_ref(peer_b)} both claim the label " <>
               "#{inspect(label(peer_a))} but reference different semantic identities " <>
               "(#{iri_a} vs #{iri_b}) with no admitted mapping. RFC S47: label_A == label_B " <>
               "does not imply meaning_A == meaning_B."
           )}

        true ->
          {:error,
           refusal(
             :semantic_identity_unmapped,
             "peers #{peer_ref(peer_a)} and #{peer_ref(peer_b)} reference unrelated semantic " <>
               "identities (#{iri_a} vs #{iri_b}) with no admitted mapping"
           )}
      end
    end
  end

  # -- internals --------------------------------------------------------------

  defp peer_iri(peer, side) do
    case peer[:iri] || peer["iri"] do
      nil ->
        {:error,
         refusal(
           :semantic_identity_absent,
           "peer #{side} (#{peer_ref(peer)}) claims capability #{inspect(label(peer))} with no " <>
             "semantic identity; a label alone is not a semantic identity (RFC S47)"
         )}

      iri ->
        Iri.validate(iri)
    end
  end

  defp labels_match?(a, b) do
    la = label(a)
    lb = label(b)
    is_binary(la) and is_binary(lb) and String.downcase(la) == String.downcase(lb)
  end

  defp label(peer), do: peer[:label] || peer["label"]

  defp peer_ref(peer), do: inspect(peer[:peer_id] || peer["peer_id"] || "<anonymous>")

  defp check_distinct(source, target) when source != target, do: :ok

  defp check_distinct(source, _target),
    do:
      {:error,
       refusal(
         :semantic_mapping_degenerate,
         "a mapping from #{source} to itself carries no information; identical identities " <>
           "reconcile without one"
       )}

  defp check_kind(kind) when kind in @kinds, do: :ok

  defp check_kind(kind),
    do:
      {:error,
       refusal(
         :semantic_mapping_kind_invalid,
         "mapping kind #{inspect(kind)} must be one of the SKOS-aligned kinds #{inspect(@kinds)}"
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
         :semantic_mapping_unadmitted,
         "a cross-peer mapping is only usable once admitted: admission_receipt must carry a " <>
           "non-empty :receipt_id and :fingerprint, got #{inspect(receipt)}"
       )}
    end
  end

  defp check_receipt(receipt),
    do:
      {:error,
       refusal(
         :semantic_mapping_unadmitted,
         "a cross-peer mapping is only usable once admitted: expected an %AshA2A.Receipt{} or a " <>
           "map with :receipt_id and :fingerprint, got #{inspect(receipt)}"
       )}

  defp refusal(code, detail), do: %{code: code, detail: detail}
end
