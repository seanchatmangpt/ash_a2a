defmodule AshA2A.C1RefusalTotalityTest do
 use ExUnit.Case, async: true
 test "registry is nonempty and unique" do c=AshA2A.ConsequenceKernel.RefusalRegistry.codes(); assert c!=[]; assert Enum.uniq(c)==c end
end
