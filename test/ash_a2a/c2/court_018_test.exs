defmodule AshA2A.C2.Court.C018Test do
  use ExUnit.Case, async: true
  @tag :c2_authority
  test "court 18 exact effect mutation is detectable" do
    a = AshA2A.C2.PreparedEffect.new("principal-18", "capability", "subject", %{court: 18})
    b = AshA2A.C2.PreparedEffect.new("principal-18", "capability", "subject", %{court: 19})
    refute a.digest == b.digest
  end
end
