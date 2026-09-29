defmodule AshA2A.C2.Court.C001Test do
  use ExUnit.Case, async: true
  @tag :c2_authority
  test "court 1 exact effect mutation is detectable" do
    a = AshA2A.C2.PreparedEffect.new("principal-1", "capability", "subject", %{court: 1})
    b = AshA2A.C2.PreparedEffect.new("principal-1", "capability", "subject", %{court: 2})
    refute a.digest == b.digest
  end
end
