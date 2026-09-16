defmodule AshA2A.Test.Fixture.ReceiptCrashWindow.ExternalDo do
  @moduledoc """
  Real consequence-bearing fixture for the receipt crash-window falsifier.

  The action performs one real HTTP consequence and then kills the process
  executing it with the untrappable `:kill` exit reason. That places the
  failure strictly after the remote receiver has acknowledged the consequence
  and before `AshA2A.CommandBus` can finalize its pre-DO pending receipt.
  """

  use Ash.Resource,
    domain: AshA2A.Test.Fixture.ReceiptCrashWindow.Domain,
    data_layer: Ash.DataLayer.Ets,
    extensions: [AshA2A]

  attributes do
    uuid_primary_key(:id)
  end

  actions do
    action :perform_then_crash, :string do
      argument(:url, :string, allow_nil?: false)
      argument(:operation_id, :string, allow_nil?: false)

      run(fn input, _context ->
        url = Map.fetch!(input.arguments, :url)
        operation_id = Map.fetch!(input.arguments, :operation_id)

        case Req.post(url <> "/do",
               json: %{"operation_id" => operation_id},
               receive_timeout: 2_000
             ) do
          {:ok, %Req.Response{status: status}} when status in 200..299 ->
            Process.exit(self(), :kill)

          other ->
            {:error, {:external_receiver_failed, other}}
        end
      end)
    end
  end

  a2a do
    skill(:perform_then_crash, :perform_then_crash, consequence: :external_do)
  end
end

defmodule AshA2A.Test.Fixture.ReceiptCrashWindow.Domain do
  @moduledoc false

  use Ash.Domain, extensions: [AshA2A], validate_config_inclusion?: false

  resources do
    resource(AshA2A.Test.Fixture.ReceiptCrashWindow.ExternalDo)
  end
end

defmodule AshA2A.Test.Fixture.ReceiptCrashWindow.Runner do
  @moduledoc """
  Separate-BEAM runner used by the crash-window Chicago test.

  `run!/3` is intentionally expected never to return: the real external DO
  kills the process after the receiver acknowledges it. The filesystem receipt
  anchor is therefore the only evidence that crosses into the next BEAM VM.
  """

  alias AshA2A.{Authority, Command, CommandBus, Identity}
  alias AshA2A.Test.Fixture.ReceiptCrashWindow.ExternalDo
  alias AshA2A.Test.MessageHelpers

  @store __MODULE__.ChildStore

  def capability_id, do: "#{inspect(ExternalDo)}.perform_then_crash"

  def command(url, command_id) do
    principal = Identity.principal("receipt-crash-window-subject")

    authority =
      Authority.new(principal, capability_id(),
        token_id: "receipt-crash-window-authority"
      )

    Command.new(capability_id(),
      command_id: command_id,
      agent_id: "receipt-crash-window-agent",
      principal_id: principal,
      authority: authority,
      input: %{"url" => url, "operation_id" => command_id}
    )
  end

  def message(url, command_id) do
    MessageHelpers.data_message(%{"url" => url, "operation_id" => command_id})
  end

  def run!(url, outbox_dir, command_id) do
    Application.put_env(:ash_a2a, :receipt_outbox_dir, outbox_dir)
    {:ok, _pid} = GenServer.start(AshA2A.ReceiptStore.Memory, %{}, name: @store)

    CommandBus.run(
      command(url, command_id),
      message(url, command_id),
      ExternalDo,
      store_opts: [name: @store]
    )

    raise "crash-window runner returned after consequence; expected :kill"
  end
end
