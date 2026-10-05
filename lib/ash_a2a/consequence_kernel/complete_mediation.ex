# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshA2A.ConsequenceKernel.CompleteMediation do
  @moduledoc false
  alias AshA2A.ConsequenceKernel.CallGraphCourt
  @forbidden [AshA2A.Dispatcher, AshA2A.Effector, AshA2A.C2.Effector]
  def forbidden_modules, do: @forbidden
  def admit_call_path(modules) when is_list(modules), do: if(Enum.any?(modules, &(&1 in @forbidden)), do: {:error, :kernel_bypass}, else: :ok)
  def admit_call_edge(edge) when is_map(edge) do
    case CallGraphCourt.classify(edge) do
      {:admit, reason} -> {:ok, reason}
      {:refuse, reason} -> {:error, reason}
    end
  end
end
