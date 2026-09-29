defmodule AshA2A.RequestIdentityTest do
  use ExUnit.Case, async: true

  test "request identity is deterministic" do
    assert AshA2A.ConsequenceKernel.RequestIdentity.derive(%{"a" => 1}) ==
             AshA2A.ConsequenceKernel.RequestIdentity.derive(%{"a" => 1})
  end
end
