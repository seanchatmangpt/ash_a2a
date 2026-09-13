defmodule AshA2A.Topology.Group do
  @moduledoc """
  Optional adapter for the `Group` process/topology registry.

  Group membership and lookup are ephemeral observations about where a machine
  process is reachable. They are never promoted to Ash domain state, task
  lifecycle truth, authority, or execution standing.
  """

  alias AshA2A.Identity

  @spec available?() :: boolean()
  def available?, do: Code.ensure_loaded?(Group)

  @spec key(Identity.t() | String.t() | atom()) :: String.t()
  def key(%Identity{} = identity), do: Identity.external(identity)
  def key(value) when is_binary(value), do: value
  def key(value) when is_atom(value), do: Atom.to_string(value)

  @spec register(term(), Identity.t() | String.t() | atom(), map()) :: :ok | {:error, term()}
  def register(registry, identity, metadata \\ %{}) when is_map(metadata) do
    invoke(:register, [registry, key(identity), metadata])
  end

  @spec lookup(term(), Identity.t() | String.t() | atom()) :: term()
  def lookup(registry, identity), do: invoke(:lookup, [registry, key(identity)])

  @spec unregister(term(), Identity.t() | String.t() | atom()) :: term()
  def unregister(registry, identity), do: invoke(:unregister, [registry, key(identity)])

  @spec join(term(), term(), map()) :: term()
  def join(registry, group, metadata \\ %{}), do: invoke(:join, [registry, group, metadata])

  @spec members(term(), term()) :: term()
  def members(registry, group), do: invoke(:members, [registry, group])

  @spec leave(term(), term()) :: term()
  def leave(registry, group), do: invoke(:leave, [registry, group])

  defp invoke(function, args) do
    if available?() and function_exported?(Group, function, length(args)) do
      apply(Group, function, args)
    else
      {:error, {:unsupported, :group, function, length(args)}}
    end
  end
end
