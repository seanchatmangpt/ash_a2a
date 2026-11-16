defmodule AshA2A.LaneL05.ResubscribeClaimTest do
  # UNVERIFIED: authored without an Elixir toolchain; not yet run.
  use ExUnit.Case, async: true

  @doc_path Path.expand("../../docs/reference/a2a-spec-version-mapping.md", __DIR__)

  test "durability doc describes journal replay as UNVERIFIED and keeps the producer gap" do
    doc = File.read!(@doc_path)
    flat = String.replace(doc, ~r/\s+/, " ")

    assert flat =~ "AshA2A.Protocol.EventJournal"
    assert flat =~ "config :ash_a2a, :event_journal"
    assert flat =~ "Remaining gap: no live producer migrates between nodes"
    assert flat =~ "no runtime code appends to the journal yet"
    assert flat =~ "PRODUCER_UNAVAILABLE"
    assert flat =~ "Status: UNVERIFIED"
    assert flat =~ "Durable cross-node task continuity: PARTIAL."
    refute flat =~ "Durable cross-node task continuity: CONFORMANT"
  end
end
