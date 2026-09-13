defmodule AshA2A.Topology.Presence do
  @moduledoc """
  Adapter for a host application's `Phoenix.Presence` module.

  Presence is strictly ephemeral topology. Reads return the host Presence
  projection; track/update/untrack are provider mutations and therefore return
  `AshA2A.RuntimeReceipt` evidence. Presence never owns Ash domain state,
  A2A TaskID lifecycle, authority, or command execution standing.
  """

  alias AshA2A.{Identity, RuntimeReceipt}

  @spec available?(module()) :: boolean()
  def available?(presence_module) when is_atom(presence_module) do
    Code.ensure_loaded?(presence_module) and
      function_exported?(presence_module, :track, 4) and
      function_exported?(presence_module, :list, 1)
  end

  @spec key(Identity.t() | term()) :: String.t()
  def key(%Identity{} = identity), do: Identity.external(identity)
  def key(value) when is_binary(value), do: value
  def key(value), do: to_string(value)

  @spec list(module(), String.t()) :: term()
  def list(presence_module, topic), do: invoke(presence_module, :list, [topic])

  @spec track(module(), pid(), String.t(), Identity.t() | term(), map()) ::
          {:ok, RuntimeReceipt.t()} | {:error, term()}
  def track(presence_module, pid, topic, identity, metadata \\ %{})
      when is_pid(pid) and is_binary(topic) and is_map(metadata) do
    actuate(presence_module, :track, identity, [pid, topic, key(identity), metadata])
  end

  @spec update(module(), pid(), String.t(), Identity.t() | term(), map() | function()) ::
          {:ok, RuntimeReceipt.t()} | {:error, term()}
  def update(presence_module, pid, topic, identity, metadata)
      when is_pid(pid) and is_binary(topic) do
    actuate(presence_module, :update, identity, [pid, topic, key(identity), metadata])
  end

  @spec untrack(module(), pid(), String.t(), Identity.t() | term()) ::
          {:ok, RuntimeReceipt.t()} | {:error, term()}
  def untrack(presence_module, pid, topic, identity)
      when is_pid(pid) and is_binary(topic) do
    actuate(presence_module, :untrack, identity, [pid, topic, key(identity)])
  end

  defp actuate(module, function, subject, args) do
    case invoke(module, function, args) do
      {:error, _} = error -> error
      result -> {:ok, RuntimeReceipt.new(:phoenix_presence, function, subject, result)}
    end
  end

  defp invoke(module, function, args) do
    if Code.ensure_loaded?(module) and function_exported?(module, function, length(args)) do
      apply(module, function, args)
    else
      {:error, {:unsupported, :phoenix_presence, module, function, length(args)}}
    end
  end
end
