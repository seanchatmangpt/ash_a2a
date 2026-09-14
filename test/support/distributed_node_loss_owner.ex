defmodule AshA2A.Test.DistributedNodeLossOwner do
  @moduledoc """
  Real helper executed ON a real peer BEAM node by
  `AshA2A.DistributedNodeLossTest`, via `Node.spawn/4` (an MFA remote
  spawn -- naming a `{module, function, args}` for the target node to
  `apply/3` and on-demand-load from its own code path).

  This is deliberately NOT an anonymous closure shipped to the peer node:
  Erlang distribution can only execute a remote anonymous `fun` if the
  module that defined it is already loaded, byte-identically, on the
  receiving node. `test/**/*_test.exs` files are compiled in-memory only
  by `mix test` (per this project's `elixirc_paths(:test) = ["lib",
  "test/support"]` in `mix.exs`, ordinary test files are never written to
  `_build/test/lib/ash_a2a/ebin/*.beam`), so a closure defined directly in
  the test module would be unloadable on a freshly-started `:peer` node
  and would fail there with a real `{badfun, ...}`/undef error. This
  module lives under `test/support/` specifically so it IS compiled to a
  real, on-disk `.beam` file the peer node can load from the extended code
  path the test gives it (`:code.add_pathsz/1`).

  `start_group_register_and_wait/6` starts the real `group` hex package's
  `Group.start_link/1` FROM WITHIN this same persistent process, then calls
  the actual production adapter under test, `AshA2A.Topology.Group.register/3`,
  and finally blocks -- so the real `Group.Supervisor`'s link AND the
  registration's real liveness both track this process's (and therefore the
  peer node's) real lifetime.

  This is deliberately NOT split into "start Group via a transient
  `:rpc.call`/`:erpc.call`, then register from a separate spawned process":
  `Group.start_link/1` calls `Supervisor.start_link/3` internally, which
  links the CALLING process to the new supervisor for the supervisor's
  entire lifetime. `:rpc.call`/`:erpc.call` (in this OTP release, `:rpc`
  itself delegates to `:erpc`) execute the remote MFA inside a short-lived
  ephemeral worker process that replies to its caller and then terminates
  using its own reply term as its EXIT reason -- a real, reproducible
  Erlang/OTP gotcha empirically observed while building this test: that
  ephemeral worker's termination is itself a non-`:normal` exit signal
  delivered to everything it is linked to, including the `Group.Supervisor`
  it just started, which promptly crashes with that same reason since a
  plain `Supervisor` treats an exit from an unrecognized linked process as
  fatal. Starting the linked supervisor from a process that stays alive for
  the test's duration (this one) avoids that entirely -- the fix is which
  real process owns the link, not a stand-in for either collaborator.

  Deliberately NOT aliasing `AshA2A.Topology.Group` to `Group` for the same
  reason as the test module itself: this file needs both the real `group`
  package (`Group.start_link`) and the production adapter
  (`AshA2A.Topology.Group.register`, kept fully-qualified) side by side.
  """

  @spec start_group_register_and_wait(
          atom(),
          pos_integer(),
          AshA2A.Identity.t(),
          map(),
          pid()
        ) :: :ok
  def start_group_register_and_wait(group_name, shards, task_id, meta, reply_to) do
    {:ok, sup_pid} = Group.start_link(name: group_name, shards: shards, log: false)
    send(reply_to, {:group_started, sup_pid})

    {:ok, receipt} = AshA2A.Topology.Group.register(group_name, task_id, meta)
    send(reply_to, {:registered, receipt})

    receive do
      :stop -> :ok
    end
  end
end
