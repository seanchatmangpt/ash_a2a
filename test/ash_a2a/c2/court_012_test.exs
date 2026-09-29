defmodule AshA2A.C2.Court.C012Test do
  use ExUnit.Case, async: true
  @tag :c2_authority
  test "court 12 exact effect mutation is detectable" do
    a = AshA2A.C2.PreparedEffect.new("principal-12", "capability", "subject", %{court: 12})
    b = AshA2A.C2.PreparedEffect.new("principal-12", "capability", "subject", %{court: 13})
    refute a.digest == b.digest
  end
end
