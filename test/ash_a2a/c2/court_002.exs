defmodule AshA2A.C2.Court.C002Test do
 use ExUnit.Case, async: true
 @tag :c2_authority
 test "court 2 exact effect mutation is detectable" do
  a=AshA2A.C2.PreparedEffect.new("principal-2","capability","subject",%{court:2})
  b=AshA2A.C2.PreparedEffect.new("principal-2","capability","subject",%{court:3})
  refute a.digest == b.digest
 end
end
