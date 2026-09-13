defmodule AshA2A.Topology.Group do
  @moduledoc """
  Optional adapter for the `Group` process/topology registry.

  Reads are ephemeral observations. Mutations return `AshA2A.RuntimeReceipt`
  evidence and never imply Ash domain state, task lifecycle truth, authority,
  command execution, or standing beyond the provider operation observed.
  """

  alias AshA2A.{Identity, RuntimeReceipt}

  @spec available?() :: boolean()
  def available?, do: Code.ensure_loaded?(Group)

  @spec key(Identity.t() | String.t() | atom()) :: String.t()
  def key(%Identity{} = identity), do: Identity.external(identity)
  def key(value) when is_binary(value), do: value
  def key(value) when is_atom(value), do: Atom.to_string(value)

  @spec register(term(), Identity.t() | String.t() | atom(), map()) ::
          {:ok, RuntimeReceipt.t()} | {:error, term()}
  def register(registry, identity, metadata \\ %{}) when is_map(metadata) do
    actuate(:register, identity, [registry, key(identity), metadata])
  end

  @spec lookup(term(), Identity.t() | String.t() | atom()) :: term()
  def lookup(registry, identity), do: invoke(:lookup, [registry, key(identity)])

  @spec unregister(term(), Identity.t() | String.t() | atom()) ::
          {:ok, RuntimeReceipt.t()} | {:error, term()}
  def unregister(registry, identity) do
    actuate(:unregister, identity, [registry, key(identity)])
  end

  @spec join(term(), term(), map()) :: {:ok, RuntimeReceipt.t()} | {:error, term()}
  def join(registry, group, metadata \\ %{}) do
    actuate(:join, group, [registry, group, metadata])
  end

  @spec members(term(), term()) :: term()
  def members(registry, group), do: invoke(:members, [registry, group])

  @spec leave(term(), term()) :: {:ok, RuntimeReceipt.t()} | {:error, term()}
  def leave(registry, group), do: actuate(:leave, group, [registry, group])

  defp actuate(function, subject, args) do
    case invoke(function, args) do
      {:error, _} = error -> error
      result -> {:ok, RuntimeReceipt.new(:group, function, subject, result)}
    end
  end

  defp invoke(function, args) do
    if available?() and function_exported?(Group, function, length(args)) do
      apply(Group, function, args)
    else
      {:error, {:unsupported, :group, function, length(args)}}
    end
  end
end
