defmodule AshA2A.Chicago.Fixtures.RealCollaborators do
  @moduledoc """
  Adversarial substitutes for `AshA2A.Chicago.Courts.RealCollaborators`
  (RFC-SA2A-002 §34, gate 3).

  Each module here is a *configuration-level substitute* for a load-bearing
  collaborator -- exactly what gate 3 must detect. They are deliberately real,
  runnable implementations of the behaviour they impersonate (so the SUT
  accepts them structurally) whose semantics are wrong in the one way the
  court attacks. None of them is ever the default configuration.

    * `LossyDurableStore` -- implements `AshA2A.ReceiptStore` and *declares*
      `durable?/0 -> true`, but keeps every write in process memory: a restart
      loses them. `AshA2A.CommandBus` would stamp `standing: :durable` on its
      receipts from the declaration alone.
    * `AlwaysGrantBroker` -- implements `AshA2A.Authority.Broker` and answers
      `granted?/3 -> true` for everyone: a fake broker response (§10), so
      `:broker` policy with this broker is not a real authority boundary.
    * `StubGraphLawPort` -- implements `AshA2A.Semantic.GraphLaw` and claims
      the real engine's version string, but computes answers in Elixir
      without executing the GraphLaw wasm.
  """

  defmodule LossyDurableStore do
    @moduledoc "Declares durability it does not have: writes live only in process memory."
    use GenServer

    @behaviour AshA2A.ReceiptStore

    alias AshA2A.{Command, Identity, Receipt}

    @doc "The false declaration under attack."
    @spec durable?() :: boolean()
    def durable?, do: true

    def start_link(opts \\ []) do
      GenServer.start_link(__MODULE__, %{}, name: Keyword.get(opts, :name, __MODULE__))
    end

    @impl GenServer
    def init(state), do: {:ok, state}

    @impl AshA2A.ReceiptStore
    def claim(%Command{} = command, opts \\ []),
      do: GenServer.call(server(opts), {:claim, command})

    @impl AshA2A.ReceiptStore
    def commit(%Receipt{} = receipt, opts \\ []),
      do: GenServer.call(server(opts), {:commit, receipt})

    @impl AshA2A.ReceiptStore
    def fetch(%Identity{kind: :command} = command_id, opts \\ []),
      do: GenServer.call(server(opts), {:fetch, Identity.external(command_id)})

    @impl GenServer
    def handle_call({:claim, command}, _from, state) do
      key = Identity.external(command.command_id)

      case Map.get(state, key) do
        nil ->
          execution_id = Identity.execution(Ash.UUIDv7.generate())
          entry = %{fingerprint: command.fingerprint, receipt: nil}
          {:reply, {:execute, execution_id}, Map.put(state, key, entry)}

        %{fingerprint: fp, receipt: %Receipt{} = receipt} when fp == command.fingerprint ->
          {:reply, {:replay, Receipt.replay(receipt)}, state}

        %{fingerprint: fp} when fp == command.fingerprint ->
          {:reply, {:error, :in_flight}, state}

        _ ->
          {:reply, {:error, :command_conflict}, state}
      end
    end

    def handle_call({:commit, %Receipt{} = receipt}, _from, state) do
      key = Identity.external(receipt.command_id)

      case Map.get(state, key) do
        %{fingerprint: fp} = entry when fp == receipt.fingerprint ->
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

  defmodule AlwaysGrantBroker do
    @moduledoc "A fake broker response: every principal holds every capability."
    @behaviour AshA2A.Authority.Broker

    alias AshA2A.{Authority, Identity}

    @impl true
    def issue(%Identity{kind: :principal} = subject, capability_id, opts \\ []),
      do: {:ok, Authority.new(subject, capability_id, opts)}

    @impl true
    def revoke(%Authority{}, _opts \\ []), do: :ok

    @impl true
    def verify(%Authority{} = authority, _opts \\ []), do: {:ok, authority}

    @impl true
    def granted?(%Identity{kind: :principal}, capability_id, _opts \\ [])
        when is_binary(capability_id),
        do: true
  end

  defmodule StubGraphLawPort do
    @moduledoc "Answers like the GraphLaw port without executing the GraphLaw wasm."
    @behaviour AshA2A.Semantic.GraphLaw

    @impl true
    def version, do: {:ok, "praxis-graphlaw v26.7.5"}

    @impl true
    def graph_hash(ttl) when is_binary(ttl),
      do: {:ok, :crypto.hash(:sha256, ttl) |> Base.encode16(case: :lower)}

    @impl true
    def validate(ttl, _shapes) when is_binary(ttl) do
      {:ok, hash} = graph_hash(ttl)
      {:ok, %{"graph_hash" => hash, "dialects" => [], "hooks" => [], "replay" => %{}}}
    end
  end
end
