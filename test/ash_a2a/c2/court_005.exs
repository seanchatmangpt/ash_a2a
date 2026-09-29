defmodule AshA2A.C2.Court.C005Test do
 use ExUnit.Case, async: true
 @tag :c2_authority
 test "court 5 exact effect mutation is detectable" do
  a=AshA2A.C2.PreparedEffect.new("principal-5","capability","subject",%{court:5})
  b=AshA2A.C2.PreparedEffect.new("principal-5","capability","subject",%{court:6})
  refute a.digest == b.digest
 end
end
