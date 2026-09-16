defmodule AshA2A.Test.MultinodeDispatch do
  @moduledoc """
  Real helper executed ON a real peer BEAM node via `:erpc.call/4` by
  `AshA2A.MultinodeClusterTest`, proving genuine cross-node execution of
  `AshA2A.Planning.GoalFacts.admit/2` -- the same real, safe, non-actuating
  admission function the fleet-density branch's own dispatch path calls --
  rather than a same-node illusion.

  Lives under `test/support/` rather than inline in the test module for the
  same real reason `AshA2A.Test.DistributedNodeLossOwner`'s own @moduledoc
  documents: `elixirc_paths(:test) = ["lib", "test/support"]` (`mix.exs`)
  means only files under those two paths are compiled to real, on-disk
  `.beam` files a freshly-started `:peer` node can load from an extended
  code path (`:code.add_pathsz/1`) the first time the MFA references them --
  a closure captured by a `*_test.exs` module would be unloadable there and
  would fail on the peer with a real `{badfun, ...}`/undef error.

  This is not a mock or a stand-in for `GoalFacts.admit/2`: it calls the
  real, unmodified function and returns its real result verbatim, merely
  tagging it with this process's own real `node()` -- captured on whichever
  node the MFA actually executes -- so the caller can assert the admission
  genuinely ran on the remote peer (`node() != caller's own node()`), not
  merely that a reply message came back over the wire.
  """

  @spec admit_on_this_node(module(), map()) :: {node(), {:ok, map()} | {:error, map()}}
  def admit_on_this_node(resource_or_domain, envelope) do
    {node(), AshA2A.Planning.GoalFacts.admit(resource_or_domain, envelope)}
  end
end
