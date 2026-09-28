defmodule AshA2A.Gall.Closure.ReceiptBinding do
  @moduledoc "Verifies that a canonical AshA2A receipt remains bound to the exact command and GALL candidate."

  def admit(receipt, command, candidate)
      when is_map(receipt) and is_map(command) and is_map(candidate) do
    command_id = AshA2A.Gall.Fields.get(command, :command_id)
    capability = AshA2A.Gall.Fields.get(command, :capability_id)
    fingerprint = AshA2A.Gall.Fields.get(command, :fingerprint)
    candidate_digest = AshA2A.Gall.Fields.get(candidate, :candidate_digest)
    metadata = AshA2A.Gall.Fields.get(receipt, :metadata) || %{}
    effect = AshA2A.Gall.Fields.get(receipt, :intended_effect) || %{}

    cond do
      AshA2A.Gall.Fields.get(receipt, :command_id) != command_id ->
        {:error, {:refused_gall, :receipt_binding, :command_mismatch}}

      AshA2A.Gall.Fields.get(receipt, :capability_id) != capability ->
        {:error, {:refused_gall, :receipt_binding, :capability_mismatch}}

      not is_nil(fingerprint) and AshA2A.Gall.Fields.get(receipt, :fingerprint) != fingerprint ->
        {:error, {:refused_gall, :receipt_binding, :fingerprint_mismatch}}

      (AshA2A.Gall.Fields.get(metadata, :candidate_digest) ||
         AshA2A.Gall.Fields.get(effect, :gall_029_candidate_digest)) !=
          candidate_digest ->
        {:error, {:refused_gall, :receipt_binding, :candidate_mismatch}}

      true ->
        {:ok, receipt}
    end
  end

  def admit(_, _, _), do: {:error, {:refused_gall, :receipt_binding, :invalid_receipt}}
end
