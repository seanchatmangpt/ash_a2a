defmodule AshA2A.C2.Court.C028Test do
  use ExUnit.Case, async: true
  @tag :c2_authority
  test "court 28 exact effect mutation is detectable" do
    a = AshA2A.C2.PreparedEffect.new("principal-28", "capability", "subject", %{court: 28})
    b = AshA2A.C2.PreparedEffect.new("principal-28", "capability", "subject", %{court: 29})
    refute a.digest == b.digest
  end
end
