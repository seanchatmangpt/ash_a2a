defmodule AshA2A.Reactor.ExecuteCommand do
  @moduledoc """
  Reactor step adapter for the receipted AshA2A command boundary.

  Reactor coordinates the step; it does not gain independent authority or
  call `AshA2A.Dispatcher` directly. All command execution remains routed
  through `AshA2A.CommandBus`.
  """

  use Reactor.Step

  @impl true
  def run(arguments, context, options) do
    command = Map.fetch!(arguments, :command)
    message = Map.fetch!(arguments, :message)
    resource_or_domain = Map.fetch!(arguments, :resource_or_domain)

    bus_opts =
      options
      |> Keyword.get(:command_bus_opts, [])
      |> Keyword.put_new(:history, Map.get(context, :a2a_history, []))
      |> Keyword.put_new(:auth_identity, Map.get(context, :a2a_auth_identity))

    case AshA2A.CommandBus.run(command, message, resource_or_domain, bus_opts) do
      {:ok, receipt} -> {:ok, receipt}
      {:error, reason} -> {:error, reason}
    end
  end
end
