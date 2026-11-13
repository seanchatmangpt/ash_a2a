# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
#
# SPDX-License-Identifier: MIT

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

  @spec run(term(), Command.t(), AshA2A.Protocol.Message.t(), module(), keyword()) ::
          {:ok, %{receipt: AshA2A.Receipt.t(), placement: RuntimeReceipt.t()}}
          | {:error, term()}
  def run(
        pool,
        %Command{} = command,
        %AshA2A.Protocol.Message{} = message,
        resource_or_domain,
        opts \\ []
      ) do
    if available?() do
      flame_opts = Keyword.get(opts, :flame_opts, [])
      bus_opts = Keyword.get(opts, :command_bus_opts, [])

      result =
        guarded(fn ->
          apply(FLAME, :call, [
            pool,
            fn -> AshA2A.CommandBus.run(command, message, resource_or_domain, bus_opts) end,
            flame_opts
          ])
        end)

      placement =
        RuntimeReceipt.new(:flame, :call, command.command_id, result,
          metadata: %{pool: inspect(pool)}
        )

      classify(result, placement)
    else
      {:error, {:unsupported, :flame}}
    end
  end

  @doc false
  # Runs `fun`, converting raise/throw/exit into typed error tuples (exits
  # included: `FLAME.call/3` exits on pool/node failure).
  @spec guarded((-> term())) :: term()
  def guarded(fun) when is_function(fun, 0) do
    fun.()
  rescue
    exception -> {:error, {:exception, exception.__struct__, Exception.message(exception)}}
  catch
    kind, reason -> {:error, {kind, reason}}
  end

  @doc false
  # Maps a guarded result + placement receipt onto the public return shape.
  @spec classify(term(), RuntimeReceipt.t()) ::
          {:ok, %{receipt: AshA2A.Receipt.t(), placement: RuntimeReceipt.t()}}
          | {:error, %{reason: term(), placement: RuntimeReceipt.t()}}
  def classify({:ok, %AshA2A.Receipt{} = receipt}, placement),
    do: {:ok, %{receipt: receipt, placement: placement}}

  def classify({:error, reason}, placement), do: {:error, %{reason: reason, placement: placement}}

  def classify(other, placement),
    do: {:error, %{reason: {:unexpected_flame_result, other}, placement: placement}}
end
