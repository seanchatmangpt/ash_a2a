defmodule AshA2A.C1Identity.StringTest do
  use ExUnit.Case, async: true
  alias AshA2A.Identity.Canonical
  @vector Path.expand("../../../priv/sa2a/c1/identity_vectors/string.json", __DIR__)
  test "accept utf8 string" do
    v = @vector |> File.read!() |> Jason.decode!() |> Map.fetch!("value")
    assert match?({:ok, "sha256:" <> digest} when byte_size(digest) == 64, Canonical.digest(v))
  end
end
