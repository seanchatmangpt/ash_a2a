defmodule AshA2A.SemanticSubjectCommandTest do
  use ExUnit.Case, async: true

  alias AshA2A.{Command, Identity, Receipt, SemanticSubject}

  @a "sha256:" <> String.duplicate("a", 64)
  @b "sha256:" <> String.duplicate("b", 64)
  @c "sha256:" <> String.duplicate("c", 64)
  @d "sha256:" <> String.duplicate("d", 64)

  test "command fingerprint is scoped to exact semantic graph and projection" do
    assert {:ok, subject_a} =
             SemanticSubject.new(
               graph_digest: @a,
               projection_digest: @b,
               manufacturer_digest: @c
             )

    assert {:ok, subject_b} =
             SemanticSubject.new(
               graph_digest: @d,
               projection_digest: @b,
               manufacturer_digest: @c
             )

    opts = [agent_id: "agent-1", principal_id: "principal-1", input: %{"id" => 1}]

    command_a = Command.new("people.read", Keyword.put(opts, :semantic_subject, subject_a))
    command_b = Command.new("people.read", Keyword.put(opts, :semantic_subject, subject_b))

    refute command_a.fingerprint == command_b.fingerprint
  end

  test "receipt carries the same exact semantic subject without granting authority" do
    assert {:ok, subject} =
             SemanticSubject.new(
               graph_digest: @a,
               projection_digest: @b,
               manufacturer_digest: @c
             )

    command =
      Command.new("people.read",
        agent_id: "agent-1",
        principal_id: "principal-1",
        semantic_subject: subject
      )

    receipt = Receipt.from_reply(command, Identity.new(:execution, "execution-1"), :read, {:reply, :ok})

    assert receipt.semantic_subject == subject
    assert receipt.fingerprint == command.fingerprint
    assert receipt.standing == :observed
  end

  test "legacy commands remain valid without a semantic subject" do
    command = Command.new("people.read", agent_id: "agent-1", principal_id: "principal-1")
    assert command.semantic_subject == nil

    receipt = Receipt.from_reply(command, Identity.new(:execution, "execution-1"), :read, {:reply, :ok})
    assert receipt.semantic_subject == nil
  end

  test "malformed graph identity is refused" do
    assert {:error, {:refused_semantic_subject, :graph_digest}} =
             SemanticSubject.new(
               graph_digest: "not-a-digest",
               projection_digest: @b,
               manufacturer_digest: @c
             )
  end
end
