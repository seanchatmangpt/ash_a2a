defmodule AshA2A.C2.Court.C004Test do
 use ExUnit.Case, async: true
 @tag :c2_authority
 test "court 4 exact effect mutation is detectable" do
  a=AshA2A.C2.PreparedEffect.new("principal-4","capability","subject",%{court:4})
  b=AshA2A.C2.PreparedEffect.new("principal-4","capability","subject",%{court:5})
  refute a.digest == b.digest
 end
end
