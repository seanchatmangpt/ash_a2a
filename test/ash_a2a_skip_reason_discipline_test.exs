# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshA2A.SkipReasonDisciplineTest do
  @moduledoc """
  Fails closed when a `:skip`-tagged test carries no reason string, and
  lists the tags `test_helper.exs` excluded (loud census, never silent).
  A bare `@tag :skip` / `@moduletag :skip` is a skip with no stated reason.
  """
  use ExUnit.Case, async: true

  @bare ~r/^\s*@(module|describe)?tag\s+:skip\b(?!\s*,)(?!_)/
  # `skip: true` / `skip: not x` / `skip: !x` are boolean skips with no reason string.
  @boolean ~r/\bskip:\s*(true\b|not\s|!)/

  test "no bare :skip tag without a reason string" do
    offenders =
      Path.wildcard("test/**/*.{ex,exs}")
      |> Enum.reject(&(&1 == "test/ash_a2a_skip_reason_discipline_test.exs"))
      |> Enum.flat_map(fn file ->
        file
        |> File.read!()
        |> String.split("\n")
        |> Enum.with_index(1)
        |> Enum.filter(fn {line, _} -> Regex.match?(@bare, line) or Regex.match?(@boolean, line) end)
        |> Enum.map(fn {line, n} -> "#{file}:#{n}: #{String.trim(line)}" end)
      end)

    assert offenders == [],
           "skip tags without a reason (use `@tag skip: \"why\"`):\n" <>
             Enum.join(offenders, "\n")
  end

  test "excluded tags are a known list (printed census)" do
    excluded = ExUnit.configuration()[:exclude] |> List.wrap()
    IO.puts(:stderr, "[test_helper] excluded tags: #{inspect(excluded)}")
    assert is_list(excluded)
    assert :external_api in excluded
    assert :benchmark in excluded
  end
end
