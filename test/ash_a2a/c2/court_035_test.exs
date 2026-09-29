defmodule AshA2A.C2.Court.C035Test do
  use ExUnit.Case, async: true
  @tag :c2_authority
  test "court 35 exact effect mutation is detectable" do
    a = AshA2A.C2.PreparedEffect.new("principal-35", "capability", "subject", %{court: 35})
    b = AshA2A.C2.PreparedEffect.new("principal-35", "capability", "subject", %{court: 36})
    refute a.digest == b.digest
  end
end
