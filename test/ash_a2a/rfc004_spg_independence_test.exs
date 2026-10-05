# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshA2A.Rfc004SpgIndependenceTest do
  use ExUnit.Case, async: true

  alias AshA2A.SpgConformance

  defp temp_corpus do
    dir = Path.join(System.tmp_dir!(), "spg_corpus_#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    File.cp_r!(SpgConformance.corpus_dir(), dir)
    on_exit(fn -> File.rm_rf!(dir) end)
    dir
  end

  test "committed corpus digest pin verifies against the shipped corpus" do
    assert {:ok, "sha256:" <> _} = SpgConformance.verify_pinned()
  end

  test "mutating a case in a real temp copy changes the digest and is refused" do
    dir = temp_corpus()
    assert {:ok, digest} = SpgConformance.verify_pinned(dir)

    path = Path.join(dir, "001_exact_subject_match.json")
    mutated = path |> SpgConformance.load_file!() |> put_in(["replay", "seed"], 999)
    File.write!(path, JSON.encode!(mutated))

    assert {:error, {:corpus_digest_mismatch, ^digest, actual}} =
             SpgConformance.verify_pinned(dir)

    refute actual == digest
  end

  test "missing pin is refused" do
    assert {:error, {:corpus_pin_unreadable, :enoent}} =
             SpgConformance.verify_pinned(SpgConformance.corpus_dir(), "/nonexistent/pin")
  end

  test "independent evaluator agrees with every admit fixture in independent families" do
    cases = SpgConformance.load_all()
    report = SpgConformance.independent_report(cases)

    independent = SpgConformance.independent_families()
    admits = Enum.filter(cases, &(&1["family"] in independent and &1["expect"] == "admit"))
    assert length(admits) > 0

    assert Enum.all?(admits, fn c ->
             match?({:admit, _}, SpgConformance.independent_evaluator(c))
           end)

    assert report.evaluated == Enum.count(cases, &(&1["family"] in independent))
    assert report.evaluated == length(report.agree) + length(report.disagree)
  end

  test "FINDING: refuse fixtures carry no concrete witness, independent evaluator admits them" do
    cases = SpgConformance.load_all()
    report = SpgConformance.independent_report(cases)

    refuse_ids =
      cases
      |> Enum.filter(
        &(&1["family"] in SpgConformance.independent_families() and &1["expect"] == "refuse")
      )
      |> Enum.map(& &1["case_id"])

    assert Enum.sort(Enum.map(report.disagree, &elem(&1, 0))) == Enum.sort(refuse_ids)

    independent = Enum.filter(cases, &(&1["family"] in SpgConformance.independent_families()))

    assert {:error, %{failures: failures}} =
             SpgConformance.run_cases(independent, &SpgConformance.independent_evaluator/1)

    assert Enum.sort(Enum.map(failures, &elem(&1, 0))) == Enum.sort(refuse_ids)
    assert Enum.all?(failures, fn {_, {:error, reason}} -> reason == :false_admission end)
  end

  test "independent evaluator refuses concrete-field violations without reading checks" do
    c =
      SpgConformance.load_file!(
        Path.join(SpgConformance.corpus_dir(), "001_exact_subject_match.json")
      )

    bad_sha = put_in(c, ["subject", "base_sha"], "xyz")

    assert {:refuse, "SPG_INDEPENDENT_IDENTITY_MISMATCH"} =
             SpgConformance.independent_evaluator(bad_sha)

    bad_proc = put_in(c, ["procedure", "identity"], "urn:ash-a2a:spg:identity:other")

    assert {:refuse, "SPG_INDEPENDENT_IDENTITY_MISMATCH"} =
             SpgConformance.independent_evaluator(bad_proc)

    no_auth = put_in(c, ["boundary", "authority_explicit"], false)

    assert {:refuse, "SPG_INDEPENDENT_AUTHORITY_UNBOUND"} =
             SpgConformance.independent_evaluator(no_auth)
  end

  test "family split is documented and covers every corpus family exactly once" do
    families = SpgConformance.load_all() |> Enum.map(& &1["family"]) |> Enum.uniq() |> Enum.sort()
    split = SpgConformance.independent_families() ++ SpgConformance.self_checked_families()
    assert Enum.sort(split) == families
  end
end
