# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshA2A.ApplicationRestForOneTest do
  @moduledoc """
  Asserts the root supervisor strategy is `:rest_for_one` (stores before
  dependents). Source of truth is the compiled Application module body, not
  a comment.
  """

  use ExUnit.Case, async: true

  test "AshA2A.Application starts its tree with :rest_for_one" do
    {:ok, ast} =
      Code.string_to_quoted(File.read!(Path.expand("../../lib/ash_a2a/application.ex", __DIR__)))

    assert contains_rest_for_one?(ast),
           "lib/ash_a2a/application.ex must pass strategy: :rest_for_one to Supervisor.start_link/2"
  end

  defp contains_rest_for_one?(ast) do
    Macro.prewalk(ast, false, fn
      {:strategy, :rest_for_one} = node, _acc ->
        {node, true}

      node, acc ->
        {node, acc}
    end)
    |> elem(1)
  end
end
