defmodule AshA2A.C2.Court.C026Test do
  use ExUnit.Case, async: true
  @tag :c2_authority
  test "court 26 exact effect mutation is detectable" do
    a = AshA2A.C2.PreparedEffect.new("principal-26", "capability", "subject", %{court: 26})
    b = AshA2A.C2.PreparedEffect.new("principal-26", "capability", "subject", %{court: 27})
    refute a.digest == b.digest
  end
end
