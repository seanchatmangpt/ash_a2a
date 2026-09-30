defmodule AshA2A.CapabilityReleaseStandingIntegrationTest do
  use ExUnit.Case, async: false
  alias AshA2A.CapabilityRelease
  alias AshA2A.Chicago.{Result, StandingReceipt, Subject}
  alias AshA2A.Chicago.Courts.ObserverQualification
  @moduletag :tmp_dir
  defp digest(c), do: "sha256:" <> String.duplicate(c, 64)

  test "real durable exact-subject receipt is required", %{tmp_dir: dir} do
    repo = init_repo!(dir)
    sha = commit!(repo, "app.txt", "v1")
    receipt = receipt!(repo)
    path = Path.join([repo, AshA2A.StandingRef.receipt_dir("sa2a", sha), AshA2A.StandingRef.standing_file("sa2a")])
    File.mkdir_p!(Path.dirname(path)); File.write!(path, JSON.encode!(receipt))
    git!(repo, ["add", "receipts"]); git!(repo, ["commit", "-q", "--no-verify", "-m", "receipt"])

    candidate = CapabilityRelease.candidate("standing.cap", "26.9.30", digest("a"), subject_revision: sha)
    {:ok, admitted} = CapabilityRelease.admit(candidate, digest("b"))
    assert {:error, {:standing_binding_required, _}} = CapabilityRelease.release(admitted, digest("c"))
    assert {:ok, released} = CapabilityRelease.release(admitted, repo: repo, standing: "CONFORMANT")
    assert released.standing_binding.subject_revision == sha
    assert released.standing_binding.technical_standing == "CONFORMANT"
    assert released.standing_binding.external_standing == "NONE"
    assert released.standing_binding.runtime_authority == "NONE"
    assert {:ok, closure} = CapabilityRelease.freeze([released])
    assert {:ok, binding} = CapabilityRelease.binding("standing.cap", capability_release_closure: closure, repo: repo)
    attrs = CapabilityRelease.attributes(binding)
    assert attrs.standing_subject_revision == sha
    assert attrs.external_standing == "NONE"
    assert attrs.runtime_authority == "NONE"

    stale = %{admitted | subject_revision: String.duplicate("f", 40)}
    assert {:error, {:standing_exact_subject_mismatch, _, ^sha}} =
             CapabilityRelease.release(stale, repo: repo, standing: "CONFORMANT")
  end


  test "mutated artifact receipt is refused at strict runtime replay", %{tmp_dir: dir} do
    repo = init_repo!(Path.join(dir, "artifact-case"))
    sha = commit!(repo, "app.txt", "v1")
    receipt = receipt!(repo)
    artifacts = Path.join(dir, "artifacts")
    artifact_dir = Path.join(artifacts, "sa2a-conformance-" <> sha)
    receipt_path = Path.join([artifact_dir, AshA2A.StandingRef.standing_file("sa2a")])
    File.mkdir_p!(Path.dirname(receipt_path))
    File.write!(receipt_path, JSON.encode!(receipt))

    candidate =
      CapabilityRelease.candidate("artifact.cap", "26.9.30", digest("d"),
        subject_revision: sha
      )

    {:ok, admitted} = CapabilityRelease.admit(candidate, digest("e"))

    assert {:ok, released} =
             CapabilityRelease.release(admitted,
               repo: repo,
               artifacts_dir: artifacts,
               standing: "CONFORMANT"
             )

    assert String.starts_with?(released.standing_binding.receipt_source, "artifact:")
    assert {:ok, closure} = CapabilityRelease.freeze([released])

    mutated = Map.put(receipt, "claim", "mutated after release")
    File.write!(receipt_path, JSON.encode!(mutated))

    assert {:error, _reason} =
             CapabilityRelease.binding("artifact.cap",
               capability_release_closure: closure,
               repo: repo,
               artifacts_dir: artifacts
             )
  end

  defp init_repo!(dir) do
    repo = Path.join(dir, "subject"); File.mkdir_p!(repo)
    git!(repo, ["init", "-q", "-b", "main"])
    git!(repo, ["config", "user.email", "standing@example.invalid"])
    git!(repo, ["config", "user.name", "standing"])
    git!(repo, ["config", "commit.gpgsign", "false"]); repo
  end
  defp commit!(repo, file, body) do
    File.write!(Path.join(repo, file), body); git!(repo, ["add", file])
    git!(repo, ["commit", "-q", "--no-verify", "-m", file]); git!(repo, ["rev-parse", "HEAD"])
  end
  defp receipt!(repo) do
    fs = ObserverQualification.falsifiers(); f = Enum.find(fs, &(&1.kind == :negative))
    rs = for gate <- 1..3, do: %{Result.negative(f, attempt_observed?: true, forbidden_outcome_observed?: false) | gate: gate, ocel_corroborated?: true}
    StandingReceipt.build(%{profile: :core, subject: Subject.capture(repo: repo), courts: [ObserverQualification],
      falsifiers: fs, results: rs,
      ocel: %{sha256: String.duplicate("a",64), bytes: 1, events: 1, objects: 1, mapping_digest: "standing", dropped: 0, gaps: 0},
      ocel_validation: %{status: :valid, validator: "independent", report: %{}}, run_id: "standing-integration"})
  end
  defp git!(repo, args) do
    {out, 0} = System.cmd("git", args, cd: repo, stderr_to_stdout: true); String.trim(out)
  end
end
