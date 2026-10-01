defmodule Actuator.AnchorTest do
  @moduledoc """
  T2/T3 court: journal and effect-ledger truncation must not be accepted on restart.

  Real OS processes: a child boots the Store on a real state dir and performs an effect; the
  parent then damages the on-disk state the way a rollback/truncation attacker would and a
  SECOND child tries to boot. Final state is asserted: the second process must refuse to
  start (typed refusal, exit 3) and the ledger effect count must not grow (no double perform).
  """
  use ExUnit.Case, async: false
  alias Actuator.{Anchor, Journal, Kit, Ledger, Store}

  @moduletag :crash

  setup do
    Process.flag(:trap_exit, true)
    dir = Kit.tmp_dir("anchor")
    one = Kit.child_fixture(dir, 1)
    two = Kit.child_fixture(dir, 2, one.built.keys)
    {:ok, dir: dir, one: one, two: two}
  end

  defp jpath(dir), do: Path.join(dir, "journal.jsonl")
  defp lpath(dir), do: Path.join(dir, "effect_ledger.jsonl")
  defp lines(path), do: path |> File.read!() |> String.split("\n", trim: true)
  defp write_lines(path, ls), do: File.write!(path, Enum.map_join(ls, "", &(&1 <> "\n")))

  defp performed!(fx) do
    {out, status} = Kit.run_child(fx)
    assert status == 0, out
    assert out =~ "CHILD_RETURNED {:ok, %{status: :performed", out
  end

  defp refused!(fx, code) do
    {out, status} = Kit.run_child(fx)
    assert status == 3, out
    assert out =~ "BOOT_REFUSED", out
    assert out =~ code, out
    refute out =~ "CHILD_RETURNED"
  end

  test "control: an undamaged state dir reboots and replays without a second perform", %{
    dir: dir,
    one: one
  } do
    performed!(one)
    {out, 0} = Kit.run_child(one)
    assert out =~ "status: :replayed"
    assert length(lines(lpath(dir))) == 1
    assert :ok = Kit.ledger_oracle(dir, [one.built.effect_bytes])
  end

  test "journal AND ledger rolled back to empty: refuses to boot, does not perform a second time",
       %{dir: dir, one: one} do
    performed!(one)
    File.write!(jpath(dir), "")
    File.write!(lpath(dir), "")
    refused!(one, "journal_truncated")
    assert File.read!(lpath(dir)) == ""
  end

  test "ledger truncated, journal intact: refuses to boot", %{dir: dir, one: one, two: two} do
    performed!(one)
    performed!(two)
    write_lines(lpath(dir), Enum.take(lines(lpath(dir)), 1))
    refused!(one, "ledger_truncated")
    assert length(lines(lpath(dir))) == 1
  end

  test "journal tail (the completed record) truncated: refuses instead of demoting to unknown",
       %{dir: dir, one: one} do
    performed!(one)
    write_lines(jpath(dir), Enum.drop(lines(jpath(dir)), -1))
    refused!(one, "journal_truncated")
  end

  test "journal gap (a middle record removed): refuses on the broken chain", %{
    dir: dir,
    one: one,
    two: two
  } do
    performed!(one)
    performed!(two)
    [a, _b, c, d] = lines(jpath(dir))
    write_lines(jpath(dir), [a, c, d])
    refused!(one, "journal_broken_chain")
  end

  test "anchor deleted while state is non-empty: refuses (no anchor is not a fresh dir)", %{
    dir: dir,
    one: one
  } do
    performed!(one)
    File.rm!(Anchor.path(dir))
    refused!(one, "anchor_missing")
  end

  test "anchor corrupt: refuses", %{dir: dir, one: one} do
    performed!(one)
    File.write!(Anchor.path(dir), "{not json")
    refused!(one, "anchor_corrupt")
  end

  test "an attacker who re-chains the journal and re-anchors still trips the journal/ledger cross-check",
       %{dir: dir, one: one} do
    performed!(one)
    # drop the executing claim, recompute a VALID journal chain and a VALID anchor
    [_claim | rest] = lines(jpath(dir)) |> Enum.map(&Jason.decode!/1)

    events =
      Enum.map(rest, &Map.drop(&1, ["seq", "prev", "hash"]))

    {jlines, jseq, jhead} = Journal.build(events)
    write_lines(jpath(dir), jlines)
    {:ok, %{count: lseq, head: lhead}} = Ledger.verify(dir)

    :ok =
      Anchor.write(dir, %{
        journal_seq: jseq,
        journal_head: jhead,
        ledger_seq: lseq,
        ledger_head: lhead
      })

    assert {:error, {:store_boot_refused, {code, _}}} = Store.start_link(state_dir: dir)
    assert code in [:ledger_without_claim, :journal_orphan_event]
  end

  test "claim in the journal without a ledger terminal entry is unknown_outcome, never re-performed",
       %{dir: dir, one: one} do
    {_out, 137} = Kit.run_child(one, "after_write_ahead")
    assert File.read!(lpath(dir)) == ""
    {out, 0} = Kit.run_child(one)
    assert out =~ "status: :replayed"
    assert out =~ "unknown_outcome"
    assert File.read!(lpath(dir)) == ""
  end
end
