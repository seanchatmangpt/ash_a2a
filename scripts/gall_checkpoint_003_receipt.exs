defmodule AshA2A.Gall.Receipt003Court do
  @moduledoc false

  import AshA2A.Test.MessageHelpers

  alias AshA2A.{Authority, Command, CommandBus, Identity, SemanticSubject}
  alias AshA2A.Gall.CommandReceipt
  alias AshA2A.ReceiptStore

  defmodule Resource do
    use Ash.Resource,
      domain: Domain,
      data_layer: Ash.DataLayer.Ets,
      extensions: [AshA2A]

    attributes do
      uuid_primary_key(:id)
      attribute(:label, :string, public?: true)
    end

    actions do
      read(:read)

      create :create do
        accept([:label])
      end
    end
  end

  defmodule Domain do
    use Ash.Domain, extensions: [AshA2A]

    resources do
      resource(Resource)
    end
  end

  def run(gall002_path, out_dir) do
    source = gall002_path |> File.read!() |> Jason.decode!()
    File.mkdir_p!(out_dir)

    data_dir = Path.join(out_dir, "ekv")
    outbox_dir = Path.join(out_dir, "outbox")
    File.mkdir_p!(data_dir)
    Application.put_env(:ash_a2a, :receipt_outbox_dir, outbox_dir)

    try do
      ekv_name = String.to_atom("gall003_ekv_#{System.unique_integer([:positive, :monotonic])}")
      {:ok, _pid} = EKV.start_link(name: ekv_name, data_dir: data_dir, cluster_size: 1)

        {:ok, subject} =
        SemanticSubject.new(
          graph_digest: source["graph_digest"],
          projection_digest: source["projection_digest"],
          manufacturer_digest: source["manufacturer_digest"]
        )
  
      capability = AshA2A.CapabilityIndex.Compiler.capability_id(Resource, :create)
      principal = Identity.principal("gall-003-court")
  
      command =
        Command.new(capability,
          command_id: "gall-003-exact-head",
          agent_id: "gall-003-court",
          principal_id: principal,
          authority: Authority.new(principal, capability, token_id: "gall-003-grant"),
          semantic_subject: subject,
          metadata: %{
            work_order_digest: source["work_order_digest"],
            idempotency_key: "gall-003-exact-effect"
          },
          input: %{label: "gall-003-exact-head"}
        )
  
      pre_state = Ash.read!(Resource, domain: Domain)
      pre_state_digest = CommandReceipt.digest(pre_state)
  
      {:ok, receipt} =
        CommandBus.run(command, data_message(command.input), Domain,
          store: ReceiptStore.Ekv,
          store_opts: [name: ekv_name],
          actuation_dedup: :strict
        )
  
      true = receipt.standing == :durable
      true = receipt.terminal_status == :executed
  
      {:ok, handoff} = CommandReceipt.from_receipt(receipt)
      handoff = handoff |> Map.from_struct() |> jsonable()
  
      handoff =
        Map.merge(handoff, %{
          "producer_sha" => git_head!(),
          "work_order_digest" => source["work_order_digest"],
          "pre_state_digest" => pre_state_digest
        })
  
      command_path = Path.join(out_dir, "gall-003-receipt.json")
      File.write!(command_path, Jason.encode!(handoff, pretty: true) <> "\n")
  
      post_state = Ash.read!(Resource, domain: Domain)
  
      post_payload = %{
        "capability_id" => handoff["capability_id"],
        "command_fingerprint" => handoff["command_fingerprint"],
        "semantic_subject_digest" => handoff["semantic_subject_digest"],
        "consequence_identity" => "ash-ets:gall-003-exact-head",
        "post_state_digest" => CommandReceipt.digest(post_state),
        "occurrence_count" => length(post_state) - length(pre_state),
        "source_type" => "ash_read",
        "source_locator" => "AshA2A.Gall.Receipt003Court.Resource"
      }
  
      File.write!(
        Path.join(out_dir, "post-state.json"),
        Jason.encode!(post_payload, pretty: true) <> "\n"
      )
  
      events = %{
        "events" => [
          event("receipt_prepared", 10, handoff),
          event("do_attempted", 20, handoff),
          event("post_state_observed", 30, handoff)
        ]
      }
  
      File.write!(
        Path.join(out_dir, "events.ocel.json"),
        Jason.encode!(events, pretty: true) <> "\n"
      )
  
      handoff
    after
      Application.delete_env(:ash_a2a, :receipt_outbox_dir)
    end

  defp event(activity, sequence, handoff) do
    %{
      "eventType" => activity,
      "attributes" => [
        %{"name" => "sequence", "value" => sequence},
        %{"name" => "command_id", "value" => handoff["command_id"]},
        %{"name" => "capability_id", "value" => handoff["capability_id"]}
      ],
      "relationships" => [
        %{"qualifier" => "command", "objectId" => handoff["command_id"]}
      ]
    }
  end

  defp jsonable(%_{} = value), do: value |> Map.from_struct() |> jsonable()

  defp jsonable(value) when is_map(value) do
    Map.new(value, fn {key, item} -> {to_string(key), jsonable(item)} end)
  end

  defp jsonable(value) when is_list(value), do: Enum.map(value, &jsonable/1)
  defp jsonable(value) when is_atom(value), do: Atom.to_string(value)
  defp jsonable(value), do: value

  defp git_head! do
    {sha, 0} = System.cmd("git", ["rev-parse", "HEAD"], stderr_to_stdout: true)
    String.trim(sha)
  end
end

case System.argv() do
  [gall002_path, out_dir] ->
    payload = AshA2A.Gall.Receipt003Court.run(gall002_path, out_dir)
    IO.puts(Jason.encode!(payload))

  _ ->
    IO.puts(:stderr, "usage: MIX_ENV=test mix run scripts/gall_checkpoint_003_receipt.exs -- GALL002.json OUT_DIR")
    System.halt(2)
end
