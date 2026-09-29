defmodule AshA2A.C1Identity.FloatTest do
  use ExUnit.Case, async: true
  alias AshA2A.Identity.Canonical
  @vector Path.expand("../../../priv/sa2a/c1/identity_vectors/float.json", __DIR__)
  test "refuse float" do
    v = @vector |> File.read!() |> Jason.decode!() |> Map.fetch!("value")
    assert Canonical.digest(v) == {:error, :canonical_float_forbidden}
  end
end
