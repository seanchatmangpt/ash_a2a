defmodule AshA2A.EffectIdentityTest do
  use ExUnit.Case, async: true

  test "effect identity binds request" do
    assert AshA2A.ConsequenceKernel.EffectIdentity.derive("r1", %{"x" => 1}) !=
             AshA2A.ConsequenceKernel.EffectIdentity.derive("r2", %{"x" => 1})
  end
end
