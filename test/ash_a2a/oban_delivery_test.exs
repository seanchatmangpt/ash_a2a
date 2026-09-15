defmodule AshA2A.ObanDeliveryTest do
  use ExUnit.Case, async: true

  alias AshA2A.{Authority, Command, Delivery, Identity, SemanticSubject}

  test "provider delivery id remains distinct from A2A task id" do
    command =
      Command.new("Example.Resource.read",
        command_id: "command-1",
        agent_id: "agent-1",
        principal_id: "principal-1",
        task_id: "task-1"
      )

    delivery = Delivery.new(:oban, command, provider_ref: 42, status: :scheduled)

    assert Delivery.task_key(delivery) == "task:task-1"
    assert delivery.provider_ref == 42
    refute delivery.provider_ref == Delivery.task_key(delivery)
  end

  test "Oban payload carries command references but not execution identity" do
    principal = Identity.principal("principal-1")
    authority = Authority.new(principal, "Example.Resource.update", token_id: "auth-1")

    command =
      Command.new("Example.Resource.update",
        command_id: "command-2",
        agent_id: "agent-1",
        principal_id: principal,
        task_id: "task-2",
        authority: authority,
        input: %{value: 7}
      )

    payload = Delivery.Oban.payload(command)

    assert payload["command_id"] == "command:command-2"
    assert payload["task_id"] == "task:task-2"
    assert payload["authority_token_id"] == "runtime:auth-1"
    assert payload["fingerprint"] == command.fingerprint
    refute Map.has_key?(payload, "execution_id")

    # No semantic_subject on this command -- byte-identical to before
    # semantic_subject fields existed on the payload at all.
    refute Map.has_key?(payload, "semantic_subject_graph_digest")
    refute Map.has_key?(payload, "semantic_subject_projection_digest")
    refute Map.has_key?(payload, "semantic_subject_manufacturer_digest")
    refute Map.has_key?(payload, "semantic_subject_ephemeral")
  end

  test "Oban payload carries a real non-nil semantic_subject's fields so fingerprint can round-trip" do
    principal = Identity.principal("principal-3")

    {:ok, semantic_subject} =
      SemanticSubject.new(
        graph_digest: "sha256:" <> String.duplicate("a", 64),
        projection_digest: "sha256:" <> String.duplicate("b", 64),
        manufacturer_digest: "sha256:" <> String.duplicate("c", 64),
        ephemeral?: false
      )

    command =
      Command.new("Example.Resource.update",
        command_id: "command-3",
        agent_id: "agent-1",
        principal_id: principal,
        semantic_subject: semantic_subject,
        input: %{value: 9}
      )

    payload = Delivery.Oban.payload(command)

    assert payload["semantic_subject_graph_digest"] == semantic_subject.graph_digest
    assert payload["semantic_subject_projection_digest"] == semantic_subject.projection_digest
    assert payload["semantic_subject_manufacturer_digest"] == semantic_subject.manufacturer_digest
    assert payload["semantic_subject_ephemeral"] == false

    # Reconstructing a real SemanticSubject from the carried payload fields
    # (mirroring AshA2A.Test.Support.CommandWorker.reconstruct_semantic_subject/1)
    # and rebuilding the Command from it must recompute the exact same
    # fingerprint the original command carries -- the real regression this
    # payload/1 fix closes: before it, a reconstructed command with a real
    # semantic_subject computed a DIFFERENT fingerprint than the original,
    # because the semantic_subject fields never reached the worker at all.
    {:ok, reconstructed_subject} =
      SemanticSubject.new(
        graph_digest: payload["semantic_subject_graph_digest"],
        projection_digest: payload["semantic_subject_projection_digest"],
        manufacturer_digest: payload["semantic_subject_manufacturer_digest"],
        ephemeral?: payload["semantic_subject_ephemeral"]
      )

    reconstructed =
      Command.new(payload["capability_id"],
        command_id: "command-3",
        agent_id: "agent-1",
        principal_id: principal,
        semantic_subject: reconstructed_subject,
        input: payload["input"]
      )

    assert Command.fingerprint(reconstructed) == command.fingerprint
  end
end
