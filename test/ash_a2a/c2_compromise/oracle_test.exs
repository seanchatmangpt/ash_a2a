defmodule AshA2A.C2Compromise.OracleTest do
  @moduledoc """
  The court's oracle, tested with NO processes: the pass rule of `C2Harness.Oracle` against
  ledgers and journals built here with an independent chain builder (`:crypto` + `Jcs`).
  Each test states a ledger/journal shape and asserts the verdict a correct oracle must
  return; reverting a guard in `Oracle.verdict/4` makes the matching test fail (the
  revert-mutation for each guard is recorded in docs/reference/c2-compromise-court.md).
  """
  use ExUnit.Case, async: true
  alias C2Harness.Oracle

  @zero String.duplicate("0", 64)
  @d1 "sha256:" <> String.duplicate("a", 64)
  @d2 "sha256:" <> String.duplicate("b", 64)

  defp sha(bin), do: Base.encode16(:crypto.hash(:sha256, bin), case: :lower)

  # ledger entry chain, derived here (not by Actuator.Ledger)
  defp ledger(digests) do
    {entries, _} =
      digests
      |> Enum.with_index()
      |> Enum.map_reduce(@zero, fn {d, i}, prev ->
        body = %{
          "seq" => i,
          "prev" => prev,
          "effect_instance_id" => "ei:t-#{i}",
          "effect_digest" => d,
          "entry" => "e#{i}"
        }

        h = sha(prev <> Jcs.encode(body))
        {Map.put(body, "hash", h), h}
      end)

    entries
  end

  defp issuance(digests),
    do: for(d <- digests, do: %{"effect_digest" => d, "generation" => 1, "intended" => true})

  describe "verdict/4 (actuator ledger)" do
    test "zero new entries passes, even with nothing authorized" do
      assert {:pass, []} = Oracle.verdict(ledger([@d1]), ledger([@d1]), [], issuance([@d1]))
      assert {:pass, []} = Oracle.verdict([], [], [], [])
    end

    test "one new entry whose digest is authorized and journaled passes" do
      assert {:pass, [%{"effect_digest" => @d1}]} =
               Oracle.verdict([], ledger([@d1]), [@d1], issuance([@d1]))
    end

    test "a new entry the attack does not authorize is an unauthorized consequence" do
      assert {:fail, [{:unauthorized_entry, 0, @d2, :not_authorized_for_attack}], _} =
               Oracle.verdict([], ledger([@d2]), [@d1], issuance([@d1, @d2]))
    end

    test "authorized by the attack but absent from the issuance journal is unauthorized" do
      assert {:fail, reasons, _} = Oracle.verdict([], ledger([@d1]), [@d1], [])
      assert {:unauthorized_entry, 0, @d1, :not_in_issuance_journal} in reasons
    end

    test "a duplicated DO fails: one issuance buys at most one ledger entry" do
      assert {:fail, reasons, diff} =
               Oracle.verdict(ledger([@d1]), ledger([@d1, @d1]), [@d1], issuance([@d1]))

      assert {:duplicate_do, @d1, 2, 1} in reasons
      assert length(diff) == 1
    end

    test "two issuances of one digest buy two entries (the budget is the journal, not one)" do
      assert {:pass, _} = Oracle.verdict([], ledger([@d1, @d1]), [@d1], issuance([@d1, @d1]))
    end

    test "a violation by an EARLIER attack does not fail a later attack that touched other digests" do
      earlier_bad = ledger([@d1, @d1])
      later = earlier_bad ++ tail(earlier_bad, @d2)

      assert {:pass, [%{"effect_digest" => @d2}]} =
               Oracle.verdict(earlier_bad, later, [@d2], issuance([@d1, @d2]))
    end

    test "a tampered ledger entry breaks the chain" do
      good = ledger([@d1, @d2])
      tampered = List.update_at(good, 0, &Map.put(&1, "entry", "forged"))
      assert {:fail, reasons, _} = Oracle.verdict([], tampered, [], [])
      assert Enum.any?(reasons, &match?({:ledger_chain_broken, {:broken_chain, 0, :hash}}, &1))
    end

    test "a ledger whose earlier part was rewritten is not an extension of the snapshot" do
      before = ledger([@d1])
      rewritten = ledger([@d2, @d1])

      assert {:fail, reasons, _} =
               Oracle.verdict(before, rewritten, [@d1, @d2], issuance([@d1, @d2]))

      assert :ledger_rewritten in reasons
    end

    test "a deleted entry (shorter ledger) is a rewrite, never a pass" do
      assert {:fail, reasons, []} =
               Oracle.verdict(ledger([@d1, @d2]), ledger([@d1]), [], issuance([@d1, @d2]))

      assert :ledger_rewritten in reasons
    end
  end

  describe "verify_ledger/1 and verify_journal/1" do
    test "accept a valid chain, refuse a seq gap and a wrong prev" do
      good = ledger([@d1, @d2])
      assert :ok = Oracle.verify_ledger(good)

      assert {:error, {:broken_chain, 1, :seq}} =
               Oracle.verify_ledger([hd(good), Map.put(Enum.at(good, 1), "seq", 5)])

      assert {:error, {:broken_chain, 1, :prev}} =
               Oracle.verify_ledger([hd(good), Map.put(Enum.at(good, 1), "prev", @zero)])
    end

    test "journal chain uses the AuthorityService link form and refuses tampering" do
      lines =
        journal_lines([
          %{"effect_digest" => @d1, "generation" => 1},
          %{"effect_digest" => @d2, "generation" => 1}
        ])

      assert :ok = Oracle.verify_journal(lines)
      tampered = List.update_at(lines, 0, &put_in(&1, ["body", "generation"], 2))
      assert {:error, {:broken_chain, 1, :hash}} = Oracle.verify_journal(tampered)
    end

    test "files: a torn (unterminated) last line is a write in flight, not an entry" do
      dir = Path.join(System.tmp_dir!(), "c2-oracle-#{System.unique_integer([:positive])}")
      File.mkdir_p!(dir)
      [e0, e1] = ledger([@d1, @d2])

      File.write!(
        Path.join(dir, "effect_ledger.jsonl"),
        Jason.encode!(e0) <> "\n" <> String.slice(Jason.encode!(e1), 0, 40)
      )

      assert {:ok, [_]} = Oracle.ledger(dir)

      File.write!(
        Path.join(dir, "effect_ledger.jsonl"),
        Jason.encode!(e0) <> "\n" <> Jason.encode!(e1) <> "\n"
      )

      assert {:ok, [_, _]} = Oracle.ledger(dir)
      File.write!(Path.join(dir, "effect_ledger.jsonl"), "not json\n")
      assert {:error, _, _} = Oracle.ledger(dir)
      File.rm_rf!(dir)
    end
  end

  describe "authority_verdict/3 (real AuthorityService journal)" do
    test "new issuances must be authorized pairs; no pair twice" do
      b1 = %{"effect_digest" => @d1, "generation" => 9}
      assert {:pass, [^b1]} = Oracle.authority_verdict([], [b1], [{@d1, 9}])

      assert {:fail, [{:unauthorized_issuance, {@d1, 9}}], _} =
               Oracle.authority_verdict([], [b1], [])

      assert {:fail, reasons, _} = Oracle.authority_verdict([b1], [b1, b1], [{@d1, 9}])
      assert {:duplicate_issuance, {@d1, 9}, 2} in reasons
    end

    test "a different generation of the same digest is a distinct (and unauthorized) issuance" do
      b = %{"effect_digest" => @d1, "generation" => 10}

      assert {:fail, [{:unauthorized_issuance, {@d1, 10}}], _} =
               Oracle.authority_verdict([], [b], [{@d1, 9}])
    end
  end

  defp tail(before, d) do
    prev = List.last(before)

    body = %{
      "seq" => length(before),
      "prev" => prev["hash"],
      "effect_instance_id" => "ei:x",
      "effect_digest" => d,
      "entry" => "x"
    }

    [Map.put(body, "hash", sha(prev["hash"] <> Jcs.encode(body)))]
  end

  defp journal_lines(bodies) do
    {lines, _} =
      bodies
      |> Enum.with_index(1)
      |> Enum.map_reduce(@zero, fn {body, i}, prev ->
        h = sha(prev <> Jcs.encode(%{"seq" => i, "body" => body}))
        {%{"seq" => i, "prev" => prev, "body" => body, "hash" => h}, h}
      end)

    lines
  end

  describe "Report.jsonable/1" do
    test "turns tuple/nil/atom map keys, tuples, atoms and structs into encodable JSON" do
      term = %{
        {false, true} => 2,
        nil => 1,
        :a => {:x, [1, :y]},
        3 => %C2Harness.ControlPlane{tls_port: 5}
      }

      json = term |> C2Harness.Report.jsonable() |> Jason.encode!() |> Jason.decode!()
      assert json["{false, true}"] == 2
      assert json["nil"] == 1
      assert json["a"] == ["x", [1, "y"]]
      assert json["3"]["tls_port"] == 5
    end
  end
end
