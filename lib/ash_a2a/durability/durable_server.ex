defmodule AshA2A.Durability.DurableServer do
  @moduledoc """
  Optional adapter for Phoenix `DurableServer` task runtimes.

  The A2A TaskID is used as the stable DurableServer key, but DurableServer's
  PID/storage lock/node placement remain provider state. Mutating lifecycle
  operations return `AshA2A.RuntimeReceipt`; none of them imply Ash command
  execution or task completion.

  The provider defaults to `DurableServer.Supervisor`. Hosts may configure
  `:ash_a2a, :durable_server_provider` with an API-compatible module. This is
  a provider substitution seam only: it does not change TaskID semantics,
  manufacture durability, or grant command authority.
  """

  alias AshA2A.{Identity, RuntimeReceipt}

  @default_provider DurableServer.Supervisor

  @spec provider() :: module()
  def provider do
    Application.get_env(:ash_a2a, :durable_server_provider, @default_provider)
  end

  @spec available?() :: boolean()
  def available?, do: Code.ensure_loaded?(provider())

  @spec key(Identity.t()) :: String.t()
  def key(%Identity{kind: :task} = task_id), do: Identity.external(task_id)

  @spec ensure_task(term(), module(), Identity.t(), map(), keyword()) ::
          {:ok, RuntimeReceipt.t()} | {:error, term()}
  def ensure_task(supervisor, server_module, %Identity{kind: :task} = task_id, initial_state, opts \\ [])
      when is_atom(server_module) and is_map(initial_state) do
    spec = {server_module, key: key(task_id), initial_state: initial_state}
    actuate(:ensure_started_child, task_id, [supervisor, spec, opts])
  end

  @spec lookup(term(), Identity.t()) :: term()
  def lookup(supervisor, %Identity{kind: :task} = task_id) do
    invoke(:lookup, [supervisor, key(task_id)])
  end

  @spec rehome_task(term(), module(), Identity.t(), map(), keyword()) ::
          {:ok, RuntimeReceipt.t()} | {:error, term()}
  def rehome_task(supervisor, server_module, %Identity{kind: :task} = task_id, initial_state, opts \\ [])
      when is_atom(server_module) and is_map(initial_state) do
    spec = {server_module, key: key(task_id), initial_state: initial_state}
    actuate(:rehome_child, task_id, [supervisor, spec, opts])
  end

  @spec cordon_task(term(), Identity.t(), keyword()) :: {:ok, RuntimeReceipt.t()} | {:error, term()}
  def cordon_task(supervisor, %Identity{kind: :task} = task_id, opts \\ []) do
    actuate(:terminate_and_cordon_child, task_id, [supervisor, key(task_id), opts])
  end

  @spec uncordon_task(term(), Identity.t()) :: {:ok, RuntimeReceipt.t()} | {:error, term()}
  def uncordon_task(supervisor, %Identity{kind: :task} = task_id) do
    actuate(:uncordon_child, task_id, [supervisor, key(task_id)])
  end

  @spec delete_task(term(), Identity.t(), timeout()) :: {:ok, RuntimeReceipt.t()} | {:error, term()}
  def delete_task(supervisor, %Identity{kind: :task} = task_id, timeout \\ 5_000) do
    actuate(:terminate_and_delete_child, task_id, [supervisor, key(task_id), timeout], irreversible?: true)
  end

  defp actuate(function, subject, args, metadata \\ []) do
    case invoke(function, args) do
      {:error, _} = error -> error
      result -> {:ok, RuntimeReceipt.new(:durable_server, function, subject, result, metadata: Map.new(metadata))}
    end
  end

  defp invoke(function, args) do
    provider = provider()

    if Code.ensure_loaded?(provider) and function_exported?(provider, function, length(args)) do
      apply(provider, function, args)
    else
      {:error, {:unsupported, :durable_server, function, length(args)}}
    end
  end
end
