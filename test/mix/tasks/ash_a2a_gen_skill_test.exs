# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule Mix.Tasks.AshA2a.GenSkillTest do
  @moduledoc """
  Real Igniter project, real task run, assertions on the persisted source.
  """

  use ExUnit.Case, async: true

  import Igniter.Test

  @path "lib/test/ticket.ex"

  defp project do
    test_project(
      files: %{
        @path => """
        defmodule Test.Ticket do
          use Ash.Resource,
            domain: Test.Domain,
            data_layer: Ash.DataLayer.Ets

          attributes do
            uuid_primary_key(:id)
          end
        end
        """
      }
    )
  end

  defp source(igniter),
    do: igniter.rewrite |> Rewrite.source!(@path) |> Rewrite.Source.get(:content)

  test "appends the skill inside the a2a block with no default consequence" do
    content =
      project()
      |> Igniter.compose_task("ash_a2a.gen.skill", ["Test.Ticket", "open_ticket", "create"])
      |> source()

    assert content =~ "extensions: [AshA2A]"
    assert content =~ "a2a do"
    assert content =~ "skill(:open_ticket, :create)"
    # `observe` is a compile-time error on a mutating action, so it is never
    # written unless asked for.
    refute content =~ "consequence"
  end

  test "writes consequence and description only when given, and is idempotent" do
    argv = [
      "Test.Ticket",
      "open_ticket",
      "create",
      "--consequence",
      "change",
      "--description",
      "Opens one"
    ]

    once = project() |> Igniter.compose_task("ash_a2a.gen.skill", argv) |> source()
    assert once =~ "consequence: :change"
    assert once =~ ~s(description: "Opens one")

    twice =
      project()
      |> Igniter.compose_task("ash_a2a.gen.skill", argv)
      |> Igniter.compose_task("ash_a2a.gen.skill", argv)
      |> source()

    assert twice == once
  end
end
