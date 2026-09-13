defmodule AshA2A.Execution.FLAME do
  @moduledoc """
  Optional FLAME placement adapter for receipted AshA2A commands.

  FLAME chooses where the closure runs; it never gains independent capability,
  authority, or dispatch semantics. The remotely placed closure calls
  `AshA2A.CommandBus`, so the same admission/replay/receipt fence applies on
  every node. Placement itself is also represented by `AshA2A.RuntimeReceipt`.
  """

  alias AshA2A.{Command, RuntimeReceipt}

  @spec available?() :: boolean()
  def available?, do: Code.ensure_loaded?(FLAME) and function_exported?(FLAME, :call, 3)

  @spec run(term(), Command.t(), A2A.Message.t(), module(), keyword()) ::
          {:ok, %{receipt: AshA2A.Receipt.t(), placement: RuntimeReceipt.t()}}
          | {:error, term()}
  def run(pool, %Command{} = command, %A2A.Message{} = message, resource_or_domain, opts \\ []) do
    if available?() do
      flame_opts = Keyword.get(opts, :flame_opts, [])
      bus_opts = Keyword.get(opts, :command_bus_opts, [])

      result =
        try do
          apply(FLAME, :call, [pool, fn -> AshA2A.CommandBus.run(command, message, resource_or_domain, bus_opts) end, flame_opts])
        rescue
          exception -> {:error, {:exception, exception.__struct__, Exception.message(exception)}}
        catch
          kind, reason -> {:error, {kind, reason}}
        end

      placement =
        RuntimeReceipt.new(:flame, :call, command.command_id, result,
          metadata: %{pool: inspect(pool)}
        )

      case result do
        {:ok, %AshA2A.Receipt{} = receipt} ->
          {:ok, %{receipt: receipt, placement: placement}}

        {:error, reason} ->
          {:error, %{reason: reason, placement: placement}}

        other ->
          {:error, %{reason: {:unexpected_flame_result, other}, placement: placement}}
      end
    else
      {:error, {:unsupported, :flame}}
    end
  end
end
