defmodule AshA2A.GallClosure.AuditConsumer do
  @moduledoc "Bounded GALL-029/030 guard for audit_consumer."
  def admit(%{audit_consumer: v} = s) when v not in [nil, false, ""],
    do: {:ok, Map.put(s, :gall_guard, :audit_consumer)}

  def admit(_), do: {:error, :missing_audit_consumer}
end
