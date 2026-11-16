defmodule AshA2A.Receipts.VerifierTest do
  use ExUnit.Case, async: true

  alias AshA2A.Receipts.Verifier

  @moduletag :tmp_dir

  defp write!(root, rel, content) do
    path = Path.join(root, rel)
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, content)
    path
  end

  defp sha(content), do: :crypto.hash(:sha256, content) |> Base.encode16(case: :lower)

  defp codes(findings), do: Enum.map(findings, & &1.code)

  test "a consistent receipt has no findings", %{tmp_dir: root} do
    write!(root, "lib/a.ex", "defmodule A do end")
    write!(root, "test/a_test.exs", "x")
    write!(root, "logs/run.log", "ok")

    text = """
    Standing: ALIVE
    Run log: logs/run.log
    Commit: abc1234
    `lib/a.ex` sha256:#{sha("defmodule A do end")} and `test/a_test.exs`
    """

    assert Verifier.verify_text(text, "r.md", root: root, commit_exists: fn _ -> true end) == []
  end

  test "hash mismatch and missing hashed file are errors", %{tmp_dir: root} do
    write!(root, "lib/a.ex", "changed")
    bad = String.duplicate("0", 64)
    text = "Standing: UNVERIFIED\n`lib/a.ex` sha256:#{bad}\n`lib/gone.ex` sha256:#{bad}\n"
    found = Verifier.verify_text(text, "r.md", root: root)
    assert :hash_mismatch in codes(found)
    assert :hash_file_missing in codes(found)
    refute Verifier.ok?(found)
  end

  test "malformed and unknown commits are errors", %{tmp_dir: root} do
    assert [%{code: :commit_malformed}] =
             Verifier.verify_text("Standing: UNVERIFIED\nCommit: zzz\n", "r.md", root: root)

    assert [%{code: :commit_unknown}] =
             Verifier.verify_text("Standing: UNVERIFIED\nCommit: abc1234\n", "r.md",
               root: root,
               commit_exists: fn _ -> false end
             )
  end

  test "cited test file must exist", %{tmp_dir: root} do
    found =
      Verifier.verify_text("Standing: UNVERIFIED\n`test/nope_test.exs`\n", "r.md", root: root)

    assert codes(found) == [:test_missing]
  end

  test "verified standing needs an existing run log", %{tmp_dir: root} do
    assert [%{code: :verified_without_run_log}] =
             Verifier.verify_text("Standing: ALIVE\n", "r.md", root: root)

    found = Verifier.verify_text("Standing: ALIVE\nRun log: logs/none.log\n", "r.md", root: root)
    assert :run_log_missing in codes(found)
    assert :verified_without_run_log in codes(found)
  end

  test "UNVERIFIED with a run log warns but is not an error", %{tmp_dir: root} do
    write!(root, "run.log", "x")
    found = Verifier.verify_text("Standing: UNVERIFIED\nRun log: run.log\n", "r.md", root: root)
    assert [%{code: :unverified_with_run_log, severity: :warning}] = found
    assert Verifier.ok?(found)
  end

  test "missing standing line warns", %{tmp_dir: root} do
    assert [%{code: :standing_missing, severity: :warning}] =
             Verifier.verify_text("nothing\n", "r.md", root: root)
  end

  test "CONFORMANT row on an UNVERIFIED doc or row is an error", %{tmp_dir: root} do
    write!(root, "docs/x.md", "# X\n\nStatus: UNVERIFIED\n")
    write!(root, "docs/y.md", "# Y\n\nStatus: ALIVE\n")

    text = """
    Standing: UNVERIFIED
    | Row | Doc | Claim |
    | --- | --- | --- |
    | a | `docs/x.md` | CONFORMANT |
    | b | `docs/y.md` | CONFORMANT |
    | c | none | CONFORMANT / UNVERIFIED |
    """

    found = Verifier.verify_text(text, "r.md", root: root)
    assert Enum.count(found, &(&1.code == :conformant_on_unverified)) == 2
  end

  test "verify_file reports an unreadable receipt", %{tmp_dir: root} do
    assert [%{code: :receipt_unreadable}] = Verifier.verify_file(Path.join(root, "absent.md"))
  end
end
