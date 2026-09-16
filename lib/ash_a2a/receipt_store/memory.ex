defmodule AshA2A.ReceiptStore.Memory do
  @moduledoc """
  In-memory reference receipt store for local/runtime composition.

  Also implements the optional RFC-SA2A-001 S55 actuation-claim callbacks
  (`claim_actuation/3`, `commit_actuation/3`, `release_actuation/2`). The
  actuation index lives in the same `GenServer` state under `{:actuation, id}`
  keys, so it inherits the same free serialization the command claim already
  gets from the process mailbox -- two concurrent claimants on one effect are
  ordered by the mailbox, not by a racy read-then-write.
  """
  use GenServer

  @behaviour AshA2A.ReceiptStore

  alias AshA2A.{Actuation, Command, Identity, Receipt}

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
  def claim_actuation(%Actuation{} = actuation, %Command{} = command, opts \\ []) do
    GenServer.call(server(opts), {:claim_actuation, actuation, command.command_id})
  end

  @impl true
  def commit_actuation(%Actuation{} = actuation, %Receipt{} = receipt, opts \\ []) do
    GenServer.call(server(opts), {:commit_actuation, actuation, receipt})
  end

  @impl true
  def release_actuation(%Actuation{} = actuation, opts \\ []) do
    GenServer.call(server(opts), {:release_actuation, actuation})
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

  def handle_call({:claim_actuation, %Actuation{} = actuation, command_id}, _from, state) do
    key = actuation_key(actuation)
    idempotency = Identity.external(actuation.idempotency_key)

    case Map.get(state, key) do
      nil ->
        entry = %{
          idempotency_key: idempotency,
          command_id: Identity.external(command_id),
          receipt: nil
        }

        {:reply, :proceed, Map.put(state, key, entry)}

      %{idempotency_key: ^idempotency, receipt: %Receipt{} = receipt} ->
        {:reply, {:duplicate, Receipt.replay(receipt)}, state}

      %{idempotency_key: ^idempotency} ->
        {:reply, {:error, :actuation_in_flight}, state}

      _ ->
        {:reply, {:error, :actuation_conflict}, state}
    end
  end

  def handle_call(
        {:commit_actuation, %Actuation{} = actuation, %Receipt{} = receipt},
        _from,
        state
      ) do
    key = actuation_key(actuation)

    case Map.get(state, key) do
      nil -> {:reply, {:error, :unclaimed_actuation}, state}
      entry -> {:reply, :ok, Map.put(state, key, %{entry | receipt: receipt})}
    end
  end

  def handle_call({:release_actuation, %Actuation{} = actuation}, _from, state) do
    key = actuation_key(actuation)

    case Map.get(state, key) do
      # Only an unexecuted claim is releasable. Dropping a claim that already
      # carries a receipt would re-open a completed effect for re-actuation,
      # which is the exact thing S55 exists to prevent.
      %{receipt: nil} -> {:reply, :ok, Map.delete(state, key)}
      _ -> {:reply, :ok, state}
    end
  end

  defp actuation_key(%Actuation{actuation_id: actuation_id}),
    do: {:actuation, Identity.external(actuation_id)}

  defp server(opts), do: Keyword.get(opts, :name, __MODULE__)
end
