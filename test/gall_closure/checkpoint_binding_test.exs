# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshA2A.GallClosure.CheckpointBindingTest do
  use ExUnit.Case, async: true
  alias AshA2A.GallClosure.CheckpointBinding

  test "bounded admission",
    do: assert(match?({:ok, _}, CheckpointBinding.admit(%{checkpoint: "witness"})))

  test "typed refusal", do: assert(CheckpointBinding.admit(%{}) == {:error, :missing_checkpoint})
end
