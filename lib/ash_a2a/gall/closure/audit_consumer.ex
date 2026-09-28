defmodule AshA2A.Gall.Closure.AuditConsumer do
  @moduledoc "Authority-free audit projection for exact GALL receipt and provenance subjects."

  def project(receipt, provenance) when is_map(receipt) and is_map(provenance) do
    %{
      kind: :gall_audit_record,
      receipt_id: field(receipt, :receipt_id),
      command_id: field(receipt, :command_id),
      candidate_digest: field(provenance, :candidate_digest),
      producer_sha: field(provenance, :producer_sha),
      terminal_status: field(receipt, :terminal_status),
      standing: field(receipt, :standing),
      authority: :none
    }
  end

  def project(_, _), do: {:error, {:refused_gall, :audit_consumer, :invalid_input}}

  defp field(map, key), do: Map.get(map, key) || Map.get(map, to_string(key))
end
