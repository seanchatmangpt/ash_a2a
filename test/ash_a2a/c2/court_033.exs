defmodule AshA2A.C2.Court.C033Test do
 use ExUnit.Case, async: true
 @tag :c2_authority
 test "court 33 exact effect mutation is detectable" do
  a=AshA2A.C2.PreparedEffect.new("principal-33","capability","subject",%{court:33})
  b=AshA2A.C2.PreparedEffect.new("principal-33","capability","subject",%{court:34})
  refute a.digest == b.digest
 end
end
