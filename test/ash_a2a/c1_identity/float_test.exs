# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshA2A.C1Identity.FloatTest do
  use ExUnit.Case, async: true
  alias AshA2A.Identity.Canonical
  @vector Path.expand("../../../priv/sa2a/c1/identity_vectors/float.json", __DIR__)
  # RFC-SA2A-007 errata E-F: portable identity refuses floats (the vector's
  # own purpose is "refuse float"); RFC 8785 would admit them, identity does not.
  test "identity canonicalization refuses floats (RFC-007 E-F)" do
    v = @vector |> File.read!() |> Jason.decode!() |> Map.fetch!("value")
    assert {:error, :canonical_float_forbidden} = Canonical.digest(v)
  end
end
