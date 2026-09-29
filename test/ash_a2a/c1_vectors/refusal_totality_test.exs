defmodule AshA2A.C1RefusalTotalityTest do
  use ExUnit.Case, async: true

  alias AshA2A.ConsequenceKernel.RefusalRegistry
  alias AshA2A.Semantic.Refusal

  test "registry is nonempty and unique" do
    codes = RefusalRegistry.codes()
    assert length(codes) > 0
    assert Enum.uniq(codes) == codes
  end

  test "every consequence-kernel refusal code has an explicit S42 class" do
    mapping = Refusal.mapping()

    for code <- RefusalRegistry.codes() do
      assert Map.has_key?(mapping, code), "#{code} has no S42 class"
    end
  end
end
