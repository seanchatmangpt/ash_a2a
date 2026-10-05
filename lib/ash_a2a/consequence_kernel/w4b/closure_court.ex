# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshA2A.ConsequenceKernel.W4B.ClosureCourt do
  @moduledoc false
  alias AshA2A.ConsequenceKernel.W4B.EntryPolicy

  def judge(vectors) when is_list(vectors),
    do:
      Enum.map(vectors, fn %{consequence: c, route: r, expected: e} ->
        {c, r, EntryPolicy.admit(c, r) == e}
      end)

  def closed?(results), do: Enum.all?(results, fn {_, _, ok?} -> ok? end)
end
