defmodule AshA2A.C2.Court.C011Test do
 use ExUnit.Case, async: true
 @tag :c2_authority
 test "court 11 exact effect mutation is detectable" do
  a=AshA2A.C2.PreparedEffect.new("principal-11","capability","subject",%{court:11})
  b=AshA2A.C2.PreparedEffect.new("principal-11","capability","subject",%{court:12})
  refute a.digest == b.digest
 end
end
