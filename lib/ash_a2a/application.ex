defmodule AshA2A.Application do
  @moduledoc """
  Starts the A2A agent supervisor and the default replay receipt store.

  Host applications may replace `:receipt_store` with another
  `AshA2A.ReceiptStore` implementation; non-default stores own their own
  supervision lifecycle.
  """

  use Application

  @impl true
  def start(_type, _args) do
    agents = Application.get_env(:ash_a2a, :agents, [])

    children =
      receipt_store_children() ++
        [
          {A2A.AgentSupervisor, agents: agents}
        ]

    Supervisor.start_link(children, strategy: :one_for_one, name: AshA2A.Supervisor)
  end

  defp receipt_store_children do
    case Application.get_env(:ash_a2a, :receipt_store, AshA2A.ReceiptStore.Memory) do
      AshA2A.ReceiptStore.Memory -> [{AshA2A.ReceiptStore.Memory, []}]
      _custom_store -> []
    end
  end
end
