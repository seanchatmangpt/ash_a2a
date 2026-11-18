# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshA2A.C1Identity.IntegerTest do
  use ExUnit.Case, async: true
  alias AshA2A.Identity.Canonical
  @vector Path.expand("../../../priv/sa2a/c1/identity_vectors/integer.json", __DIR__)
  test "accept integer" do
    v = @vector |> File.read!() |> Jason.decode!() |> Map.fetch!("value")
    assert match?({:ok, "sha256:" <> digest} when byte_size(digest) == 64, Canonical.digest(v))
  end
end
