defmodule AshA2A.CapabilityReleaseStandingTest do
  use ExUnit.Case, async: false

  alias AshA2A.CapabilityRelease
  alias AshA2A.Chicago.{Result, StandingReceipt, Subject}
  alias AshA2A.Chicago.Courts.ObserverQualification

  @moduletag :tmp_dir

  defp digest(char), do: "sha256:" <> String.duplicate(char, 64)

  defp admitted(id \\ "standing.cap") do
    candidate = CapabilityRelease.candidate(id, "26.9.30", digest("a"))
    {:ok, admitted} = CapabilityRelease.admit(candidate, digest("b"))
    admitted
  end

  test "standing release resolves a real durable exact-subject court receipt", %{tmp_dir: dir} do
    repo = init_repo!(dir)
    subject_sha = commit!(repo, "app.txt", "v1")
    receipt = build_receipt!(repo)

    file_receipt!(repo, subject_sha, receipt)
    _receipt_commit = commit_receipts!(repo)

    assert {:ok, released} =
             CapabilityRelease.release_from_standing(admitted(),
               repo: repo,
               court: "sa2a",
               standing: "CONFORMANT"
             )

    assert released.state == :released
    assert released.release_digest == "sha256:" <> receipt["receipt_digest"]
    assert released.standing_binding.court == "sa2a"
    assert released.standing_binding.standing == "CONFORMANT"
    assert released.standing_binding.subject_sha == subject_sha
    assert released.standing_binding.receipt_digest == released.release_digest
    assert released.standing_binding.receipt_source =~ "git:"
    assert String.starts_with?(released.standing_binding.binding_digest, "sha256:")

    assert {:ok, closure} = CapabilityRelease.freeze_standing([released])
    assert {:ok, binding} =
             CapabilityRelease.binding("standing.cap",
               capability_release_mode: :standing_strict,
               capability_release_closure: closure
             )

    attrs = CapabilityRelease.attributes(binding)

    assert attrs.technical_standing == "CONFORMANT"
    assert attrs.technical_standing_court == "sa2a"
    assert attrs.technical_standing_subject_sha == subject_sha
    assert attrs.technical_standing_receipt_digest == released.release_digest
    refute Map.has_key?(attrs, :authority)
    refute Map.has_key?(attrs, :external_standing)
  end

  test "legacy strict remains compatible while standing_strict refuses digest-only releases" do
    {:ok, released} = CapabilityRelease.release(admitted("legacy.cap"), digest("c"))
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

    assert {:error, {:technical_standing_required, "legacy.cap"}} =
             CapabilityRelease.freeze_standing([released])
  end

  test "standing release fails closed when no durable admitted receipt exists", %{tmp_dir: dir} do
    repo = init_repo!(dir)
    _subject_sha = commit!(repo, "app.txt", "v1")

    assert {:error, {:no_admitted_receipt, [], 1}} =
             CapabilityRelease.release_from_standing(admitted(), repo: repo)
  end

  test "standing_strict advertising equals its executable closure" , %{tmp_dir: dir} do
    repo = init_repo!(dir)
    subject_sha = commit!(repo, "app.txt", "v1")
    receipt = build_receipt!(repo)
    file_receipt!(repo, subject_sha, receipt)
    commit_receipts!(repo)

    assert {:ok, released} =
             CapabilityRelease.release_from_standing(admitted(), repo: repo)

    assert {:ok, closure} = CapabilityRelease.freeze_standing([released])

    skills = [
      %{id: "candidate", name: :candidate},
      %{id: "standing.cap", name: :standing}
    ]

    assert {:ok, [%{id: "standing.cap"} = advertised]} =
             CapabilityRelease.filter_skills(skills,
               capability_release_mode: :standing_strict,
               capability_release_closure: closure
             )

    assert advertised.name == :standing

    assert :ok =
             CapabilityRelease.guard(advertised.id,
               capability_release_mode: :standing_strict,
               capability_release_closure: closure
             )
  end

  defp init_repo!(dir) do
    repo = Path.join(dir, "subject")
    File.mkdir_p!(repo)
    git!(repo, ["init", "-q", "-b", "main"])
    git!(repo, ["config", "user.email", "standing-closure@example.invalid"])
    git!(repo, ["config", "user.name", "standing closure test"])
    git!(repo, ["config", "commit.gpgsign", "false"])
    repo
  end

  defp commit!(repo, file, body) do
    File.write!(Path.join(repo, file), body)
    git!(repo, ["add", file])
    git!(repo, ["commit", "-q", "--no-verify", "-m", "#{file}: #{body}"])
    git!(repo, ["rev-parse", "HEAD"])
  end

  defp file_receipt!(repo, sha, receipt) do
    dir = Path.join(repo, AshA2A.StandingRef.receipt_dir("sa2a", sha))
    path = Path.join(dir, AshA2A.StandingRef.standing_file("sa2a"))
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, JSON.encode!(receipt))
  end

  defp commit_receipts!(repo) do
    git!(repo, ["add", "receipts"])
    git!(repo, ["commit", "-q", "--no-verify", "-m", "standing receipt"])
    git!(repo, ["rev-parse", "HEAD"])
  end

  defp build_receipt!(repo) do
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
        mapping_digest: "capability-release-standing",
        dropped: 0,
        gaps: 0
      },
      ocel_validation: %{status: :valid, validator: "independent", report: %{}},
      run_id: "capability-release-standing-#{System.unique_integer([:positive])}"
    })
  end

  defp git!(repo, args) do
    {out, 0} = System.cmd("git", args, cd: repo, stderr_to_stdout: true)
    String.trim(out)
  end
end
