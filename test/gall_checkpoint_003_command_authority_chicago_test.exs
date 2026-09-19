defmodule AshA2A.Gall.CommandAuthorityChicagoTest do
  use ExUnit.Case, async: false

  import AshA2A.Test.MessageHelpers

  alias AshA2A.{Authority, Command, CommandBus, Identity, SemanticSubject}
  alias AshA2A.Gall.CommandReceipt
  alias AshA2A.ReceiptStore

  defmodule A do
    use Ash.Resource,
      domain: Domain,
      data_layer: Ash.DataLayer.Ets,
      extensions: [AshA2A]

    attributes do
      uuid_primary_key(:id)
      attribute(:label, :string, public?: true)
    end

    actions do
      create :create do
        accept([:label])
      end
    end
  end

  defmodule B do
    use Ash.Resource,
      domain: Domain,
      data_layer: Ash.DataLayer.Ets,
      extensions: [AshA2A]

    attributes do
      uuid_primary_key(:id)
      attribute(:label, :string, public?: true)
    end

    actions do
      create :create do
        accept([:label])
      end
    end
  end

  defmodule Domain do
    use Ash.Domain, extensions: [AshA2A]

    resources do
      resource(A)
      resource(B)
    end
  end

  setup do
    outbox_dir =
      Path.join(System.tmp_dir!(), "gall-003-#{System.unique_integer([:positive])}")

    Application.put_env(:ash_a2a, :receipt_outbox_dir, outbox_dir)
    name = Module.concat(__MODULE__, "Store#{System.unique_integer([:positive])}")
    start_supervised!({ReceiptStore.Memory, name: name})

    on_exit(fn ->
      Application.delete_env(:ash_a2a, :receipt_outbox_dir)
      File.rm_rf!(outbox_dir)
    end)

    {:ok, store_opts: [name: name]}
  end

  defp semantic_subject do
    {:ok, subject} =
      SemanticSubject.new(
        graph_digest: "sha256:" <> String.duplicate("a", 64),
        projection_digest: "sha256:" <> String.duplicate("b", 64),
        manufacturer_digest: "sha256:" <> String.duplicate("c", 64)
      )

    subject
  end

  defp command(capability_id, id) do
    principal = Identity.principal("gall-003-principal")

    Command.new(capability_id,
      command_id: id,
      agent_id: "gall-003-agent",
      principal_id: principal,
      authority: Authority.new(principal, capability_id, token_id: "grant-#{id}"),
      semantic_subject: semantic_subject(),
      input: %{label: id}
    )
  end

  test "exact non-first duplicate capability survives CommandBus and emits bound observer handoff",
       %{store_opts: store_opts} do
    capability = "#{__MODULE__}.B.create"
    cmd = command(capability, "gall-003-b")

    assert {:ok, receipt} =
             CommandBus.run(cmd, data_message(cmd.input), Domain,
               store: ReceiptStore.Memory,
               store_opts: store_opts
             )

    assert receipt.capability_id == capability
    assert receipt.consequence == :change
    assert receipt.terminal_status == :executed

    assert {:ok, handoff} = CommandReceipt.from_receipt(receipt)
    assert handoff.capability_id == capability
    assert handoff.manufacturer_subject_digest == semantic_subject().manufacturer_digest
    assert String.starts_with?(handoff.handoff_digest, "sha256:")

    assert Ash.read!(A) == []
    assert length(Ash.read!(B)) == 1
  end

  test "ambiguous display selector is refused before consequence", %{store_opts: store_opts} do
    cmd = command("create", "gall-003-ambiguous")

    assert {:error, %{code: :ambiguous_skill}} =
             CommandBus.run(cmd, data_message(cmd.input), Domain,
               store: ReceiptStore.Memory,
               store_opts: store_opts
             )

    assert Ash.read!(A) == []
    assert Ash.read!(B) == []
  end

  test "tampering a bound semantic subject prevents observer handoff", %{store_opts: store_opts} do
    capability = "#{__MODULE__}.A.create"
    cmd = command(capability, "gall-003-tamper")

    assert {:ok, receipt} =
             CommandBus.run(cmd, data_message(cmd.input), Domain,
               store: ReceiptStore.Memory,
               store_opts: store_opts
             )

    tampered = %{
      receipt
      | semantic_subject: %{
          receipt.semantic_subject
          | manufacturer_digest: "sha256:" <> String.duplicate("d", 64)
        }
    }

    assert {:error, %{code: :receipt_binding_field_mismatch}} =
             CommandReceipt.from_receipt(tampered)
  end
end
