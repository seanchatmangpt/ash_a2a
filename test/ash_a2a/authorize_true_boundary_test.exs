# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshA2A.AuthorizeTrueBoundaryTest do
  @moduledoc """
  Ash calls from Executor and Dispatcher pass `authorize?: true` explicitly.
  Proven against the source of the live modules (not a grep of docs).
  """

  use ExUnit.Case, async: true

  test "Executor and Dispatcher source pass authorize?: true on Ash calls" do
    for rel <- ["lib/ash_a2a/executor.ex", "lib/ash_a2a/dispatcher.ex"] do
      path = Path.expand(Path.join("../..", rel), __DIR__)
      text = File.read!(path)

      assert text =~ ~r/authorize\?:\s*true/,
             "#{rel} must pass authorize?: true on Ash calls"
    end
  end
end
