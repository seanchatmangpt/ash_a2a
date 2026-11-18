# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshA2A.C1W3Hardening.PreparedReleasedTest do
  use ExUnit.Case, async: true
  alias AshA2A.ConsequenceKernel.PreparedEffectStore.Transition

  test "prepared_released transition court" do
    v =
      Path.join([File.cwd!(), "priv/sa2a/c1/w3_hardening_vectors/prepared_released.json"])
      |> File.read!()
      |> Jason.decode!()

    Code.ensure_loaded!(Transition)
    from = String.to_existing_atom(v["from"])
    to = String.to_existing_atom(v["to"])
    assert Transition.admit(from, to) == :ok == v["admit"]
  end
end
