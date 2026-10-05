# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshA2A.Replan.ProviderResult do
  def normalize({:ok, %{} = v}, id), do: {:ok, %{provider: id, candidate: v}}
  def normalize({:error, r}, id), do: {:error, %{provider: id, reason: r}}
  def normalize(v, id), do: {:error, %{provider: id, reason: {:invalid_provider_result, v}}}
end
