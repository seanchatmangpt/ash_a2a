defmodule AshA2A.ExecutionContextTest do
  use ExUnit.Case, async: true

  @moduledoc """
  Direct coverage of the `AshA2A.ExecutionContext` struct itself. Every other
  test that touches this module builds one indirectly, via
  `AshA2A.ContextResolver.from_a2a_message/3`; none constructs and asserts on
  the struct's own real default values or field set.
  """

  test "struct defaults context to %{} and history to [], with actor/tenant/domain nil" do
    context = %AshA2A.ExecutionContext{}

    assert context.actor == nil
    assert context.tenant == nil
    assert context.domain == nil
    assert context.context == %{}
    assert context.history == []
  end

  test "struct holds real, independently-set field values" do
    message = %{role: :user}

    context = %AshA2A.ExecutionContext{
      actor: %{id: "user-1"},
      tenant: "tenant-a",
      domain: AshA2A.Test.Fixture.Domain,
      context: %{source: :test},
      history: [message]
    }

    assert context.actor == %{id: "user-1"}
    assert context.tenant == "tenant-a"
    assert context.domain == AshA2A.Test.Fixture.Domain
    assert context.context == %{source: :test}
    assert context.history == [message]
  end
end
