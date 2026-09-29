defmodule AshA2A.C2.Court.C019Test do
 use ExUnit.Case, async: true
 @tag :c2_authority
 test "court 19 exact effect mutation is detectable" do
  a=AshA2A.C2.PreparedEffect.new("principal-19","capability","subject",%{court:19})
  b=AshA2A.C2.PreparedEffect.new("principal-19","capability","subject",%{court:20})
  refute a.digest == b.digest
 end
end
