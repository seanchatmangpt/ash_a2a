defmodule AshA2A.Test.CrashingReceiptStoreFixture do
  @moduledoc """
  A real `AshA2A.ReceiptStore` implementation used only to exercise
  `AshA2A.CommandBus.run/4`'s fail-closed handling of a receipt store whose
  backing process becomes transiently unavailable mid-flight.

  `claim/2` delegates to the real `AshA2A.ReceiptStore.Memory`. `commit/2`
  first genuinely stops the underlying `Memory` GenServer registered under
  `opts[:name]` -- a real state change against a real process, not a
  stubbed interaction -- and only then makes the real `Memory.commit/2`
  call against the now-dead process, producing a real `:noproc` exit for
  `AshA2A.CommandBus.run/4` to catch. This is not a mock: it never asserts
  on how it was called, and every crash it produces is a genuine one
  against a genuinely-stopped real collaborator.
  """
  @behaviour AshA2A.ReceiptStore

  alias AshA2A.ReceiptStore.Memory

  @impl true
  def claim(command, opts), do: Memory.claim(command, opts)

  @impl true
  def commit(receipt, opts) do
    opts
    |> Keyword.fetch!(:name)
    |> GenServer.whereis()
    |> case do
      pid when is_pid(pid) -> GenServer.stop(pid, :shutdown)
      nil -> :ok
    end

    Memory.commit(receipt, opts)
  end

  @impl true
  def fetch(id, opts), do: Memory.fetch(id, opts)
end
