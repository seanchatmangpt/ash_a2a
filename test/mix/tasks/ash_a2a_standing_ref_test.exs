# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule Mix.Tasks.AshA2a.StandingRefTest do
  @moduledoc """
  Chicago-style qualification of `mix ash_a2a.standing_ref` /
  `AshA2A.StandingRef` (work order ASH_A2A-26922-14, DfCM composition C03).

  Every case builds a real git repository in a tmp dir, makes real commits,
  and files real standing receipts under the repo-local convention
  `receipts/courts/sa2a/<sha>/chicago/standing_receipt.json`. Receipts are
  issued by the production `AshA2A.Chicago.StandingReceipt.build/1` over the
  subject `AshA2A.Chicago.Subject.capture/1` really captures from that tmp
  repository at that commit (so `source_revision` is the real SHA), and one
  case issues its receipt through the real `AshA2A.Chicago.Runner` against the
  real `AshA2A.Test.ChicagoSelfTest.Court`. Assertions are on the SHA the task
  really prints and the typed refusals it really returns -- no Mock/patch.

  `async: false` -- the runner case attributes CommandBus telemetry to its
  falsifiers, and concurrent CommandBus traffic from other modules must not
  pollute that attribution.
  """

  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  alias AshA2A.Chicago.{Result, Runner, StandingReceipt, Subject}
  alias AshA2A.Chicago.Courts.ObserverQualification
  alias AshA2A.StandingRef
  alias AshA2A.Test.ChicagoSelfTest

  @moduletag :tmp_dir

  describe "mix ash_a2a.standing_ref --court sa2a --standing CONFORMANT" do
    test "two receipted commits, the newer NONCONFORMANT: the task prints the CONFORMANT one",
         %{tmp_dir: dir} do
      repo = init_repo!(dir)

      a = commit!(repo, "app.txt", "v1")
      conformant = build_receipt!(repo, :conformant)
      assert conformant["standing"] == "CONFORMANT"

      b = commit!(repo, "app.txt", "v2")
      nonconformant = build_receipt!(repo, :nonconformant)
      assert nonconformant["standing"] == "NONCONFORMANT"

      file_receipt!(repo, a, conformant)
      file_receipt!(repo, b, nonconformant)
      head = commit_receipts!(repo)

      printed =
        capture_io(fn ->
          Mix.Tasks.AshA2a.StandingRef.run([
            "--repo",
            repo,
            "--court",
            "sa2a",
            "--standing",
            "CONFORMANT"
          ])
        end)

      assert String.trim(printed) == a
      refute a == b

      assert {:ok, resolution} = StandingRef.resolve(repo: repo)
      assert resolution.sha == a
      assert resolution.ref_sha == head
      assert resolution.receipt_digest == conformant["receipt_digest"]
      assert resolution.conformance == "ABSENT"
      assert resolution.commits_walked == 3

      assert [%{sha: ^b, reason: {:standing_mismatch, "NONCONFORMANT"}}] = resolution.refused

      # The same history asked for the NONCONFORMANT standing resolves B.
      assert {:ok, %{sha: ^b}} = StandingRef.resolve(repo: repo, standing: "NONCONFORMANT")
    end

    test "the newest admitted SHA wins; an uncommitted receipt is not durable and is never read",
         %{tmp_dir: dir} do
      repo = init_repo!(dir)
      a = commit!(repo, "app.txt", "v1")
      receipt_a = build_receipt!(repo, :conformant)
      b = commit!(repo, "app.txt", "v2")
      receipt_b = build_receipt!(repo, :conformant)

      file_receipt!(repo, a, receipt_a)
      commit_receipts!(repo)
      assert {:ok, %{sha: ^a}} = StandingRef.resolve(repo: repo)

      # Written to the working tree only: not durable, not found.
      file_receipt!(repo, b, receipt_b)
      assert {:ok, %{sha: ^a}} = StandingRef.resolve(repo: repo)

      # Committed: now durable, and B is newer than A.
      commit_receipts!(repo)
      assert {:ok, %{sha: ^b, refused: []}} = StandingRef.resolve(repo: repo)
    end

    test "CI artifact directories (sa2a-conformance-<sha>/) resolve like git-tracked receipts",
         %{tmp_dir: dir} do
      repo = init_repo!(dir)
      a = commit!(repo, "app.txt", "v1")
      receipt = build_receipt!(repo, :conformant)
      commit!(repo, "app.txt", "v2")

      assert {:error, {:no_admitted_receipt, [], 2}} = StandingRef.resolve(repo: repo)

      artifacts = Path.join(dir, "artifacts")
      path = Path.join([artifacts, "sa2a-conformance-" <> a, "chicago", "standing_receipt.json"])
      File.mkdir_p!(Path.dirname(path))
      File.write!(path, JSON.encode!(receipt))

      assert {:ok, %{sha: ^a, receipt_source: "artifact:" <> _}} =
               StandingRef.resolve(repo: repo, artifacts_dir: artifacts)
    end
  end

  describe "admission is fail-closed and typed" do
    test "a CONFORMANT receipt filed under a SHA it does not attest is refused", %{tmp_dir: dir} do
      repo = init_repo!(dir)
      a = commit!(repo, "app.txt", "v1")
      receipt_a = build_receipt!(repo, :conformant)
      b = commit!(repo, "app.txt", "v2")

      file_receipt!(repo, a, receipt_a)
      file_receipt!(repo, b, receipt_a)
      commit_receipts!(repo)

      assert {:ok, %{sha: ^a, refused: [%{sha: ^b, reason: :subject_revision_mismatch}]}} =
               StandingRef.resolve(repo: repo)
    end

    test "a NONCONFORMANT receipt relabelled CONFORMANT is refused, sealed or not",
         %{tmp_dir: dir} do
      repo = init_repo!(dir)
      a = commit!(repo, "app.txt", "v1")
      receipt_a = build_receipt!(repo, :conformant)
      b = commit!(repo, "app.txt", "v2")
      receipt_b = build_receipt!(repo, :nonconformant)
      c = commit!(repo, "app.txt", "v3")
      receipt_c = build_receipt!(repo, :nonconformant)

      relabelled = Map.put(receipt_b, "standing", "CONFORMANT")

      resealed =
        receipt_c
        |> Map.put("standing", "CONFORMANT")
        |> then(&Map.put(&1, "receipt_digest", StandingReceipt.digest(&1)))

      assert :ok = StandingReceipt.verify_digest(resealed)

      file_receipt!(repo, a, receipt_a)
      file_receipt!(repo, b, relabelled)
      file_receipt!(repo, c, resealed)
      commit_receipts!(repo)

      assert {:ok, %{sha: ^a, refused: refused}} = StandingRef.resolve(repo: repo)

      assert Enum.map(refused, &{&1.sha, &1.reason}) == [
               {c, :standing_inconsistent_with_receipt},
               {b, :receipt_digest_mismatch}
             ]
    end

    test "a receipt whose subject was dirty is refused", %{tmp_dir: dir} do
      repo = init_repo!(dir)
      a = commit!(repo, "app.txt", "v1")
      clean = build_receipt!(repo, :conformant)
      b = commit!(repo, "app.txt", "v2")

      File.write!(Path.join(repo, "app.txt"), "v2 + uncommitted edit")
      dirty = build_receipt!(repo, :conformant)
      assert dirty["subject"]["dirty"] == true
      git!(repo, ["checkout", "--", "app.txt"])

      file_receipt!(repo, a, clean)
      file_receipt!(repo, b, dirty)
      commit_receipts!(repo)

      assert {:ok, %{sha: ^a, refused: [%{sha: ^b, reason: :subject_dirty}]}} =
               StandingRef.resolve(repo: repo)
    end

    test "a co-located conformance receipt is bound to the subject's wasm; PASS is required only on request",
         %{tmp_dir: dir} do
      repo = init_repo!(dir)
      a = commit!(repo, "app.txt", "v1")
      receipt_a = build_receipt!(repo, :conformant)
      b = commit!(repo, "app.txt", "v2")
      receipt_b = build_receipt!(repo, :conformant)
      c = commit!(repo, "app.txt", "v3")
      receipt_c = build_receipt!(repo, :conformant)
      d = commit!(repo, "app.txt", "v4")
      receipt_d = build_receipt!(repo, :conformant)

      wasm = receipt_a["subject"]["validator_digests"]["graphlaw_wasm"]
      assert is_binary(wasm)

      # A PASS label its own assertions contradict is forged.
      forged =
        put_in(conformance(wasm, true), ["assertions", "same_input_identity", "value"], false)

      file_receipt!(repo, a, receipt_a, %{"sa2a-conformance.json" => conformance(wasm, true)})
      file_receipt!(repo, b, receipt_b, %{"sa2a-conformance.json" => conformance(wasm, false)})

      file_receipt!(repo, c, receipt_c, %{
        "sa2a-conformance.json" => conformance(String.duplicate("0", 64), true)
      })

      file_receipt!(repo, d, receipt_d, %{"sa2a-conformance.json" => forged})
      commit_receipts!(repo)

      # Default: the Chicago standing addresses the SHA; a FAIL over the
      # subject's own wasm is reported, not re-judged.
      assert {:ok, %{sha: ^b, conformance: "FAIL", refused: refused}} =
               StandingRef.resolve(repo: repo)

      assert Enum.map(refused, &{&1.sha, &1.reason}) == [
               {d, :conformance_assertion_not_passed},
               {c, :conformance_wasm_not_subject_wasm}
             ]

      # Strict: the conformance receipt must be present and PASS.
      assert {:ok, %{sha: ^a, conformance: "PASS", refused: strict_refused}} =
               StandingRef.resolve(repo: repo, require_conformance: true)

      assert Enum.map(strict_refused, &{&1.sha, &1.reason}) == [
               {d, :conformance_assertion_not_passed},
               {c, :conformance_wasm_not_subject_wasm},
               {b, {:conformance_result, "FAIL"}}
             ]

      printed =
        capture_io(fn ->
          Mix.Tasks.AshA2a.StandingRef.run(["--repo", repo, "--require-conformance"])
        end)

      assert String.trim(printed) == a
    end

    test "no admitted receipt: the task prints no SHA and exits non-zero with the refusals",
         %{tmp_dir: dir} do
      repo = init_repo!(dir)
      b = commit!(repo, "app.txt", "v1")
      file_receipt!(repo, b, build_receipt!(repo, :nonconformant))
      commit_receipts!(repo)

      stderr =
        capture_io(:stderr, fn ->
          stdout =
            capture_io(fn ->
              assert_raise Mix.Error, ~r/no durable sa2a receipt admitted/, fn ->
                Mix.Tasks.AshA2a.StandingRef.run(["--repo", repo])
              end
            end)

          assert stdout == ""
        end)

      assert stderr =~ "refused #{b}"
      assert stderr =~ "NONCONFORMANT"

      assert {:error, {:unsupported_court, "nope"}} =
               StandingRef.resolve(repo: repo, court: "nope")

      assert {:error, {:unknown_standing, "GREEN"}} =
               StandingRef.resolve(repo: repo, standing: "GREEN")
    end
  end

  describe "a receipt issued by the real Chicago runner" do
    test "resolves at its real standing and is refused as CONFORMANT", %{tmp_dir: dir} do
      repo = init_repo!(dir)
      a = commit!(repo, "app.txt", "v1")

      assert {:ok, run} =
               Runner.run(
                 profile: :core,
                 courts: [ChicagoSelfTest.Court],
                 evidence_dir: Path.join(dir, "evidence"),
                 subject_opts: [repo: repo]
               )

      receipt = JSON.decode!(File.read!(Path.join([dir, "evidence", "standing_receipt.json"])))
      assert receipt["subject"]["source_revision"] == a
      assert receipt["standing"] == run.receipt["standing"]
      assert receipt["standing"] == "PARTIAL_ALIVE"

      file_receipt!(repo, a, receipt)
      commit_receipts!(repo)

      assert {:ok, %{sha: ^a, standing: "PARTIAL_ALIVE"}} =
               StandingRef.resolve(repo: repo, standing: "PARTIAL_ALIVE")

      assert {:error,
              {:no_admitted_receipt, [%{sha: ^a, reason: {:standing_mismatch, "PARTIAL_ALIVE"}}],
               _}} =
               StandingRef.resolve(repo: repo)
    end
  end

  # --- real git + real receipts ---------------------------------------------------

  defp init_repo!(dir) do
    repo = Path.join(dir, "subject")
    File.mkdir_p!(repo)
    git!(repo, ["init", "-q", "-b", "main"])
    git!(repo, ["config", "user.email", "standing-ref@example.invalid"])
    git!(repo, ["config", "user.name", "standing-ref test"])
    git!(repo, ["config", "commit.gpgsign", "false"])
    repo
  end

  defp commit!(repo, file, content) do
    File.write!(Path.join(repo, file), content)
    git!(repo, ["add", file])
    git!(repo, ["commit", "-q", "--no-verify", "-m", "#{file}: #{content}"])
    git!(repo, ["rev-parse", "HEAD"])
  end

  defp commit_receipts!(repo) do
    git!(repo, ["add", "receipts"])
    git!(repo, ["commit", "-q", "--no-verify", "-m", "receipts"])
    git!(repo, ["rev-parse", "HEAD"])
  end

  defp file_receipt!(repo, sha, receipt, extra \\ %{}) do
    dir = Path.join(repo, StandingRef.receipt_dir("sa2a", sha))
    path = Path.join(dir, StandingRef.standing_file("sa2a"))
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, JSON.encode!(receipt))
    Enum.each(extra, fn {name, doc} -> File.write!(Path.join(dir, name), JSON.encode!(doc)) end)
  end

  defp git!(repo, args) do
    {out, 0} = System.cmd("git", args, cd: repo, stderr_to_stdout: true)
    String.trim(out)
  end

  # The production receipt builder over the subject really captured from the
  # tmp repository at its current HEAD. `:nonconformant` records one survived
  # falsifier; everything else is corroborated, gates 1-3 (SA2A-CORE) covered.
  defp build_receipt!(repo, standing) do
    falsifiers = ObserverQualification.falsifiers()
    f = Enum.find(falsifiers, &(&1.kind == :negative))

    results =
      for gate <- 1..3 do
        survived? = standing == :nonconformant and gate == 2

        %{
          Result.negative(f, attempt_observed?: true, forbidden_outcome_observed?: survived?)
          | gate: gate,
            ocel_corroborated?: true
        }
      end

    StandingReceipt.build(%{
      profile: :core,
      subject: Subject.capture(repo: repo),
      courts: [ObserverQualification],
      falsifiers: falsifiers,
      results: results,
      ocel: %{
        sha256: String.duplicate("a", 64),
        bytes: 1,
        events: 1,
        objects: 1,
        mapping_digest: "standing-ref",
        dropped: 0,
        gaps: 0
      },
      ocel_validation: %{status: :valid, validator: "independent", report: %{}},
      run_id: "standing-ref-#{System.unique_integer([:positive])}"
    })
  end

  defp conformance(wasm_digest, pass?) do
    assertion = %{"computed" => true, "value" => pass?, "detail" => nil, "divergences" => []}

    %{
      "profile" => "SA2A-PORTABLE-EXECUTION",
      "wasm_digest" => wasm_digest,
      "wasm_digest_algorithm" => "sha256",
      "assertions" =>
        Map.new(AshA2A.SA2A.Conformance.assertion_names(), &{Atom.to_string(&1), assertion}),
      "result" => if(pass?, do: "PASS", else: "FAIL")
    }
  end
end
