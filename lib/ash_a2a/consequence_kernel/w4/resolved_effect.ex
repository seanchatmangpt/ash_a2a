# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshA2A.ConsequenceKernel.W4.ResolvedEffect do
  @moduledoc false
  @enforce_keys [:request, :route]
  defstruct [:request, :route, :exact_subject, :prepared_digest]
  @type t :: %__MODULE__{}
end
