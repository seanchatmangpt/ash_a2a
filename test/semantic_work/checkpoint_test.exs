# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshA2A.SemanticWork.CheckpointTest do
  use ExUnit.Case, async: true
  alias AshA2A.SemanticWork.Checkpoint

  test "fails closed" do
    assert {:error, _} = Checkpoint.bind(%{})
    assert {:error, :refused_invalid_envelope} = Checkpoint.bind(:invalid)
  end
end
