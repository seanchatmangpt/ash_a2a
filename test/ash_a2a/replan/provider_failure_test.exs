# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshA2A.Replan.ProviderFailureTest do
  use ExUnit.Case, async: true

  test "records failed edge" do
    assert %{provider: :p, attempt: 2} = AshA2A.Replan.ProviderFailure.new(:p, :timeout, 2)
  end
end
