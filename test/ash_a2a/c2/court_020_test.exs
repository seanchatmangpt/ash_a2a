defmodule AshA2A.C2.Court.C020Test do
  use ExUnit.Case, async: true
  @tag :c2_authority
  test "court 20 exact effect mutation is detectable" do
    a = AshA2A.C2.PreparedEffect.new("principal-20", "capability", "subject", %{court: 20})
    b = AshA2A.C2.PreparedEffect.new("principal-20", "capability", "subject", %{court: 21})
    refute a.digest == b.digest
  end
end
