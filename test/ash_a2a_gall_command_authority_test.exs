defmodule AshA2A.Test.FailingActuationStore do
  @moduledoc false
  @behaviour AshA2A.ReceiptStore

  alias AshA2A.ReceiptStore.Memory

  def claim(command, opts), do: Memory.claim(command, opts)
  def commit(receipt, opts), do: Memory.commit(receipt, opts)
  def fetch(command_id, opts), do: Memory.fetch(command_id, opts)

  def claim_actuation(_actuation, _command, _opts), do: raise("actuation index unavailable")

  def commit_actuation(actuation, receipt, opts),
    do: Memory.commit_actuation(actuation, receipt, opts)

  def release_actuation(actuation, opts), do: Memory.release_actuation(actuation, opts)
end

defmodule AshA2AGallCommandAuthorityTest do
  use ExUnit.Case, async: false

  @moduletag :serial
  @moduletag :serial_shard
  import AshA2A.Test.MessageHelpers

  alias AshA2A.{
    Actuation,
    Authority,
    Command,
    CommandBus,
    Evidence,
    Identity,
    Receipt,
    SemanticProjection,
    SemanticSubject
  }

  alias AshA2A.Test.FailingActuationStore
  alias AshA2A.Test.Fixture.Item

  setup do
    name = Module.concat(__MODULE__, "Store#{System.unique_integer([:positive])}")
    start_supervised!({AshA2A.ReceiptStore.Memory, name: name})
    %{store_opts: [name: name]}
  end

  test "semantic projection carries correlation identity but not raw authority evidence" do
    principal = Identity.principal("gall-user")
    capability = "AshA2A.Test.Fixture.Item.create"
    secret = "raw-bearer-secret-must-not-leak"

    authority =
      Authority.new(principal, capability, token_id: "gall-grant", evidence: %{bearer: secret})

    {:ok, subject} =
      SemanticSubject.new(
        graph_digest: "sha256:" <> String.duplicate("1", 64),
        projection_digest: "sha256:" <> String.duplicate("2", 64),
        manufacturer_digest: "sha256:" <> String.duplicate("3", 64)
      )

    command =
      Command.new(capability,
        command_id: "gall-projection-command",
        agent_id: "gall-agent",
        principal_id: principal,
        authority: authority,
        semantic_subject: subject,
        metadata: %{work_order_digest: "sha256:" <> String.duplicate("4", 64)},
        input: %{label: "projection"}
      )

    receipt =
      Receipt.pending(command, Identity.execution("gall-execution"), :change,
        actuation: Actuation.identity(command),
        evidence_class: Evidence.LocalTest.new(%{suite: "gall-003"})
      )

    event = SemanticProjection.ocel_event(receipt)
    attrs = event["attributes"]

    assert attrs["semantic_graph_digest"] == subject.graph_digest
    assert attrs["projection_digest"] == subject.projection_digest
    assert attrs["manufacturer_digest"] == subject.manufacturer_digest
    assert is_binary(attrs["actuation_id"])
    assert is_binary(attrs["idempotency_key"])
    assert attrs["authority_grant_id"] == Identity.external(authority.token_id)
    assert is_binary(attrs["authority_evidence_digest"])
    assert attrs["evidence_class"] == "local_test"
    assert attrs["work_order_digest"] == command.metadata.work_order_digest
    refute inspect(event) =~ secret
  end

  test "enforced effect idempotency refuses before DO when actuation store is unavailable", %{
    store_opts: store_opts
  } do
    capability = "AshA2A.Test.Fixture.Item.create"
    principal = Identity.principal("gall-store-user-#{System.unique_integer([:positive])}")
    label = "must-not-exist-#{System.unique_integer([:positive])}"
    authority = Authority.new(principal, capability, token_id: "gall-store-grant")

    command =
      Command.new(capability,
        command_id: "gall-store-command-#{System.unique_integer([:positive])}",
        agent_id: "gall-store-agent",
        principal_id: principal,
        authority: authority,
        metadata: %{idempotency_key: "gall-effect-token"},
        input: %{label: label}
      )

    message = data_message(%{"label" => label})

    assert {:error, %{code: :actuation_store_unavailable, receipt: receipt}} =
             CommandBus.run(command, message, Item,
               store: FailingActuationStore,
               store_opts: store_opts,
               actuation_dedup: :strict
             )

    assert receipt.terminal_status == :refused

    assert {:ok, items} = Ash.read(Item, domain: AshA2A.Test.Fixture.ItemDomain)
    refute Enum.any?(items, &(&1.label == label))
  end
end
