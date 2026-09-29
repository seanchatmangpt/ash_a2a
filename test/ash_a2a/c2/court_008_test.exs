defmodule AshA2A.C2.Court.C008Test do
  use ExUnit.Case, async: true
  @tag :c2_authority
  test "court 8 exact effect mutation is detectable" do
    a = AshA2A.C2.PreparedEffect.new("principal-8", "capability", "subject", %{court: 8})
    b = AshA2A.C2.PreparedEffect.new("principal-8", "capability", "subject", %{court: 9})
    refute a.digest == b.digest
  end
end
