defmodule AshA2A.Replan.PortableSchemaTest do
  use ExUnit.Case, async: true

  alias AshA2A.Replan.PortableSchema

  test "portable schema has stable content identity" do
    decoded = PortableSchema.decode!()
    assert decoded["$id"] == "https://chatmangpt.com/sa2a/replan-envelope/v1"
    assert PortableSchema.digest() =~ ~r/^sha256:[0-9a-f]{64}$/
  end
end
