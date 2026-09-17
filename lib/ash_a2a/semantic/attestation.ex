defmodule AshA2A.Semantic.Attestation do
  @moduledoc """
  RFC-SA2A-001 S33 semantic attestation.

  An attestation identifies, for one semantic execution:

    * the exact semantic revision (`:semantic_revision` -- the graph digest)
    * the exact plan revision (`:plan_revision`)
    * the exact manufacturer revision (`:manufacturer_revision`)
    * the exact projected artifact digest (`:projected_artifact_digest`)
    * the exact authority decision (`:authority_decision`)
    * the exact receipt set (`:receipt_set` and `:receipt_set_digest`)
    * the observed post-state (`:observed_post_state`)

  ## The central rule: an attestation MUST NOT claim evidence beyond what was observed

  This is enforced, not documented. `from_receipts/2` derives every field
  *only* from the receipts it was handed. A field the receipts do not support
  stays `nil` and its name is listed in `:unobserved`. `verify/1` then
  re-checks that every non-nil field is backed by the receipt set, so an
  attestation that was hand-built or edited after the fact fails
  `verify/1` with `:attestation_claims_unobserved_evidence` naming the exact
  field.

  Consequently `:unobserved` is a first-class part of the attestation, not an
  error path. An attestation over an unplanned, non-semantic command is a
  perfectly valid attestation that says so:

      %Attestation{semantic_revision: nil, plan_revision: nil,
                   unobserved: [:semantic_revision, :plan_revision, ...]}

  ## Receipt binding (RFC-SA2A-002 §40, §72)

  Every receipt carrying an identity binding must verify
  (`AshA2A.Receipt.Binding.verify/2`); a tampered receipt refuses the whole
  attestation (`:attestation_receipt_binding_refused`). `:receipt_binding` is
  claimed only when *every* receipt is bound and verifies, and records the
  observed keyed posture -- an attestation over an unbound receipt leaves it
  unclaimed rather than implying tamper evidence it never had.

  Decisions are emitted as `[:ash_a2a, :attestation, :build]` and
  `[:ash_a2a, :attestation, :verify]`.

  ## Evidence class

  `:evidence_class` is the *weakest* class across the receipt set, not the
  strongest. An attestation is only as good as its weakest supporting receipt;
  taking the maximum would be exactly the S70 promotion-without-evidence move.
  """

  alias AshA2A.{Actuation, Evidence, Receipt}
  alias AshA2A.Receipt.Replay

  @claimable [
    :semantic_revision,
    :plan_revision,
    :manufacturer_revision,
    :projected_artifact_digest,
    :authority_decision,
    :observed_post_state,
    :receipt_binding
  ]

  @enforce_keys [:attestation_id, :receipt_set, :receipt_set_digest, :attested_at, :unobserved]
  defstruct [
    :attestation_id,
    :semantic_revision,
    :plan_revision,
    :manufacturer_revision,
    :projected_artifact_digest,
    :authority_decision,
    :receipt_set,
    :receipt_set_digest,
    :observed_post_state,
    :receipt_binding,
    :evidence_class,
    :attested_at,
    :basis_digest,
    unobserved: []
  ]

  @type t :: %__MODULE__{}
  @type refusal :: {:error, %{code: atom(), detail: term()}}

  @doc false
  # S42 class of the refusal code this module introduced for RFC-SA2A-002 §40.
  def __sa2a_refusal_codes__, do: %{attestation_receipt_binding_refused: :refused_receipt}

  @doc "The fields an attestation may claim, each of which must be receipt-backed."
  @spec claimable_fields() :: [atom()]
  def claimable_fields, do: @claimable

  @doc """
  Builds an attestation from the receipts actually observed.

  Refuses an empty receipt set (`:attestation_without_receipts`) -- an
  attestation with no evidence is not a weaker attestation, it is not an
  attestation. Refuses a receipt set spanning more than one actuation identity
  (`:attestation_spans_multiple_actuations`), because a single attestation
  naming two different effects cannot have a single observed post-state.
  """
  @spec from_receipts([Receipt.t()], keyword()) :: {:ok, t()} | refusal()
  def from_receipts(receipts, opts \\ [])

  def from_receipts(receipts, opts) do
    result = build(receipts, opts)
    emit(:build, result, receipts)
    result
  end

  defp build([], _opts),
    do: refuse(:attestation_without_receipts, "an attestation requires at least one receipt")

  defp build(receipts, opts) when is_list(receipts) do
    with :ok <- all_receipts(receipts),
         :ok <- single_actuation(receipts),
         {:ok, binding} <- receipt_binding(receipts) do
      ordered = Enum.sort_by(receipts, &(&1.logical_clock || 0))
      latest = List.last(ordered)
      subject = Enum.find_value(ordered, & &1.semantic_subject)

      attestation = %__MODULE__{
        attestation_id: AshA2A.Identity.runtime(Ash.UUIDv7.generate()),
        semantic_revision: subject && subject.graph_digest,
        plan_revision: Enum.find_value(ordered, & &1.plan_digest),
        manufacturer_revision: subject && subject.manufacturer_digest,
        projected_artifact_digest:
          (subject && subject.projection_digest) ||
            Enum.find_value(ordered, & &1.projection_digest),
        authority_decision: authority_decision(latest),
        receipt_set: Enum.map(ordered, &receipt_reference/1),
        receipt_set_digest: receipt_set_digest(ordered),
        observed_post_state: observed_post_state(latest),
        receipt_binding: binding,
        evidence_class: weakest_evidence_class(ordered),
        attested_at: Keyword.get(opts, :attested_at, DateTime.utc_now()),
        basis_digest: basis_digest(latest),
        unobserved: []
      }

      {:ok, %{attestation | unobserved: unobserved(attestation)}}
    end
  end

  @doc """
  Re-checks an attestation against the receipts it claims to rest on.

  Every non-nil claimable field must be reproducible from `receipts`; every
  field listed in `:unobserved` must actually be nil; and the receipt set
  digest must match. Any mismatch is a typed refusal naming the field.

  This is what makes `:unobserved` load-bearing: an attestation cannot be
  edited to assert a semantic revision the receipts never carried and still
  verify.

  A non-nil `:evidence_class` must be exactly the class value the receipts
  carry (`:attestation_claims_unobserved_evidence` / `:evidence_class`
  otherwise -- a chain earned for another subject does not attest these
  receipts), and must also be an *earned* class:
  `AshA2A.Evidence.Class.verify_chain/1` runs on it, so a forged class -- the
  right struct module built by hand, or via `new/1` above rank 1, with no
  real promotion chain behind it -- refuses with that function's typed code
  (`:evidence_chain_broken` / `:evidence_class_not_earned`) instead of
  riding into a verifying attestation (RFC S70).
  """
  @spec verify(t(), [Receipt.t()]) :: :ok | refusal()
  def verify(%__MODULE__{} = attestation, receipts) when is_list(receipts) do
    result = verify_backed(attestation, receipts)
    emit(:verify, result, receipts)
    result
  end

  defp verify_backed(attestation, receipts) do
    with :ok <- all_receipts(receipts),
         {:ok, rebuilt} <- from_receipts(receipts),
         :ok <- same_receipt_set(attestation, rebuilt),
         :ok <- no_unbacked_claims(attestation, rebuilt),
         :ok <- unobserved_really_absent(attestation),
         :ok <- evidence_class_backed(attestation, rebuilt),
         :ok <- earned_evidence_class(attestation) do
      :ok
    end
  end

  @doc """
  Whether this attestation claims `field`.

  A field in `:unobserved` is never claimed, regardless of what is stored.
  """
  @spec claims?(t(), atom()) :: boolean()
  def claims?(%__MODULE__{} = attestation, field) when field in @claimable do
    field not in attestation.unobserved and not is_nil(Map.fetch!(attestation, field))
  end

  def claims?(%__MODULE__{}, _field), do: false

  defp unobserved(%__MODULE__{} = attestation) do
    Enum.filter(@claimable, &is_nil(Map.fetch!(attestation, &1)))
  end

  defp all_receipts(receipts) do
    if Enum.all?(receipts, &match?(%Receipt{}, &1)) do
      :ok
    else
      refuse(:attestation_requires_receipts, "every element must be an AshA2A.Receipt")
    end
  end

  defp single_actuation(receipts) do
    ids =
      receipts
      |> Enum.map(& &1.actuation_id)
      |> Enum.reject(&is_nil/1)
      |> Enum.uniq()

    if length(ids) <= 1 do
      :ok
    else
      refuse(
        :attestation_spans_multiple_actuations,
        Enum.map(ids, &AshA2A.Identity.external/1)
      )
    end
  end

  defp same_receipt_set(%__MODULE__{} = claimed, %__MODULE__{} = rebuilt) do
    if claimed.receipt_set_digest == rebuilt.receipt_set_digest do
      :ok
    else
      refuse(:attestation_receipt_set_mismatch, %{
        claimed: claimed.receipt_set_digest,
        observed: rebuilt.receipt_set_digest
      })
    end
  end

  defp no_unbacked_claims(%__MODULE__{} = claimed, %__MODULE__{} = rebuilt) do
    Enum.reduce_while(@claimable, :ok, fn field, :ok ->
      claimed_value = Map.fetch!(claimed, field)
      observed_value = Map.fetch!(rebuilt, field)

      cond do
        claimed_value == observed_value -> {:cont, :ok}
        is_nil(claimed_value) -> {:cont, :ok}
        true -> {:halt, refuse(:attestation_claims_unobserved_evidence, field)}
      end
    end)
  end

  defp unobserved_really_absent(%__MODULE__{} = attestation) do
    contradicted =
      Enum.filter(attestation.unobserved, fn field ->
        field in @claimable and not is_nil(Map.fetch!(attestation, field))
      end)

    if contradicted == [] do
      :ok
    else
      refuse(:attestation_unobserved_field_has_value, contradicted)
    end
  end

  defp authority_decision(%Receipt{} = receipt) do
    case Replay.basis(receipt) do
      {:ok, %Replay.Basis{authorization: %Replay.AuthorityRecord{} = record}} ->
        %{
          decision: record.decision,
          token_id: record.token_id,
          capability_id: record.capability_id,
          source: record.source
        }

      {:error, _} ->
        # The receipt cannot reconstruct a basis, so no authority decision was
        # observed. `nil` here lands the field in `:unobserved`.
        nil
    end
  end

  defp observed_post_state(%Receipt{} = receipt) do
    %{
      status: receipt.status,
      terminal_status: receipt.terminal_status,
      standing: receipt.standing,
      consequence: receipt.consequence,
      reconciliation_state: Map.get(receipt.reconciliation || %{}, :state),
      recorded_at: receipt.recorded_at,
      logical_clock: receipt.logical_clock
    }
  end

  defp basis_digest(%Receipt{} = receipt) do
    case Replay.basis(receipt) do
      {:ok, %Replay.Basis{basis_digest: digest}} -> digest
      {:error, _} -> nil
    end
  end

  defp receipt_reference(%Receipt{} = receipt) do
    %{
      receipt_id: AshA2A.Identity.external(receipt.receipt_id),
      command_id: AshA2A.Identity.external(receipt.command_id),
      status: receipt.status,
      terminal_status: receipt.terminal_status,
      standing: receipt.standing
    }
  end

  defp receipt_set_digest(receipts) do
    receipts
    |> Enum.map(&receipt_reference/1)
    |> Actuation.digest()
  end

  # RFC-SA2A-002 §72 (SA2A-ATTEST-009 survived before this): an earned chain
  # is not enough -- the claimed class must be the very class value the
  # receipts carry (same class, same chain link). A Merge chain genuinely
  # earned for some other subject does not attest these receipts.
  defp evidence_class_backed(%__MODULE__{evidence_class: nil}, _rebuilt), do: :ok

  defp evidence_class_backed(%__MODULE__{evidence_class: claimed}, %__MODULE__{
         evidence_class: observed
       }) do
    if Evidence.Class.value?(claimed) and Evidence.Class.value?(observed) and
         Evidence.Class.module(claimed) == Evidence.Class.module(observed) and
         claimed.chain_digest == observed.chain_digest,
       do: :ok,
       else: refuse(:attestation_claims_unobserved_evidence, :evidence_class)
  end

  defp earned_evidence_class(%__MODULE__{evidence_class: nil}), do: :ok

  defp earned_evidence_class(%__MODULE__{evidence_class: class}),
    do: Evidence.Class.verify_chain(class)

  # Weakest, not strongest -- see moduledoc.
  defp weakest_evidence_class(receipts) do
    receipts
    |> Enum.map(& &1.evidence_class)
    |> Enum.filter(&Evidence.Class.value?/1)
    |> Enum.min_by(&Evidence.Class.rank/1, fn -> nil end)
  end

  # RFC-SA2A-002 §40/§72: every bound receipt must verify; the binding is
  # claimed only when every receipt is bound (nil -> `:unobserved`).
  defp receipt_binding(receipts) do
    Enum.reduce_while(receipts, {:ok, []}, fn receipt, {:ok, acc} ->
      case {Map.get(receipt, :binding), AshA2A.Receipt.Binding.verify(receipt)} do
        {nil, _unbound} ->
          {:cont, {:ok, [:unbound | acc]}}

        {_bound, {:ok, report}} ->
          {:cont, {:ok, [report | acc]}}

        {_bound, {:error, %{code: code}}} ->
          {:halt,
           refuse(:attestation_receipt_binding_refused, %{
             receipt_id: AshA2A.Identity.external(receipt.receipt_id),
             code: code
           })}
      end
    end)
    |> case do
      {:ok, reports} ->
        reports = Enum.reverse(reports)

        if reports != [] and Enum.all?(reports, &is_map/1),
          do:
            {:ok,
             %{
               keyed: Enum.all?(reports, & &1.keyed),
               key_ids: reports |> Enum.map(& &1.key_id) |> Enum.uniq(),
               digests: Enum.map(reports, & &1.digest)
             }},
          else: {:ok, nil}

      error ->
        error
    end
  end

  defp emit(decision, result, receipts) do
    {outcome, code, detail, attestation} =
      case result do
        {:ok, %__MODULE__{} = attestation} -> {:built, nil, nil, attestation}
        :ok -> {:verified, nil, nil, nil}
        {:error, %{code: code, detail: detail}} -> {:refused, code, detail, nil}
      end

    :telemetry.execute(
      [:ash_a2a, :attestation, decision],
      %{system_time: System.system_time()},
      %{
        outcome: outcome,
        code: code,
        field: if(is_atom(detail) and not is_nil(detail), do: detail),
        receipts: if(is_list(receipts), do: length(receipts)),
        receipt_ids:
          if(is_list(receipts),
            do:
              receipts
              |> Enum.filter(&match?(%Receipt{}, &1))
              |> Enum.map(&AshA2A.Identity.external(&1.receipt_id))
          ),
        receipt_binding:
          attestation && if(attestation.receipt_binding, do: :claimed, else: :unclaimed),
        binding_keyed:
          attestation && attestation.receipt_binding && attestation.receipt_binding.keyed,
        evidence_class:
          attestation && attestation.evidence_class &&
            Evidence.Class.label(attestation.evidence_class)
      }
    )
  end

  defp refuse(code, detail), do: {:error, %{code: code, detail: detail}}
end
