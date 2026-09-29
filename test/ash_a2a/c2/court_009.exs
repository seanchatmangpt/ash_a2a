defmodule AshA2A.C2.Court.C009Test do
 use ExUnit.Case, async: true
 @tag :c2_authority
 test "court 9 exact effect mutation is detectable" do
  a=AshA2A.C2.PreparedEffect.new("principal-9","capability","subject",%{court:9})
  b=AshA2A.C2.PreparedEffect.new("principal-9","capability","subject",%{court:10})
  refute a.digest == b.digest
 end
end
