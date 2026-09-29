defmodule AshA2A.Replan.PortableEnvelope do
  @moduledoc """
  Portable consequence/recovery envelope for non-BEAM consumers.

  Recovery semantics are evaluated here, in SA2A, before serialization.
  Consumers validate and obey the supplied candidate decision; they do not
  recreate Outcome/RecoveryPolicy locally. The envelope carries no DO
  authority.
  """

  alias AshA2A.Replan.{Outcome, PortableSchema, ReceiptFeedback}

  @consequences [:executed, :failed, :refused, :reconciled, :compensated, :unknown_outcome]
  @decisions [:stop, :replan]

  def from_receipt(receipt, provider \\ nil) when is_map(receipt) do
    with {:ok, subject} <- required(receipt, :semantic_subject),
         {:ok, receipt_id} <- required(receipt, :receipt_id) do
      consequence = Outcome.classify(receipt)
      decision = ReceiptFeedback.ingest(receipt, provider)

      envelope = %{
        "schema" => PortableSchema.id(),
        "contract_digest" => PortableSchema.digest(),
        "exact_subject" => subject,
        "receipt_id" => to_string(receipt_id),
        "consequence" => Atom.to_string(consequence),
        "decision" => %{
          "kind" => Atom.to_string(decision.kind),
          "reason" => Atom.to_string(decision.reason),
          "authority" => Atom.to_string(decision.authority)
        },
        "provider" => nullable_string(provider),
        "projection_digest" => nullable_string(Map.get(receipt, :projection_digest)),
        "source_replay_key" => nullable_string(Map.get(receipt, :replay_key))
      }

      validate(envelope)
    end
  end

  def validate(%{
        "schema" => schema,
        "contract_digest" => digest,
        "exact_subject" => subject,
        "receipt_id" => receipt_id,
        "consequence" => consequence,
        "decision" => %{
          "kind" => kind,
          "reason" => reason,
          "authority" => "none"
        }
      } = envelope)
      when schema == PortableSchema.id() and
             digest == PortableSchema.digest() and
             not is_nil(subject) and
             is_binary(receipt_id) and byte_size(receipt_id) > 0 and
             is_binary(reason) and byte_size(reason) > 0 do
    with {:ok, _} <- member(consequence, @consequences),
         {:ok, _} <- member(kind, @decisions) do
      {:ok, envelope}
    end
  end

  def validate(_), do: {:error, :invalid_portable_replan_envelope}

  def encode(envelope) do
    with {:ok, admitted} <- validate(envelope) do
      Jason.encode(admitted)
    end
  end

  defp required(map, key) do
    case Map.get(map, key) do
      nil -> {:error, {:missing_portable_field, key}}
      value -> {:ok, value}
    end
  end

  defp member(value, allowed) do
    if value in Enum.map(allowed, &Atom.to_string/1), do: {:ok, value}, else: {:error, :invalid_enum}
  end

  defp nullable_string(nil), do: nil
  defp nullable_string(value), do: to_string(value)
end
