defmodule AshA2A.C2.Court.C016Test do
  use ExUnit.Case, async: true
  @tag :c2_authority
  test "court 16 exact effect mutation is detectable" do
    a = AshA2A.C2.PreparedEffect.new("principal-16", "capability", "subject", %{court: 16})
    b = AshA2A.C2.PreparedEffect.new("principal-16", "capability", "subject", %{court: 17})
    refute a.digest == b.digest
  end
end
