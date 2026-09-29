defmodule AshA2A.C2.Court.C015Test do
 use ExUnit.Case, async: true
 @tag :c2_authority
 test "court 15 exact effect mutation is detectable" do
  a=AshA2A.C2.PreparedEffect.new("principal-15","capability","subject",%{court:15})
  b=AshA2A.C2.PreparedEffect.new("principal-15","capability","subject",%{court:16})
  refute a.digest == b.digest
 end
end
