defmodule AshA2A.Replan.RegistryTest do
  use ExUnit.Case, async: true

  test "hddl has providers" do
    assert length(AshA2A.Replan.ProviderRegistry.for(:hddl)) >= 2
  end
end
