defmodule AshA2A.ReceiptStore.Memory do
  @moduledoc "In-memory reference receipt store for local/runtime composition."
  use GenServer

  @behaviour AshA2A.ReceiptStore

  alias AshA2A.{Command, Identity, Receipt}

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, %{}, name: Keyword.get(opts, :name, __MODULE__))
  end

  @impl true
  def init(state), do: {:ok, state}

  @impl true
  def claim(%Command{} = command, opts \\ []) do
    GenServer.call(server(opts), {:claim, command})
  end

  @impl true
  def commit(%Receipt{} = receipt, opts \\ []) do
    GenServer.call(server(opts), {:commit, receipt})
  end

  @impl true
  def fetch(%Identity{kind: :command} = command_id, opts \\ []) do
    GenServer.call(server(opts), {:fetch, Identity.external(command_id)})
  end

  @impl true
  def handle_call({:claim, command}, _from, state) do
    key = Identity.external(command.command_id)

    case Map.get(state, key) do
      nil ->
        execution_id = Identity.execution(Ash.UUIDv7.generate())
        entry = %{fingerprint: command.fingerprint, execution_id: execution_id, receipt: nil}
        {:reply, {:execute, execution_id}, Map.put(state, key, entry)}

      %{fingerprint: fingerprint, receipt: %Receipt{} = receipt}
      when fingerprint == command.fingerprint ->
        {:reply, {:replay, Receipt.replay(receipt)}, state}

      %{fingerprint: fingerprint} when fingerprint == command.fingerprint ->
        {:reply, {:error, :in_flight}, state}

      _ ->
        {:reply, {:error, :command_conflict}, state}
    end
  end

  def handle_call({:commit, %Receipt{} = receipt}, _from, state) do
    key = Identity.external(receipt.command_id)

    case Map.get(state, key) do
      %{fingerprint: fingerprint} = entry when fingerprint == receipt.fingerprint ->
        {:reply, :ok, Map.put(state, key, %{entry | receipt: receipt})}

      _ ->
        {:reply, {:error, :unclaimed_command}, state}
    end
  end

  def handle_call({:fetch, key}, _from, state) do
    case Map.get(state, key) do
      %{receipt: %Receipt{} = receipt} -> {:reply, {:ok, receipt}, state}
      _ -> {:reply, :error, state}
    end
  end

  defp server(opts), do: Keyword.get(opts, :name, __MODULE__)
end
