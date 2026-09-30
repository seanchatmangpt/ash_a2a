defmodule AshA2A.CapabilityReleaseStandingClosureTest do
  use ExUnit.Case, async: false

  alias AshA2A.CapabilityRelease
  alias AshA2A.Chicago.{Result, StandingReceipt, Subject}
  alias AshA2A.Chicago.Courts.ObserverQualification

  @moduletag :tmp_dir

  defp digest(char), do: "sha256:" <> String.duplicate(char, 64)

  test "standing-strict release binds and replays the exact durable subject", %{tmp_dir: dir} do
    repo = init_repo!(dir)
    subject_sha = commit!(repo, "app.txt", "v1")
    receipt = receipt!(repo)
    file_receipt!(repo, subject_sha, receipt)
    _receipt_commit = commit_receipts!(repo)

    candidate =
      CapabilityRelease.candidate("standing.cap", "26.9.30", digest("a"),
        subject_revision: subject_sha
      )

    {:ok, admitted} = CapabilityRelease.admit(candidate, digest("b"))

    assert {:ok, released} =
             CapabilityRelease.release_from_standing(admitted,
               repo: repo,
               court: "sa2a",
               standing: "CONFORMANT"
             )

    assert released.standing_binding.subject_revision == subject_sha
    assert released.standing_binding.technical_standing == "CONFORMANT"
    assert released.standing_binding.external_standing == "NONE"
    assert released.standing_binding.runtime_authority == "NONE"
    assert released.release_digest == released.standing_binding.portable_identity

    assert {:ok, closure} = CapabilityRelease.freeze_standing([released])

    assert {:ok, binding} =
             CapabilityRelease.binding("standing.cap",
               capability_release_mode: :standing_strict,
               capability_release_closure: closure,
               repo: repo
             )

    attrs = CapabilityRelease.attributes(binding)
    assert attrs.standing_subject_revision == subject_sha
    assert attrs.technical_standing == "CONFORMANT"
    assert attrs.external_standing == "NONE"
    assert attrs.runtime_authority == "NONE"
    refute Map.has_key?(attrs, :authority)
  end

  test "standing-strict refuses a digest-only legacy release" do
    candidate = CapabilityRelease.candidate("legacy.cap", "26.9.30", digest("a"))
    {:ok, admitted} = CapabilityRelease.admit(candidate, digest("b"))
    {:ok, released} = CapabilityRelease.release(admitted, digest("c"))
    assert {:ok, closure} = CapabilityRelease.freeze([released])

    assert :ok =
             CapabilityRelease.guard("legacy.cap",
               capability_release_mode: :strict,
               capability_release_closure: closure
             )

    assert {:error, {:technical_standing_required, "legacy.cap"}} =
             CapabilityRelease.guard("legacy.cap",
               capability_release_mode: :standing_strict,
               capability_release_closure: closure
             )
  end

  test "stale exact-subject standing cannot release", %{tmp_dir: dir} do
    repo = init_repo!(dir)
    subject_sha = commit!(repo, "app.txt", "v1")
    receipt = receipt!(repo)
    file_receipt!(repo, subject_sha, receipt)
    _receipt_commit = commit_receipts!(repo)

    candidate =
      CapabilityRelease.candidate("stale.cap", "26.9.30", digest("a"),
        subject_revision: String.duplicate("f", 40)
      )

    {:ok, admitted} = CapabilityRelease.admit(candidate, digest("b"))

    assert {:error, {:standing_exact_subject_mismatch, _, ^subject_sha}} =
             CapabilityRelease.release_from_standing(admitted,
               repo: repo,
               standing: "CONFORMANT"
             )
  end

  test "standing-strict advertising equals executable closure", %{tmp_dir: dir} do
    repo = init_repo!(dir)
    subject_sha = commit!(repo, "app.txt", "v1")
    receipt = receipt!(repo)
    file_receipt!(repo, subject_sha, receipt)
    _receipt_commit = commit_receipts!(repo)

    candidate =
      CapabilityRelease.candidate("standing.cap", "26.9.30", digest("a"),
        subject_revision: subject_sha
      )

    {:ok, admitted} = CapabilityRelease.admit(candidate, digest("b"))
    {:ok, released} = CapabilityRelease.release_from_standing(admitted, repo: repo)
    {:ok, closure} = CapabilityRelease.freeze_standing([released])

    skills = [%{id: "candidate"}, %{id: "standing.cap"}]

    assert {:ok, [%{id: "standing.cap"}]} =
             CapabilityRelease.filter_skills(skills,
               capability_release_mode: :standing_strict,
               capability_release_closure: closure,
               repo: repo
             )
  end

  defp init_repo!(dir) do
    repo = Path.join(dir, "subject")
    File.mkdir_p!(repo)
    git!(repo, ["init", "-q", "-b", "main"])
    git!(repo, ["config", "user.email", "standing@example.invalid"])
    git!(repo, ["config", "user.name", "standing"])
    git!(repo, ["config", "commit.gpgsign", "false"])
    repo
  end

  defp commit!(repo, file, body) do
    File.write!(Path.join(repo, file), body)
    git!(repo, ["add", file])
    git!(repo, ["commit", "-q", "--no-verify", "-m", file])
    git!(repo, ["rev-parse", "HEAD"])
  end

  defp file_receipt!(repo, sha, receipt) do
    path =
      Path.join([
        repo,
        AshA2A.StandingRef.receipt_dir("sa2a", sha),
        AshA2A.StandingRef.standing_file("sa2a")
      ])

    File.mkdir_p!(Path.dirname(path))
    File.write!(path, JSON.encode!(receipt))
  end

  defp commit_receipts!(repo) do
    git!(repo, ["add", "receipts"])
    git!(repo, ["commit", "-q", "--no-verify", "-m", "standing receipt"])
    git!(repo, ["rev-parse", "HEAD"])
  end

  defp receipt!(repo) do
    falsifiers = ObserverQualification.falsifiers()
    falsifier = Enum.find(falsifiers, &(&1.kind == :negative))

    results =
      for gate <- 1..3 do
        %{
          Result.negative(falsifier,
            attempt_observed?: true,
            forbidden_outcome_observed?: false
          )
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
        mapping_digest: "standing-closure",
        dropped: 0,
        gaps: 0
      },
      ocel_validation: %{status: :valid, validator: "independent", report: %{}},
      run_id: "standing-closure"
    })
  end

  defp git!(repo, args) do
    {out, 0} = System.cmd("git", args, cd: repo, stderr_to_stdout: true)
    String.trim(out)
  end
end
