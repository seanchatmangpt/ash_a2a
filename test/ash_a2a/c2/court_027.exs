defmodule AshA2A.C2.Court.C027Test do
 use ExUnit.Case, async: true
 @tag :c2_authority
 test "court 27 exact effect mutation is detectable" do
  a=AshA2A.C2.PreparedEffect.new("principal-27","capability","subject",%{court:27})
  b=AshA2A.C2.PreparedEffect.new("principal-27","capability","subject",%{court:28})
  refute a.digest == b.digest
 end
end
