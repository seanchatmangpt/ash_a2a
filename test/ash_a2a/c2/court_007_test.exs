defmodule AshA2A.C2.Court.C007Test do
  use ExUnit.Case, async: true
  @tag :c2_authority
  test "court 7 exact effect mutation is detectable" do
    a = AshA2A.C2.PreparedEffect.new("principal-7", "capability", "subject", %{court: 7})
    b = AshA2A.C2.PreparedEffect.new("principal-7", "capability", "subject", %{court: 8})
    refute a.digest == b.digest
  end
end
