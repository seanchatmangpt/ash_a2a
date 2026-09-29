defmodule AshA2A.C2.Court.C030Test do
  use ExUnit.Case, async: true
  @tag :c2_authority
  test "court 30 exact effect mutation is detectable" do
    a = AshA2A.C2.PreparedEffect.new("principal-30", "capability", "subject", %{court: 30})
    b = AshA2A.C2.PreparedEffect.new("principal-30", "capability", "subject", %{court: 31})
    refute a.digest == b.digest
  end
end
