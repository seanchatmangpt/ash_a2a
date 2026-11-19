# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshA2A.Replan.FerroplanPortTest do
  use ExUnit.Case, async: false

  alias AshA2A.Replan.Port.Ferroplan

  test "declares FOND" do
    assert Ferroplan.supports?(:fond)
  end

  test "no URL configured answers the typed :ferroplan_unavailable" do
    prev =
      {Application.get_env(:ash_a2a, :ferroplan_url), Application.get_env(:ash_a2a, :beam4pm_url)}

    Application.delete_env(:ash_a2a, :ferroplan_url)
    Application.delete_env(:ash_a2a, :beam4pm_url)

    on_exit(fn ->
      {f, b} = prev
      if f, do: Application.put_env(:ash_a2a, :ferroplan_url, f)
      if b, do: Application.put_env(:ash_a2a, :beam4pm_url, b)
    end)

    assert {:error, :ferroplan_unavailable} =
             Ferroplan.propose(%{domain: "d", problem: "p"}, [])

    assert {:error, %{code: :ferroplan_unavailable}} =
             AshA2A.Planning.plan_with_ferroplan(AshA2A.Test.NoSuchDomain, "d", "p")

    assert :ferroplan in AshA2A.Replan.ProviderRegistry.boot_check()
  end

  test "an unreachable URL yields a transport error, not a crash or in-process call" do
    assert {:error, _} =
             Ferroplan.propose(%{domain: "d", problem: "p"},
               ferroplan_url: "http://127.0.0.1:1/a2a"
             )
  end
end
