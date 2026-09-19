defmodule AshA2A.Gall.CommandReceipt do
  @moduledoc """
  GALL-003 observer handoff for one exact consequence receipt.

  The handoff validates the existing RFC-SA2A-002 receipt binding and carries
  only opaque authority identity. It does not add authority, re-dispatch the
  command, or treat an actuator reply as an independent postcondition.
  """

  alias AshA2A.{Receipt, SemanticSubject}
  alias AshA2A.Receipt.Binding

  @enforce_keys [
    :receipt_id,
    :command_id,
    :capability_id,
    :command_fingerprint,
    :semantic_subject,
    :manufacturer_subject_digest,
    :authority_grant_digest,
    :idempotency_key,
    :consequence,
    :binding_digest,
    :receipt_standing,
    :terminal_status,
    :handoff_digest
  ]
  defstruct [
    :receipt_id,
    :command_id,
    :capability_id,
    :command_fingerprint,
    :semantic_subject,
    :manufacturer_subject_digest,
    :authority_grant_digest,
    :idempotency_key,
    :actuation_id,
    :consequence,
    :binding_digest,
    :receipt_standing,
    :terminal_status,
    :status,
    :replayed?,
    :handoff_digest
  ]

  @type t :: %__MODULE__{}

  @spec from_receipt(Receipt.t()) :: {:ok, t()} | {:error, map()}
  def from_receipt(%Receipt{} = receipt) do
    with {:ok, %{digest: binding_digest}} <- Binding.check(receipt),
         %SemanticSubject{} = subject <- receipt.semantic_subject,
         :ok <- consequence(receipt.consequence),
         :ok <- terminal(receipt) do
      semantic_subject = %{
        graph_digest: subject.graph_digest,
        projection_digest: subject.projection_digest,
        manufacturer_digest: subject.manufacturer_digest,
        ephemeral?: subject.ephemeral?
      }

      payload = %{
        receipt_id: receipt.receipt_id,
        command_id: receipt.command_id,
        capability_id: receipt.capability_id,
        command_fingerprint: receipt.fingerprint,
        semantic_subject: semantic_subject,
        manufacturer_subject_digest: subject.manufacturer_digest,
        authority_grant_digest: digest(receipt.authority_grant),
        idempotency_key: receipt.idempotency_key,
        actuation_id: receipt.actuation_id,
        consequence: receipt.consequence,
        binding_digest: binding_digest,
        receipt_standing: receipt.standing,
        terminal_status: receipt.terminal_status,
        status: receipt.status,
        replayed?: receipt.replayed?
      }

      {:ok, struct!(__MODULE__, Map.put(payload, :handoff_digest, digest(payload)))}
    else
      {:error, %{code: _} = refusal} -> {:error, refusal}
      nil -> {:error, %{code: :semantic_subject_missing}}
      {:error, code} -> {:error, %{code: code}}
      other -> {:error, %{code: :invalid_gall_command_receipt, detail: other}}
    end
  end

  @spec digest(term()) :: String.t()
  def digest(term) do
    encoded = :erlang.term_to_binary(term, [:deterministic])
    "sha256:" <> (:crypto.hash(:sha256, encoded) |> Base.encode16(case: :lower))
  end

  defp consequence(value) when value in [:change, :external_do], do: :ok
  defp consequence(_), do: {:error, :non_consequence_receipt}

  # A durable finalized consequence and a durable/persisted pending crash-window
  # anchor are both valid GALL-003 evidence classes; neither is independent
  # postcondition proof.
  defp terminal(%Receipt{status: :pending}), do: :ok

  defp terminal(%Receipt{terminal_status: status})
       when status in [:executed, :reconciled, :failed, :unknown_outcome],
       do: :ok

  defp terminal(_), do: {:error, :consequence_terminal_state_unbound}
end
