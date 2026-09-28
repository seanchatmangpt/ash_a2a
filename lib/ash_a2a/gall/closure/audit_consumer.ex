defmodule AshA2A.Gall.Closure.AuditConsumer do
  @moduledoc "Authority-free audit projection for exact GALL receipt and provenance subjects."

  def project(receipt, provenance) when is_map(receipt) and is_map(provenance) do
    %{
      kind: :gall_audit_record,
      receipt_id: AshA2A.Gall.Fields.get(receipt, :receipt_id),
      command_id: AshA2A.Gall.Fields.get(receipt, :command_id),
      candidate_digest: AshA2A.Gall.Fields.get(provenance, :candidate_digest),
      producer_sha: AshA2A.Gall.Fields.get(provenance, :producer_sha),
      terminal_status: AshA2A.Gall.Fields.get(receipt, :terminal_status),
      standing: AshA2A.Gall.Fields.get(receipt, :standing),
      authority: :none
    }
  end

  def project(_, _), do: {:error, {:refused_gall, :audit_consumer, :invalid_input}}
end
