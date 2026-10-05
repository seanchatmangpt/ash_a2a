# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshA2A.Replan.RegistryTest do
  use ExUnit.Case, async: true

  test "hddl has providers" do
    assert length(AshA2A.Replan.ProviderRegistry.for(:hddl)) >= 2
  end
end
