# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshA2A.RefusalRegistryTest do
  use ExUnit.Case, async: true

  test "kernel refusals are typed" do
    for c <- AshA2A.ConsequenceKernel.RefusalRegistry.codes(),
        do: assert(AshA2A.ConsequenceKernel.RefusalRegistry.known?(c))
  end
end
