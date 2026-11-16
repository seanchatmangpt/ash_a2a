defmodule AshA2A.LaneL05.ResubscribeClaimTest do
  # UNVERIFIED: authored without an Elixir toolchain; not yet run.
  use ExUnit.Case, async: true

  @doc_path Path.expand("../../docs/reference/a2a-spec-version-mapping.md", __DIR__)

  test "durability doc keeps the node-local resubscribe gap and does not claim a durable journal" do
    doc = File.read!(@doc_path)
    flat = String.replace(doc, ~r/\s+/, " ")

    assert flat =~ "a mid-flight stream stays node-local"
    assert flat =~ "no replayed events"
    assert flat =~ "NOT implemented"
    assert flat =~ "Durable cross-node task continuity: PARTIAL."
    refute flat =~ "Durable cross-node task continuity: CONFORMANT"
  end
end
