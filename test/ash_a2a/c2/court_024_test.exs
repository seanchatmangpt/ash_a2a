defmodule AshA2A.C2.Court.C024Test do
  use ExUnit.Case, async: true
  @tag :c2_authority
  test "court 24 exact effect mutation is detectable" do
    a = AshA2A.C2.PreparedEffect.new("principal-24", "capability", "subject", %{court: 24})
    b = AshA2A.C2.PreparedEffect.new("principal-24", "capability", "subject", %{court: 25})
    refute a.digest == b.digest
  end
end
