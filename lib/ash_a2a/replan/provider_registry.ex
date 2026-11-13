# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshA2A.Replan.ProviderRegistry do
  @defaults [
    beam4pm: AshA2A.Replan.Port.Beam4pm,
    ferroplan: AshA2A.Replan.Port.Ferroplan,
    ash_pplan: AshA2A.Replan.Port.AshPPlan
  ]
  def defaults, do: @defaults

  @doc """
  Boot-time check: logs a warning when beam4pm/ferroplan are selected but no
  `:beam4pm_url` / `:ferroplan_url` is configured. Returns the list of unconfigured ids.
  """
  def boot_check(providers \\ @defaults) do
    missing =
      for {id, _} <- providers, id in [:beam4pm, :ferroplan], not configured?(id), do: id

    if missing != [] do
      require Logger

      Logger.warning(
        "ash_a2a replan providers #{inspect(missing)} have no URL configured " <>
          "(:beam4pm_url / :ferroplan_url); they will answer :unavailable"
      )
    end

    missing
  end

  defp configured?(:beam4pm), do: is_binary(Application.get_env(:ash_a2a, :beam4pm_url))
  defp configured?(:ferroplan), do: is_binary(AshA2A.Replan.Port.Ferroplan.url())

  def for(formalism, providers \\ @defaults),
    do: Enum.filter(providers, fn {_id, m} -> m.supports?(formalism) end)
end
