defmodule AshA2A.GallClosure.AuditConsumerTest do
  use ExUnit.Case, async: true
  alias AshA2A.GallClosure.AuditConsumer

  test "bounded admission",
    do: assert(match?({:ok, _}, AuditConsumer.admit(%{audit_consumer: "witness"})))

  test "typed refusal", do: assert(AuditConsumer.admit(%{}) == {:error, :missing_audit_consumer})
end
