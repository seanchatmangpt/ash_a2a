defmodule AshA2A.C2.Court.C013Test do
  use ExUnit.Case, async: true
  @tag :c2_authority
  test "court 13 exact effect mutation is detectable" do
    a = AshA2A.C2.PreparedEffect.new("principal-13", "capability", "subject", %{court: 13})
    b = AshA2A.C2.PreparedEffect.new("principal-13", "capability", "subject", %{court: 14})
    refute a.digest == b.digest
  end
end
