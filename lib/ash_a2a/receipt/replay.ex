defmodule AshA2A.Receipt.Replay do
  @moduledoc """
  RFC-SA2A-001 S32 replay: reconstruct the semantic basis of an execution
  from its receipt, without repeating the execution.

  > "Replaying evidence is not authority to re-actuate."

  This module is the structural enforcement of that sentence, not a comment
  asserting it. Three mechanisms, all real:

  1. **No actuation path exists here.** This module never calls
     `AshA2A.CommandBus`, `AshA2A.Dispatcher`, or `Ash`. There is no
     `reactuate/1`, no `:execute` option, no callback that receives a
     dispatch function. Replay can only *return* a basis.

  2. **The replayed authority is a different type.** `basis/1` returns the
     authorization decision as an `AshA2A.Receipt.Replay.AuthorityRecord`
     struct -- deliberately *not* an `AshA2A.Authority`. This matters because
     `AshA2A.Authority.admits?/2` has a catch-all final clause returning
     `false` for anything that is not an `%AshA2A.Authority{}`, and
     `AshA2A.CommandBus.admit/2` refuses a consequence-bearing command whose
     `:authority` is not an `%AshA2A.Authority{}` with
     `:authority_required`. So a caller who takes the replayed authority
     record and stuffs it into a fresh command gets a refusal from the real
     bus, by construction -- they do not get a silent second execution. This
     is proven, not asserted, by
     `test/ash_a2a_receipt_replay_counting_actuator_test.exs`.

  3. **Insufficient identity refuses.** `basis/1` refuses a receipt that
     cannot deterministically reconstruct the semantic basis, rather than
     filling in a plausible one. S32 asks the receipt to *contain* enough
     identity; a receipt that does not, fails the check.

  4. **Unbound or tampered identity refuses.** A receipt whose RFC-SA2A-002
     §40 identity binding is absent or does not verify
     (`AshA2A.Receipt.Binding.check/2`) has no standing to replay from, and
     refuses with the binding's typed code.

  ## What the basis contains

  S32 names five things the receipt must be able to reconstruct:

    * **admission** -- consequence class, the admission outcome, the
      intended-effect record written before DO
    * **plan selection** -- `:plan_digest`, or an explicit
      `:no_plan_recorded` marker (never a fabricated digest)
    * **construction** -- the semantic subject: graph, projection and
      manufacturer digests
    * **authorization decision** -- an `AuthorityRecord` (see above)
    * **intended effect** -- capability, consequence, actuation and
      idempotency identities
  """

  alias AshA2A.{Identity, Receipt, SemanticSubject}

  defmodule AuthorityRecord do
    @moduledoc """
    An *observed record* of an authorization decision, replayed from a receipt.

    This is intentionally not an `AshA2A.Authority`. An `AshA2A.Authority` is a
    live grant that `AshA2A.Authority.admits?/2` will honour; an
    `AuthorityRecord` is historical evidence that a grant was once observed.
    Passing one where the other is expected does not silently work -- it
    refuses, which is the S32 requirement.
    """
    @enforce_keys [:decision]
    defstruct [:decision, :token_id, :subject, :capability_id, :source, :issued_at, :expires_at]

    @type decision :: :admitted | :not_required | :absent
    @type t :: %__MODULE__{decision: decision()}
  end

  defmodule Basis do
    @moduledoc """
    The deterministic semantic basis reconstructed from one receipt.

    `:basis_digest` is a content digest over the reconstructed basis, so two
    receipts that name the same semantic execution produce the same digest --
    which is what makes this usable as conformance evidence rather than a
    pretty-printed struct.
    """
    @enforce_keys [
      :receipt_id,
      :command_id,
      :execution_id,
      :admission,
      :plan_selection,
      :construction,
      :authorization,
      :intended_effect,
      :observed_outcome,
      :basis_digest
    ]
    defstruct [
      :receipt_id,
      :command_id,
      :execution_id,
      :admission,
      :plan_selection,
      :construction,
      :authorization,
      :intended_effect,
      :observed_outcome,
      :basis_digest,
      # Never anything but `false`. There is no code path in this module that
      # sets it to `true`, because there is no code path in this module that
      # actuates anything.
      actuated?: false
    ]

    @type t :: %__MODULE__{actuated?: false}
  end

  @type refusal :: {:error, %{code: atom(), detail: String.t()}}

  @doc """
  Reconstructs the semantic basis of the execution this receipt records.

  Returns `{:ok, %Basis{actuated?: false}}` or a typed refusal. Never
  actuates; see the module doc.
  """
  @spec basis(Receipt.t()) :: {:ok, Basis.t()} | refusal()
  def basis(%Receipt{} = receipt) do
    with :ok <- sufficient_identity(receipt),
         {:ok, _binding} <- AshA2A.Receipt.Binding.check(receipt) do
      admission = %{
        consequence: receipt.consequence,
        outcome: receipt.status,
        terminal_status: receipt.terminal_status,
        input_digest: receipt.input_digest,
        fingerprint: receipt.fingerprint
      }

      plan_selection =
        case receipt.plan_digest do
          nil -> %{plan_digest: nil, marker: :no_plan_recorded}
          digest -> %{plan_digest: digest, marker: :plan_recorded}
        end

      construction = construction(receipt.semantic_subject, receipt.projection_digest)
      authorization = authorization(receipt)

      intended_effect =
        Map.merge(receipt.intended_effect || %{}, %{
          actuation_id: external(receipt.actuation_id),
          idempotency_key: external(receipt.idempotency_key)
        })

      observed_outcome = %{
        status: receipt.status,
        terminal_status: receipt.terminal_status,
        standing: receipt.standing,
        recorded_at: receipt.recorded_at,
        logical_clock: receipt.logical_clock,
        reply_shape: reply_shape(receipt.reply)
      }

      {:ok,
       %Basis{
         receipt_id: external(receipt.receipt_id),
         command_id: external(receipt.command_id),
         execution_id: external(receipt.execution_id),
         admission: admission,
         plan_selection: plan_selection,
         construction: construction,
         authorization: authorization,
         intended_effect: intended_effect,
         observed_outcome: observed_outcome,
         basis_digest:
           AshA2A.Actuation.digest(
             {admission, plan_selection, construction, authorization, intended_effect}
           ),
         actuated?: false
       }}
    end
  end

  @doc """
  Replays a whole receipt set, in stable `logical_clock` order.

  Refuses the entire set if any single receipt cannot be replayed, rather than
  silently returning a partial history that looks complete.
  """
  @spec basis_set([Receipt.t()]) :: {:ok, [Basis.t()]} | refusal()
  def basis_set(receipts) when is_list(receipts) do
    receipts
    |> Enum.sort_by(&(&1.logical_clock || 0))
    |> Enum.reduce_while({:ok, []}, fn receipt, {:ok, acc} ->
      case basis(receipt) do
        {:ok, basis} -> {:cont, {:ok, [basis | acc]}}
        {:error, _} = error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, acc} -> {:ok, Enum.reverse(acc)}
      error -> error
    end
  end

  @doc """
  Whether two receipts describe the same semantic execution basis.

  This is the comparison a portable-conformance harness needs: same basis
  digest means the two runtimes admitted, planned, constructed, authorized and
  intended the same thing -- independent of receipt ids, wall clocks and
  execution ids, none of which are in the digest.
  """
  @spec same_basis?(Receipt.t(), Receipt.t()) :: boolean()
  def same_basis?(%Receipt{} = left, %Receipt{} = right) do
    case {basis(left), basis(right)} do
      {{:ok, l}, {:ok, r}} -> l.basis_digest == r.basis_digest
      _ -> false
    end
  end

  defp sufficient_identity(%Receipt{} = receipt) do
    missing =
      Enum.filter(
        [
          receipt_id: receipt.receipt_id,
          command_id: receipt.command_id,
          execution_id: receipt.execution_id,
          fingerprint: receipt.fingerprint,
          consequence: receipt.consequence,
          actuation_id: receipt.actuation_id,
          idempotency_key: receipt.idempotency_key,
          input_digest: receipt.input_digest,
          intended_effect: receipt.intended_effect
        ],
        fn {_field, value} -> is_nil(value) end
      )
      |> Enum.map(&elem(&1, 0))

    if missing == [] do
      :ok
    else
      {:error,
       %{
         code: :insufficient_replay_identity,
         detail:
           "receipt cannot reconstruct a semantic basis; missing " <>
             Enum.map_join(missing, ", ", &to_string/1)
       }}
    end
  end

  defp construction(%SemanticSubject{} = subject, _projection_digest) do
    %{
      graph_digest: subject.graph_digest,
      projection_digest: subject.projection_digest,
      manufacturer_digest: subject.manufacturer_digest,
      ephemeral?: subject.ephemeral?
    }
  end

  defp construction(_subject, projection_digest) do
    %{
      graph_digest: nil,
      projection_digest: projection_digest,
      manufacturer_digest: nil,
      marker: :no_semantic_subject_recorded
    }
  end

  defp authorization(%Receipt{authority_grant: nil, consequence: :observe}) do
    %AuthorityRecord{decision: :not_required}
  end

  defp authorization(%Receipt{authority_grant: nil}) do
    %AuthorityRecord{decision: :absent}
  end

  defp authorization(%Receipt{authority_grant: grant}) when is_map(grant) do
    %AuthorityRecord{
      decision: :admitted,
      token_id: Map.get(grant, :token_id),
      subject: Map.get(grant, :subject),
      capability_id: Map.get(grant, :capability_id),
      source: Map.get(grant, :source),
      issued_at: Map.get(grant, :issued_at),
      expires_at: Map.get(grant, :expires_at)
    }
  end

  defp external(%Identity{} = identity), do: Identity.external(identity)
  defp external(nil), do: nil
  defp external(other), do: other

  defp reply_shape(nil), do: nil
  defp reply_shape({tag, _}) when is_atom(tag), do: tag
  defp reply_shape(other) when is_atom(other), do: other
  defp reply_shape(_), do: :opaque
end
