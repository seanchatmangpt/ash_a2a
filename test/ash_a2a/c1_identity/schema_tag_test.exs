defmodule AshA2A.C1Identity.SchemaTagTest do
  use ExUnit.Case, async: true
  alias AshA2A.Identity.Canonical
  @vector Path.expand("../../../priv/sa2a/c1/identity_vectors/schema_tag.json", __DIR__)
  test "schema tag" do
    v = @vector |> File.read!() |> Jason.decode!() |> Map.fetch!("value")
    assert match?({:ok, "sha256:" <> digest} when byte_size(digest) == 64, Canonical.digest(v))
  end
end
