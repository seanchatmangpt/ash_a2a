defmodule AshA2A.BuildCapabilityIndexAfterTest do
  @moduledoc """
  Chicago-style test (real module, real function call, no mocks) for the
  Zach-Daniel review finding on
  `AshA2A.Transformers.BuildCapabilityIndex.after?/1`: it must not claim a
  blanket "run after every other transformer" ordering, since it has no
  actual data dependency on any other transformer's output.
  """
  use ExUnit.Case, async: true

  alias AshA2A.Transformers.BuildCapabilityIndex

  test "after?/1 does not claim a blanket ordering dependency on unrelated transformers" do
    refute BuildCapabilityIndex.after?(Ash.Resource.Transformers.CachePrimaryKey)
    refute BuildCapabilityIndex.after?(SomeUnrelatedExtension.Transformers.Whatever)
  end
end
