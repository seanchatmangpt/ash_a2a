defmodule AshA2A.C2.Court.C032Test do
 use ExUnit.Case, async: true
 @tag :c2_authority
 test "court 32 exact effect mutation is detectable" do
  a=AshA2A.C2.PreparedEffect.new("principal-32","capability","subject",%{court:32})
  b=AshA2A.C2.PreparedEffect.new("principal-32","capability","subject",%{court:33})
  refute a.digest == b.digest
 end
end
