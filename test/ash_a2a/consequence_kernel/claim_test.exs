# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshA2A.ClaimTest do
  use ExUnit.Case, async: true

  defmodule Store do
    def claim_request(r, o), do: {:request, r, o}
    def claim_effect(e, o), do: {:effect, e, o}
    def release_effect(e, o), do: {:release, e, o}
  end

  test "request and effect claims are independent" do
    assert {:request, "r", "o"} = AshA2A.ConsequenceKernel.Claim.request(Store, "r", "o")
    assert {:effect, "e", "o"} = AshA2A.ConsequenceKernel.Claim.effect(Store, "e", "o")
  end
end
