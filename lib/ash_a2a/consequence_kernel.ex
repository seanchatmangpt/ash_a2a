# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshA2A.ConsequenceKernel do
  @moduledoc false
  alias AshA2A.ConsequenceKernel.Runtime.Pipeline
  def execute(prepared, opts), do: Pipeline.execute(prepared, opts)
end
