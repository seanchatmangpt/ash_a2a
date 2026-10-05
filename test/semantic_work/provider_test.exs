# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshA2A.SemanticWork.ProviderTest do
  use ExUnit.Case, async: true
  alias AshA2A.SemanticWork.Provider

  test "refusal is typed" do
    assert {:error, {:refused_missing_identity, _}} = Provider.bind(%{})
  end
end
