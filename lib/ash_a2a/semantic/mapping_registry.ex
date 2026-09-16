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

  A mapping is only usable once it has been **admitted**, so a mapping cannot
  be asserted into existence at runtime any more than a vocabulary term can
  (see `AshA2A.Semantic.TermRegistry` for the S7.3 sibling rule).

  ## A named receipt is not a receipt (RFC-SA2A-001 S6)

  `register/2` requires the mapping's `admission_receipt` to be an
  `%AshA2A.Receipt{}` that a receipt store really holds, and that admits
  THIS mapping:

    1. the receipt is fetched back from the registry's receipt store
       (`new/1`'s `:receipt_store`, default the configured
       `config :ash_a2a, :receipt_store`) by its command id -- a receipt no
       store holds is refused `:semantic_mapping_receipt_not_held`, as is a
       map merely carrying a `:receipt_id` and `:fingerprint`;
    2. the held receipt has the same receipt id and fingerprint and a
       terminal status of `:executed` -- the admission really ran
       (`:semantic_mapping_receipt_not_held` otherwise);
    3. the held receipt's `input_digest` is the digest of
       `admission_input/3` for this exact source, target and kind -- a real
       receipt that admitted some OTHER mapping is refused
       `:semantic_mapping_receipt_unbound`.

  Measured before this rule: `register/2` accepted any map with a non-empty
  `:receipt_id` and `:fingerprint` (`CHI-ADM-008`).

  Mapping kinds are SKOS-aligned prior art (`skos:exactMatch`,
  `skos:closeMatch`, `skos:broadMatch`, `skos:narrowMatch`,
  `skos:relatedMatch`) rather than a bespoke vocabulary, and mappings are
  symmetric in lookup with the direction-appropriate kind returned
  (`:broad_match` one way is `:narrow_match` the other).

  Reconciliation reports the kind it relied on, so a caller that requires exact
  identity can gate on `:same_semantic_identity`/`:exact_match` and treat a
  `:close_match` as insufficient for its own purposes.
  """

  alias AshA2A.{Actuation, Receipt}
  alias AshA2A.Semantic.Iri

  @type refusal :: %{code: atom(), detail: String.t()}
  @type kind :: :exact_match | :close_match | :broad_match | :narrow_match | :related_match

  @enforce_keys [:mappings]
  defstruct mappings: %{}, receipt_store: nil

  @type t :: %__MODULE__{}

  @kinds [:exact_match, :close_match, :broad_match, :narrow_match, :related_match]
  @inverse %{
    exact_match: :exact_match,
    close_match: :close_match,
    related_match: :related_match,
    broad_match: :narrow_match,
    narrow_match: :broad_match
  }

  @refusal_codes %{
    semantic_mapping_receipt_not_held: :refused_receipt,
    semantic_mapping_receipt_unbound: :refused_receipt
  }

  @doc false
  def __sa2a_refusal_codes__, do: @refusal_codes

  @doc """
  An empty registry -- with no admitted mappings, only identical IRIs
  reconcile.

  `:receipt_store` -- `module` or `{module, opts}` implementing
  `AshA2A.ReceiptStore`, where admission receipts are looked up; default the
  configured `config :ash_a2a, :receipt_store`
  (`AshA2A.ReceiptStore.Memory`).
  """
  @spec new(keyword()) :: t()
  def new(opts \\ []),
    do: %__MODULE__{mappings: %{}, receipt_store: Keyword.get(opts, :receipt_store)}

  @doc """
  The command input an admission of the mapping `source -> target` of `kind`
  carries. A receipt admits a mapping only when its `input_digest` is
  `AshA2A.Actuation.digest/1` of exactly this term.
  """
  @spec admission_input(String.t(), String.t(), kind()) :: map()
  def admission_input(source, target, kind),
    do: %{semantic_mapping: %{source: source, target: target, kind: kind}}

  @doc """
  Registers one explicitly admitted mapping between two semantic identities.

  Requires: two valid, distinct IRIs, a SKOS-aligned kind, and an admission
  receipt. Returns `{:ok, registry}` or a typed refusal.
  """
  @spec register(t(), term()) :: {:ok, t()} | {:error, refusal()}
  def register(%__MODULE__{} = registry, mapping) do
    result = decide_register(registry, mapping)

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
        outcome: if(match?({:ok, _}, result), do: :admitted, else: :refused),
        code: with({:error, %{code: code}} <- result, do: code, else: (_ -> nil))
      }
    )

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
         :ok <- check_receipt(receipt),
         :ok <- check_held(registry, receipt, admission_input(source, target, kind)) do
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

  # A receipt the store does not hold -- or holds for another admission -- is a
  # name, not a receipt.
  defp check_held(_registry, %{} = receipt, _input) when not is_struct(receipt, Receipt),
    do:
      {:error,
       refusal(
         :semantic_mapping_receipt_not_held,
         "a named receipt is not a receipt (RFC-SA2A-001 S6): #{inspect(receipt)} is not an " <>
           "%AshA2A.Receipt{} any receipt store can be asked for"
       )}

  defp check_held(registry, %Receipt{} = receipt, input) do
    {module, store_opts} = receipt_store(registry)

    case fetch_held(module, receipt.command_id, store_opts) do
      {:ok, %Receipt{} = held} ->
        cond do
          held.receipt_id != receipt.receipt_id or held.fingerprint != receipt.fingerprint ->
            {:error,
             refusal(
               :semantic_mapping_receipt_not_held,
               "the receipt store #{inspect(module)} holds a different receipt for command " <>
                 "#{inspect(receipt.command_id)}"
             )}

          held.terminal_status != :executed ->
            {:error,
             refusal(
               :semantic_mapping_receipt_not_held,
               "the held admission receipt is not executed (terminal status " <>
                 "#{inspect(held.terminal_status)})"
             )}

          held.input_digest != Actuation.digest(input) ->
            {:error,
             refusal(
               :semantic_mapping_receipt_unbound,
               "the held receipt #{inspect(held.receipt_id)} admits a different input than " <>
                 "this mapping (#{inspect(input)})"
             )}

          true ->
            :ok
        end

      other ->
        {:error,
         refusal(
           :semantic_mapping_receipt_not_held,
           "no receipt store holds receipt #{inspect(receipt.receipt_id)} for command " <>
             "#{inspect(receipt.command_id)} (#{inspect(module)}: #{inspect(other, limit: 5)})"
         )}
    end
  end

  defp receipt_store(%__MODULE__{receipt_store: {module, opts}}) when is_atom(module),
    do: {module, opts}

  defp receipt_store(%__MODULE__{receipt_store: module}) when is_atom(module) and module != nil,
    do: {module, []}

  defp receipt_store(%__MODULE__{}),
    do: {Application.get_env(:ash_a2a, :receipt_store, AshA2A.ReceiptStore.Memory), []}

  # A store that is not running holds nothing: fail closed, never raise.
  defp fetch_held(module, command_id, opts) do
    module.fetch(command_id, opts)
  rescue
    exception -> {:unavailable, Exception.message(exception)}
  catch
    :exit, reason -> {:unavailable, reason}
  end

  defp refusal(code, detail), do: %{code: code, detail: detail}
end
