defmodule AshA2A.Receipt.Binding do
  @moduledoc """
  RFC-SA2A-002 §40 (Gate 9) complete receipt identity binding, with the §128
  evidence-laundering posture.

  A receipt's standing rests on the identity it binds. The binding covers
  every field §40 names, each digested separately so a refusal can name the
  tampered field:

  | bound field             | receipt source                                                   |
  |-------------------------|------------------------------------------------------------------|
  | `:receipt_identity`     | `receipt_id`, `command_id`, `execution_id`, `task_id`, `agent_id`, `principal_id` |
  | `:actor`                | `actor`                                                          |
  | `:semantic_subject`     | `semantic_subject`                                               |
  | `:capability_action`    | `capability_id`, `consequence`, `fingerprint`                    |
  | `:input_digest`         | `input_digest`                                                   |
  | `:plan_digest`          | `plan_digest`                                                    |
  | `:projection_digest`    | `projection_digest`                                              |
  | `:authority_grant`      | `authority_grant`                                                |
  | `:idempotency_identity` | `actuation_id`, `idempotency_key`                                |
  | `:intended_effect`      | `intended_effect`                                                |
  | `:result_identity`      | `status`, `terminal_status`, `reply`, `metadata.postcondition` (`:not_yet_observed` on the prepared anchor) |

  The receipt chain predecessor is carried by each link and digested into it.

  ## Chain

  `bind/2` (called by `AshA2A.Receipt.pending/4`) writes the **prepared**
  root link. Every lawful mutation of a bound field afterwards
  (`finalize/2`, a postcondition contradiction, deduplication, outbox
  reconciliation, compensation, an unknown outcome) appends a link through
  `transition/4`, whose predecessor is the previous link's digest.

  `transition/4` first checks the *prior* receipt. A tampered receipt is
  never resealed by a lawful transition: its old binding is carried forward
  unchanged, so the transitioned receipt still refuses.

  ## Exact-term digests (§128)

  Field digests are SHA-256 over `:erlang.term_to_binary/2` with
  `:deterministic` -- an injective encoding. A bound field re-encoded as a
  keyword list, a list of string-keyed pairs, a JSON-style string-keyed map,
  an external identity string, or nested one level deeper is a different term
  and therefore a different digest. No normalization collapses two
  encodings a consumer would read differently into one verifying value.

  ## Keyed MAC

  When `config :ash_a2a, :receipt_binding_key` holds a non-empty binary, link
  digests are HMAC-SHA256 under that key (`algorithm: "hmac-sha256"`,
  `keyed: true`, `key_id` a fingerprint of the key -- never the key). With
  no key, links are unkeyed SHA-256 and the binding records `keyed: false`;
  it is never described as keyed. Unkeyed binding detects accidental and
  partial tampering; a writer who rewrites a field *and* recomputes every
  digest defeats it -- only the keyed mode closes that, and only against a
  writer who does not hold the key.

  Verification is fail-closed on key posture:

    * keyed binding, no key configured -> `:receipt_binding_key_unavailable`
    * keyed binding, different key -> `:receipt_binding_key_mismatch`
    * unkeyed binding while a key is configured -> `:receipt_binding_downgraded`
    * `keyed: true` without HMAC material -> `:receipt_binding_keyed_claim_unbacked`

  ## Telemetry

    * `[:ash_a2a, :receipt, :binding, :bind]` -- every bind/transition, with
      `outcome: :bound | :not_resealed | :unbound`
    * `[:ash_a2a, :receipt, :binding, :verify]` -- every `verify/2` decision,
      with `outcome: :verified | :refused`, the refusal `code` and tampered
      `fields`
  """

  alias AshA2A.{Identity, Receipt}

  @version 1
  @domain "ash_a2a.receipt.binding.v1"

  @fields [
    :receipt_identity,
    :actor,
    :semantic_subject,
    :capability_action,
    :input_digest,
    :plan_digest,
    :projection_digest,
    :authority_grant,
    :idempotency_identity,
    :intended_effect,
    :result_identity
  ]

  @transition_stages [
    :final,
    :postcondition,
    :deduplicated,
    :reconciled,
    :compensated,
    :unknown_outcome
  ]

  @stages [:prepared | @transition_stages]

  @refusal_codes %{
    receipt_unbound: :refused_receipt,
    receipt_binding_malformed: :refused_receipt,
    receipt_binding_field_mismatch: :refused_receipt,
    receipt_binding_digest_mismatch: :refused_receipt,
    receipt_binding_chain_broken: :refused_receipt,
    receipt_binding_result_unbound: :refused_receipt,
    receipt_binding_key_mismatch: :refused_receipt,
    receipt_binding_downgraded: :refused_receipt,
    receipt_binding_keyed_claim_unbacked: :refused_provenance,
    receipt_binding_key_unavailable: :blocked_resource
  }

  @type binding :: %{
          version: pos_integer(),
          algorithm: String.t(),
          keyed: boolean(),
          key_id: String.t() | nil,
          fields: %{atom() => String.t()},
          links: [%{stage: atom(), predecessor: String.t() | nil, digest: String.t()}]
        }

  @type refusal :: {:error, %{code: atom(), detail: term()}}

  @doc "The bound fields, in RFC-SA2A-002 §40 order."
  @spec fields() :: [atom()]
  def fields, do: @fields

  @doc "Link stages: `:prepared` plus every lawful transition."
  @spec stages() :: [atom()]
  def stages, do: @stages

  @doc "Refusal codes this module introduces, with their S42 class."
  @spec refusal_codes() :: %{atom() => atom()}
  def refusal_codes, do: @refusal_codes

  @doc false
  def __sa2a_refusal_codes__, do: @refusal_codes

  @doc "The configured MAC key (`:ash_a2a, :receipt_binding_key`), or `nil`."
  @spec configured_key() :: binary() | nil
  def configured_key do
    case Application.get_env(:ash_a2a, :receipt_binding_key) do
      key when is_binary(key) and byte_size(key) > 0 -> key
      _ -> nil
    end
  end

  @doc "A non-secret fingerprint naming `key` (never the key itself)."
  @spec key_id(binary()) :: String.t()
  def key_id(key) when is_binary(key) do
    "hmac-sha256:" <>
      (:crypto.hash(:sha256, "ash_a2a.receipt.binding.key_id:" <> key)
       |> Base.encode16(case: :lower)
       |> binary_part(0, 16))
  end

  @doc """
  Writes the prepared root link. Options: `:key` (defaults to
  `configured_key/0`; `nil` binds unkeyed), `:predecessor` (the receipt chain
  predecessor digest, default `nil`).
  """
  @spec bind(Receipt.t(), keyword()) :: Receipt.t()
  def bind(%Receipt{} = receipt, opts \\ []) do
    key = key_opt(opts)
    fields = field_digests(receipt, :prepared)
    link = link(:prepared, Keyword.get(opts, :predecessor), fields, key)

    binding = %{
      version: @version,
      algorithm: algorithm(key),
      keyed: key != nil,
      key_id: key && key_id(key),
      fields: fields,
      links: [link]
    }

    emit_bind(receipt, :prepared, :bound, binding, nil)
    %{receipt | binding: binding}
  end

  @doc """
  Appends a `stage` link to `next`, the lawful successor of `prior`.

  `prior` must itself verify; otherwise `next` keeps `prior`'s binding
  unchanged (and so still refuses). An unbound `prior` yields an unbound
  `next` -- a transition never invents a binding.
  """
  @spec transition(Receipt.t(), Receipt.t(), atom(), keyword()) :: Receipt.t()
  def transition(%Receipt{} = prior, %Receipt{} = next, stage, opts \\ [])
      when stage in @transition_stages do
    case Map.get(prior, :binding) do
      nil ->
        emit_bind(next, stage, :unbound, nil, nil)
        %{next | binding: nil}

      binding ->
        key = key_opt(opts)

        case check(prior, key: key) do
          {:ok, _report} ->
            fields = field_digests(next, stage)
            head = List.last(binding.links)

            sealed = %{
              binding
              | fields: fields,
                links: binding.links ++ [link(stage, head.digest, fields, key)]
            }

            emit_bind(next, stage, :bound, sealed, nil)
            %{next | binding: sealed}

          {:error, %{code: code}} ->
            emit_bind(next, stage, :not_resealed, binding, code)
            %{next | binding: binding}
        end
    end
  end

  @doc """
  Verifies `receipt`'s binding and emits the decision. Returns
  `{:ok, report}` (the head stage/digest, keyed posture and the receipt's
  store standing) or a typed refusal; a refused receipt has no standing.
  """
  @spec verify(Receipt.t() | map(), keyword()) :: {:ok, map()} | refusal()
  def verify(receipt, opts \\ []) do
    key = key_opt(opts)
    result = check(receipt, key: key)
    emit_verify(receipt, result, key)
    result
  end

  @doc "`verify/2` without telemetry (used inside transitions and replay)."
  @spec check(Receipt.t() | map(), keyword()) :: {:ok, map()} | refusal()
  def check(receipt, opts \\ [])

  def check(%Receipt{} = receipt, opts) do
    key = key_opt(opts)

    with {:ok, binding} <- well_formed(Map.get(receipt, :binding)),
         :ok <- keyed_claim(binding),
         :ok <- key_posture(binding, key),
         head = List.last(binding.links),
         current = field_digests(receipt, head.stage),
         :ok <- fields_match(binding.fields, current),
         :ok <- head_matches(head, current, key),
         :ok <- chain_intact(binding.links, receipt, key),
         :ok <- result_bound(receipt, head) do
      {:ok,
       %{
         stage: head.stage,
         digest: head.digest,
         links: length(binding.links),
         keyed: binding.keyed,
         key_id: binding.key_id,
         standing: receipt.standing
       }}
    end
  end

  def check(_not_a_receipt, _opts),
    do: refuse(:receipt_binding_malformed, "not an AshA2A.Receipt")

  @doc "Per-field digests of `receipt` as bound at `stage`."
  @spec field_digests(Receipt.t(), atom()) :: %{atom() => String.t()}
  def field_digests(%Receipt{} = receipt, stage) when stage in @stages do
    Map.new(@fields, fn field ->
      {field, sha256({@domain, field, field_value(receipt, field, stage)})}
    end)
  end

  # --- field extraction -------------------------------------------------------

  defp field_value(r, :receipt_identity, _stage) do
    {get(r, :receipt_id), get(r, :command_id), get(r, :execution_id), get(r, :task_id),
     get(r, :agent_id), get(r, :principal_id)}
  end

  defp field_value(r, :capability_action, _stage),
    do: {get(r, :capability_id), get(r, :consequence), get(r, :fingerprint)}

  defp field_value(r, :idempotency_identity, _stage),
    do: {get(r, :actuation_id), get(r, :idempotency_key)}

  defp field_value(_r, :result_identity, :prepared), do: :not_yet_observed

  defp field_value(r, :result_identity, _stage) do
    postcondition =
      case get(r, :metadata) do
        %{} = metadata -> Map.get(metadata, :postcondition)
        _ -> nil
      end

    {get(r, :status), get(r, :terminal_status), get(r, :reply), postcondition}
  end

  defp field_value(r, field, _stage), do: get(r, field)

  defp get(receipt, key), do: Map.get(receipt, key)

  # --- checks -----------------------------------------------------------------

  defp well_formed(nil),
    do: refuse(:receipt_unbound, "the receipt carries no identity binding; it has no standing")

  defp well_formed(
         %{
           version: @version,
           algorithm: algorithm,
           keyed: keyed,
           key_id: key_id,
           fields: %{} = fields,
           links: [_ | _] = links
         } = binding
       )
       when algorithm in ["sha256", "hmac-sha256"] and is_boolean(keyed) and
              (is_nil(key_id) or is_binary(key_id)) do
    fields_ok? =
      Enum.sort(Map.keys(fields)) == Enum.sort(@fields) and
        Enum.all?(Map.values(fields), &is_binary/1)

    links_ok? =
      Enum.all?(links, fn
        %{stage: stage, digest: digest, predecessor: predecessor}
        when stage in @stages and is_binary(digest) and
               (is_nil(predecessor) or is_binary(predecessor)) ->
          true

        _ ->
          false
      end)

    if fields_ok? and links_ok?,
      do: {:ok, binding},
      else: refuse(:receipt_binding_malformed, "binding fields or links are malformed")
  end

  defp well_formed(_other),
    do: refuse(:receipt_binding_malformed, "binding is not a version-#{@version} binding map")

  defp keyed_claim(%{keyed: true} = binding) do
    if binding.algorithm == "hmac-sha256" and is_binary(binding.key_id) and
         Enum.all?(binding.links, &String.starts_with?(&1.digest, "hmac-sha256:")),
       do: :ok,
       else:
         refuse(
           :receipt_binding_keyed_claim_unbacked,
           "binding claims keyed but carries no HMAC-SHA256 material"
         )
  end

  defp keyed_claim(%{keyed: false} = binding) do
    if binding.algorithm == "sha256" and is_nil(binding.key_id) and
         Enum.all?(binding.links, &String.starts_with?(&1.digest, "sha256:")),
       do: :ok,
       else: refuse(:receipt_binding_malformed, "unkeyed binding carries keyed material")
  end

  defp key_posture(%{keyed: true}, nil),
    do:
      refuse(
        :receipt_binding_key_unavailable,
        "keyed binding cannot be verified without :ash_a2a, :receipt_binding_key"
      )

  defp key_posture(%{keyed: true, key_id: key_id}, key) do
    if key_id(key) == key_id,
      do: :ok,
      else: refuse(:receipt_binding_key_mismatch, %{bound: key_id, configured: key_id(key)})
  end

  defp key_posture(%{keyed: false}, nil), do: :ok

  defp key_posture(%{keyed: false}, _key),
    do:
      refuse(
        :receipt_binding_downgraded,
        "a receipt binding key is configured; an unkeyed binding does not verify"
      )

  defp fields_match(bound, current) do
    case Enum.filter(@fields, &(Map.get(bound, &1) != Map.get(current, &1))) do
      [] -> :ok
      fields -> refuse(:receipt_binding_field_mismatch, %{fields: fields})
    end
  end

  defp head_matches(head, current, key) do
    if link(head.stage, head.predecessor, current, key).digest == head.digest,
      do: :ok,
      else: refuse(:receipt_binding_digest_mismatch, %{stage: head.stage})
  end

  defp chain_intact([root | rest], receipt, key) do
    prepared = link(:prepared, root.predecessor, field_digests(receipt, :prepared), key)

    cond do
      root.stage != :prepared ->
        refuse(:receipt_binding_chain_broken, "the chain does not start at a prepared anchor")

      prepared.digest != root.digest ->
        refuse(
          :receipt_binding_chain_broken,
          "the prepared anchor does not bind this receipt's identity"
        )

      true ->
        rest
        |> Enum.reduce_while(root, fn link, previous ->
          if link.stage in @transition_stages and link.predecessor == previous.digest,
            do: {:cont, link},
            else: {:halt, :broken}
        end)
        |> case do
          :broken ->
            refuse(:receipt_binding_chain_broken, "a link does not name its predecessor")

          _head ->
            :ok
        end
    end
  end

  defp result_bound(receipt, %{stage: :prepared}) do
    if Map.get(receipt, :status) == :pending,
      do: :ok,
      else:
        refuse(
          :receipt_binding_result_unbound,
          "a receipt with an observed result is bound only by its prepared anchor"
        )
  end

  defp result_bound(_receipt, _head), do: :ok

  # --- digests ----------------------------------------------------------------

  defp link(stage, predecessor, fields, key) do
    payload =
      :erlang.term_to_binary(
        {@domain, @version, stage, predecessor, Enum.sort(fields), key != nil,
         key && key_id(key)},
        [:deterministic]
      )

    %{stage: stage, predecessor: predecessor, digest: mac(payload, key)}
  end

  defp mac(payload, nil),
    do: "sha256:" <> Base.encode16(:crypto.hash(:sha256, payload), case: :lower)

  defp mac(payload, key),
    do: "hmac-sha256:" <> Base.encode16(:crypto.mac(:hmac, :sha256, key, payload), case: :lower)

  defp sha256(term) do
    "sha256:" <>
      (term
       |> :erlang.term_to_binary([:deterministic])
       |> then(&:crypto.hash(:sha256, &1))
       |> Base.encode16(case: :lower))
  end

  defp algorithm(nil), do: "sha256"
  defp algorithm(_key), do: "hmac-sha256"

  defp key_opt(opts) do
    case Keyword.fetch(opts, :key) do
      {:ok, key} when is_binary(key) and byte_size(key) > 0 -> key
      {:ok, _absent} -> nil
      :error -> configured_key()
    end
  end

  defp refuse(code, detail), do: {:error, %{code: code, detail: detail}}

  # --- telemetry --------------------------------------------------------------

  defp emit_bind(receipt, stage, outcome, binding, code) do
    :telemetry.execute(
      [:ash_a2a, :receipt, :binding, :bind],
      %{system_time: System.system_time()},
      Map.merge(subject(receipt), %{
        stage: stage,
        outcome: outcome,
        code: code,
        keyed: binding && binding.keyed,
        links: binding && length(binding.links)
      })
    )
  end

  defp emit_verify(receipt, result, key) do
    decision =
      case result do
        {:ok, report} ->
          %{outcome: :verified, code: nil, fields: nil, stage: report.stage, keyed: report.keyed}

        {:error, %{code: code, detail: detail}} ->
          fields =
            case detail do
              %{fields: fields} -> Enum.map_join(fields, ",", &Atom.to_string/1)
              _ -> nil
            end

          %{outcome: :refused, code: code, fields: fields, stage: nil, keyed: nil}
      end

    :telemetry.execute(
      [:ash_a2a, :receipt, :binding, :verify],
      %{system_time: System.system_time()},
      receipt
      |> subject()
      |> Map.merge(decision)
      |> Map.put(:key_configured, key != nil)
    )
  end

  defp subject(receipt) when is_map(receipt) do
    %{
      receipt_id: external(Map.get(receipt, :receipt_id)),
      command_id: external(Map.get(receipt, :command_id)),
      capability_id: text(Map.get(receipt, :capability_id))
    }
  end

  defp subject(_other), do: %{receipt_id: nil, command_id: nil, capability_id: nil}

  defp external(%Identity{} = identity), do: Identity.external(identity)
  defp external(value) when is_binary(value), do: value
  defp external(_other), do: nil

  defp text(value) when is_binary(value), do: value
  defp text(_other), do: nil
end
