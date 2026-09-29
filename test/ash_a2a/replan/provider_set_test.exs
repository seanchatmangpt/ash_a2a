defmodule AshA2A.Replan.ProviderSetTest do
  use ExUnit.Case, async: true

  defmodule P do
    def supports?(:hddl), do: true
    def supports?(_), do: false
  end

  test "excludes failed edge" do
    assert nil == AshA2A.Replan.ProviderSet.select([p: P], :hddl, MapSet.new([:p]))
  end
end
