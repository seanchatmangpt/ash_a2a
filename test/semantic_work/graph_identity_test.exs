# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshA2A.SemanticWork.GraphIdentityTest do
  use ExUnit.Case, async: true
  alias AshA2A.SemanticWork.GraphIdentity

  test "fails closed" do
    assert {:error, _} = GraphIdentity.bind(%{})
    assert {:error, :refused_invalid_envelope} = GraphIdentity.bind(:invalid)
  end
end
