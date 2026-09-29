defmodule AshA2A.C1RequestEffectSeparationTest do
 use ExUnit.Case, async: true
 test "request and effect domains differ" do assert AshA2A.ConsequenceKernel.RequestIdentity.derive(%{"x"=>1}) != AshA2A.ConsequenceKernel.EffectIdentity.derive("r",%{"x"=>1}) end
end
