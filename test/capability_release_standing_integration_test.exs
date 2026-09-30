defmodule AshA2A.CapabilityReleaseStandingIntegrationTest do
  use ExUnit.Case, async: false
  import AshA2A.Test.MessageHelpers

  alias AshA2A.{Authority, CapabilityRelease, Command, CommandBus, Identity}
  alias AshA2A.Chicago.{Result, StandingReceipt, Subject}
  alias AshA2A.Chicago.Courts.ObserverQualification
  alias AshA2A.Test.ActuatorCounter
  alias AshA2A.Test.Fixture.AuthorityProbe

  @moduletag :tmp_dir
  @capability "AshA2A.Test.Fixture.AuthorityProbe.actuate"

  defp digest(c), do: "sha256:" <> String.duplicate(c, 64)

  defmodule MutatingStore do
    @behaviour AshA2A.ReceiptStore

    alias AshA2A.ReceiptStore.Memory

    def claim(command, opts), do: Memory.claim(command, opts)
    def commit(receipt, opts), do: Memory.commit(receipt, opts)
    def fetch(command_id, opts), do: Memory.fetch(command_id, opts)
    def claim_actuation(actuation, command, opts), do: Memory.claim_actuation(actuation, command, opts)
    def commit_actuation(actuation, receipt, opts), do: Memory.commit_actuation(actuation, receipt, opts)
    def release_actuation(actuation, opts), do: Memory.release_actuation(actuation, opts)

    def confirm_claim(command_id, execution_id, opts) do
      File.write!(Keyword.fetch!(opts, :mutate_receipt_path), Keyword.fetch!(opts, :mutated_receipt))
      Memory.confirm_claim(command_id, execution_id, opts)
    end
  end

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
    assert released.release_digest == released.standing_binding.portable_identity
    assert {:ok, closure} = CapabilityRelease.freeze([released], repo: repo)
    assert {:ok, ^released} = CapabilityRelease.select(closure, "standing.cap")
    assert CapabilityRelease.released_ids(closure) == ["standing.cap"]
    assert :ok = CapabilityRelease.guard("standing.cap", capability_release_closure: closure, repo: repo)
    assert {:ok, binding} =
             CapabilityRelease.binding("standing.cap",
               capability_release_closure: closure,
               repo: repo
             )

    assert {:ok, [%{id: "standing.cap"}]} =
             CapabilityRelease.filter_skills(
               [%{id: "candidate"}, %{id: "standing.cap"}],
               capability_release_closure: closure,
               repo: repo
             )

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
    assert {:ok, closure} =
             CapabilityRelease.freeze([released], repo: repo, artifacts_dir: artifacts)

    mutated = Map.put(receipt, "claim", "mutated after release")
    File.write!(receipt_path, JSON.encode!(mutated))

    assert {:error, _reason} =
             CapabilityRelease.binding("artifact.cap",
               capability_release_closure: closure,
               repo: repo,
               artifacts_dir: artifacts
             )
  end

  test "pre-DO replay refuses standing mutated after initial binding and preserves non-authority receipt evidence", %{tmp_dir: dir} do
    repo = init_repo!(Path.join(dir, "pre-do-case"))
    sha = commit!(repo, "app.txt", "v1")
    receipt = receipt!(repo)
    artifacts = Path.join(dir, "pre-do-artifacts")
    artifact_dir = Path.join(artifacts, "sa2a-conformance-" <> sha)
    receipt_path = Path.join([artifact_dir, AshA2A.StandingRef.standing_file("sa2a")])
    File.mkdir_p!(Path.dirname(receipt_path))
    File.write!(receipt_path, JSON.encode!(receipt))

    candidate =
      CapabilityRelease.candidate(@capability, "26.9.30", digest("8"),
        subject_revision: sha
      )

    {:ok, admitted} = CapabilityRelease.admit(candidate, digest("9"))

    assert {:ok, released} =
             CapabilityRelease.release(admitted,
               repo: repo,
               artifacts_dir: artifacts,
               standing: "CONFORMANT"
             )

    assert {:ok, closure} =
             CapabilityRelease.freeze([released], repo: repo, artifacts_dir: artifacts)

    start_supervised!(ActuatorCounter)

    store_name =
      Module.concat(__MODULE__, "Store#{System.unique_integer([:positive])}")

    start_supervised!({AshA2A.ReceiptStore.Memory, name: store_name})

    prior_outbox = Application.get_env(:ash_a2a, :receipt_outbox_dir)
    outbox = Path.join(dir, "pre-do-outbox")
    Application.put_env(:ash_a2a, :receipt_outbox_dir, outbox)

    on_exit(fn ->
      if prior_outbox do
        Application.put_env(:ash_a2a, :receipt_outbox_dir, prior_outbox)
      else
        Application.delete_env(:ash_a2a, :receipt_outbox_dir)
      end
    end)

    principal = Identity.principal("standing-operator")

    command =
      Command.new(@capability,
        command_id: "standing-pre-do-#{System.unique_integer([:positive])}",
        agent_id: "standing-agent",
        principal_id: principal,
        authority: Authority.new(principal, @capability, token_id: "standing-pre-do-token"),
        input: %{}
      )

    mutated =
      receipt
      |> Map.put("claim", "mutated after initial release binding and before DO")
      |> JSON.encode!()

    assert ActuatorCounter.count() == 0

    assert {:error, %{code: :capability_release_refused, receipt: refusal_receipt}} =
             CommandBus.run(
               command,
               data_message(%{}),
               AuthorityProbe,
               store: MutatingStore,
               store_opts: [
                 name: store_name,
                 mutate_receipt_path: receipt_path,
                 mutated_receipt: mutated
               ],
               capability_release_closure: closure,
               repo: repo,
               artifacts_dir: artifacts
             )

    assert ActuatorCounter.count() == 0

    intended = refusal_receipt.intended_effect
    assert intended.standing_binding_identity == released.standing_binding.portable_identity
    assert intended.standing_subject_revision == sha
    assert intended.standing_receipt_digest == released.standing_binding.receipt_digest
    assert intended.technical_standing == "CONFORMANT"
    assert intended.external_standing == "NONE"
    assert intended.runtime_authority == "NONE"
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
