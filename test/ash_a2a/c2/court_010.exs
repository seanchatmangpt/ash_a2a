defmodule AshA2A.C2.Court.C010Test do
 use ExUnit.Case, async: true
 @tag :c2_authority
 test "court 10 exact effect mutation is detectable" do
  a=AshA2A.C2.PreparedEffect.new("principal-10","capability","subject",%{court:10})
  b=AshA2A.C2.PreparedEffect.new("principal-10","capability","subject",%{court:11})
  refute a.digest == b.digest
 end
end
