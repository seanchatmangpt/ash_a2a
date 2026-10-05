# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
#
# SPDX-License-Identifier: MIT

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
