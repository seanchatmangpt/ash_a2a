defmodule AshA2A.Test.HordePocWorker do
  @moduledoc """
  Minimal real `GenServer` used by
  `AshA2A.LibclusterHordePocTest` to prove real cross-node process
  discovery via `Horde.Registry` -- not a same-node stand-in.

  Replies to `:ping` with `{:pong, node()}` so the caller can assert the
  reply names the process's own real, live `node()` -- whichever node
  `Horde.DynamicSupervisor` (not this test) actually chose to place it on.
  """
  use GenServer

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    name = Keyword.fetch!(opts, :name)
    GenServer.start_link(__MODULE__, :ok, name: name)
  end

  @impl true
  def init(:ok), do: {:ok, %{}}

  @impl true
  def handle_call(:ping, _from, state), do: {:reply, {:pong, node()}, state}
end
