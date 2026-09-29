defmodule AshA2A.SecM14CanonicalIdentityTest do
  use ExUnit.Case, async: true

  test "same JSON value has stable portable digest" do
    assert {:ok, a} = AshA2A.Identity.Canonical.digest(%{"b" => 2, "a" => 1})
    assert {:ok, ^a} = AshA2A.Identity.Canonical.digest(%{"a" => 1, "b" => 2})
    assert a =~ ~r/^sha256:[0-9a-f]{64}$/
  end
end
