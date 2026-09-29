defmodule AshA2A.C2.Court.C021Test do
 use ExUnit.Case, async: true
 @tag :c2_authority
 test "court 21 exact effect mutation is detectable" do
  a=AshA2A.C2.PreparedEffect.new("principal-21","capability","subject",%{court:21})
  b=AshA2A.C2.PreparedEffect.new("principal-21","capability","subject",%{court:22})
  refute a.digest == b.digest
 end
end
