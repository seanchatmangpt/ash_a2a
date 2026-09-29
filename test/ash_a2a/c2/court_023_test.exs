defmodule AshA2A.C2.Court.C023Test do
  use ExUnit.Case, async: true
  @tag :c2_authority
  test "court 23 exact effect mutation is detectable" do
    a = AshA2A.C2.PreparedEffect.new("principal-23", "capability", "subject", %{court: 23})
    b = AshA2A.C2.PreparedEffect.new("principal-23", "capability", "subject", %{court: 24})
    refute a.digest == b.digest
  end
end
