# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
#
# SPDX-License-Identifier: MIT

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

  ## Result typing (fail closed)

  A mutating operation is receipted only when the provider returns its
  documented success shape: `{:ok, {pid, meta}}` (with a real pid) for
  `ensure_started_child`/`rehome_child`, `:ok` for `terminate_and_cordon_child`,
  `terminate_and_delete_child` and `uncordon_child`. Any other return is
  `{:error, {:unexpected_provider_result, function, result}}`. A provider
  raise, exit or throw never crashes the caller: it becomes
  `{:error, {:durable_server_raised | :durable_server_exit |
  :durable_server_throw, function, detail}}`. `lookup/2` passes the
  provider's read result through unchanged but is guarded the same way.
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
  def ensure_task(
        supervisor,
        server_module,
        %Identity{kind: :task} = task_id,
        initial_state,
        opts \\ []
      )
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
  def rehome_task(
        supervisor,
        server_module,
        %Identity{kind: :task} = task_id,
        initial_state,
        opts \\ []
      )
      when is_atom(server_module) and is_map(initial_state) do
    spec = {server_module, key: key(task_id), initial_state: initial_state}
    actuate(:rehome_child, task_id, [supervisor, spec, opts])
  end

  @spec cordon_task(term(), Identity.t(), keyword()) ::
          {:ok, RuntimeReceipt.t()} | {:error, term()}
  def cordon_task(supervisor, %Identity{kind: :task} = task_id, opts \\ []) do
    actuate(:terminate_and_cordon_child, task_id, [supervisor, key(task_id), opts])
  end

  @spec uncordon_task(term(), Identity.t()) :: {:ok, RuntimeReceipt.t()} | {:error, term()}
  def uncordon_task(supervisor, %Identity{kind: :task} = task_id) do
    actuate(:uncordon_child, task_id, [supervisor, key(task_id)])
  end

  @spec delete_task(term(), Identity.t(), timeout()) ::
          {:ok, RuntimeReceipt.t()} | {:error, term()}
  def delete_task(supervisor, %Identity{kind: :task} = task_id, timeout \\ 5_000) do
    actuate(:terminate_and_delete_child, task_id, [supervisor, key(task_id), timeout],
      irreversible?: true
    )
  end

  defp actuate(function, subject, args, metadata \\ []) do
    case invoke(function, args) do
      {:error, _} = error ->
        error

      result ->
        if success?(function, result) do
          {:ok,
           RuntimeReceipt.new(:durable_server, function, subject, result,
             metadata: Map.new(metadata)
           )}
        else
          {:error, {:unexpected_provider_result, function, result}}
        end
    end
  end

  # Only the provider's documented success shapes are receipted. Anything else
  # (`:error`, `:ignore`, `nil`, `{:error, a, b}`, a bare pid, ...) is typed
  # as `{:error, {:unexpected_provider_result, function, other}}` rather than
  # manufacturing a RuntimeReceipt for an operation that did not succeed.
  # `{:ok, {pid, meta}}` is DurableServer.Supervisor's documented success
  # shape for ensure/rehome (deps/durable_server supervisor.ex docs). A bare
  # `{:ok, nil}` / `{:ok, :anything}` names no running process, so it is not
  # evidence the child was started and must not be receipted.
  defp success?(function, {:ok, {pid, _meta}})
       when function in [:ensure_started_child, :rehome_child] and is_pid(pid),
       do: true

  defp success?(function, :ok)
       when function in [
              :terminate_and_cordon_child,
              :terminate_and_delete_child,
              :uncordon_child
            ],
       do: true

  defp success?(_function, _result), do: false

  defp invoke(function, args) do
    provider = provider()

    if Code.ensure_loaded?(provider) and function_exported?(provider, function, length(args)) do
      try do
        apply(provider, function, args)
      rescue
        exception -> {:error, {:durable_server_raised, function, Exception.message(exception)}}
      catch
        :exit, reason -> {:error, {:durable_server_exit, function, reason}}
        :throw, value -> {:error, {:durable_server_throw, function, value}}
      end
    else
      {:error, {:unsupported, :durable_server, function, length(args)}}
    end
  end
end
