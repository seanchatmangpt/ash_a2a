defmodule AshA2A.Gall.Closure.ReceiptBinding do
  @moduledoc "Verifies that a canonical AshA2A receipt remains bound to the exact command and GALL candidate."

  def admit(receipt, command, candidate) when is_map(receipt) and is_map(command) and is_map(candidate) do
    command_id = field(command, :command_id)
    capability = field(command, :capability_id)
    fingerprint = field(command, :fingerprint)
    candidate_digest = field(candidate, :candidate_digest)
    metadata = field(receipt, :metadata) || %{}
    effect = field(receipt, :intended_effect) || %{}

    cond do
      field(receipt, :command_id) != command_id ->
        {:error, {:refused_gall, :receipt_binding, :command_mismatch}}

      field(receipt, :capability_id) != capability ->
        {:error, {:refused_gall, :receipt_binding, :capability_mismatch}}

      not is_nil(fingerprint) and field(receipt, :fingerprint) != fingerprint ->
        {:error, {:refused_gall, :receipt_binding, :fingerprint_mismatch}}

      (field(metadata, :candidate_digest) || field(effect, :gall_029_candidate_digest)) != candidate_digest ->
        {:error, {:refused_gall, :receipt_binding, :candidate_mismatch}}

      true ->
        {:ok, receipt}
    end
  end

  def admit(_, _, _), do: {:error, {:refused_gall, :receipt_binding, :invalid_receipt}}

  defp field(map, key), do: Map.get(map, key) || Map.get(map, to_string(key))
end
