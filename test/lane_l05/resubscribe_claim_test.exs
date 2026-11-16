defmodule AshA2A.LaneL05.ResubscribeClaimTest do
  use ExUnit.Case, async: true

  @doc_path Path.expand("../../docs/reference/a2a-spec-version-mapping.md", __DIR__)

  test "durability doc describes the journal writer and keeps the producer gap" do
    doc = File.read!(@doc_path)
    flat = String.replace(doc, ~r/\s+/, " ")

    assert flat =~ "AshA2A.Protocol.EventJournal"
    assert flat =~ "config :ash_a2a, :event_journal"
    assert flat =~ "Remaining gap: no live producer migrates between nodes"
    refute flat =~ "no runtime code appends to the journal yet"
    assert flat =~ "AshA2A.Protocol.Agent.State.put_task_checked/2"
    assert flat =~ "[:ash_a2a, :event_journal, :append_failed]"
    assert flat =~ "PRODUCER_UNAVAILABLE"
    refute flat =~ "Resubscribe replay (UNVERIFIED"
    assert flat =~ "test/ash_a2a/event_journal_writer_test.exs"
    assert flat =~ "test/ash_a2a/event_journal_crossnode_test.exs"
    assert flat =~ "Durable cross-node task continuity: PARTIAL."
    refute flat =~ "Durable cross-node task continuity: CONFORMANT"
  end
end
