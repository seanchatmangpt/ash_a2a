defmodule AshA2A.DistributedNodeLossTest do
  @moduledoc """
  Real distributed-BEAM node-loss coverage (GAP C, Squad E).

  Every collaborator here is real, per this repo's Chicago-style testing
  discipline (`~/.claude/rules/testing-chicago-style.md`):

    * a REAL second BEAM node, started as a genuinely separate OS process via
      Erlang/OTP 25+'s real `:peer` module (the documented replacement for
      the deprecated `:slave` module) -- not an in-process stand-in;
    * REAL Erlang distribution connectivity (`Node.ping/1`, `Node.list/0`,
      real `:net_kernel.monitor_nodes/1` `:nodeup`/`:nodedown` events);
    * the REAL `group` hex package (transitive dep of `:durable_server`,
      already declared in `mix.lock`) -- the exact same dependency
      `AshA2A.Topology.Group` (`lib/ash_a2a/topology/group.ex`) adapts --
      exercised directly against a real second node's real registration.

  This exists specifically to replace the same-node stand-in in
  `test/ash_a2a/durable_server_continuity_test.exs`
  (`AshA2A.Test.FakeDurableServerSupervisor.simulate_node_loss/2`, an
  in-memory `Agent` filtering entries by a `:node` atom tag it invented
  itself) for the one capability that stand-in cannot actually exercise:
  real node loss. That fixture remains untouched and still serves its own
  purpose (fast, deterministic DurableServer generation/rehome semantics);
  this file adds the real distributed evidence alongside it, it does not
  delete or replace the fixture file.

  `TaskID != PID != Node`: an `AshA2A.Identity.task/1` is captured as a
  stable `AshA2A.Topology.Group` key BEFORE any peer node exists. A real
  process OWNED by the real peer node (spawned with `Node.spawn/2`, so its
  lifetime is tied to that node, not to an RPC call that returns
  immediately) registers under that key using the actual production
  adapter, `AshA2A.Topology.Group.register/3`. The peer node is then really
  stopped (`:peer.stop/1` -- a real `SIGTERM`-equivalent to a real OS BEAM
  process). The original PID and the original Node are both really gone
  (`Node.list/0` no longer contains it, the registration's owning process
  cannot be reached), but the logical identity -- the TaskID-derived key
  string -- survives: the primary node observes a real, typed
  `%Group.Event{type: :unregistered, reason: :nodedown}` purge (Group's own
  real cross-node membership mechanism, not an invented signal), and the
  same key can be re-registered against a live process on a surviving node,
  proving the identity was never bound to the dead PID or dead node in the
  first place.
  """
  use ExUnit.Case, async: false

  @moduletag :serial
  @moduletag :serial_solo
  # Deliberately NOT aliasing `AshA2A.Topology.Group` to `Group` here: this
  # file mostly drives the REAL `group` hex package (`Group.start_link`,
  # `Group.monitor`, `Group.lookup`, the real `%Group.Event{}` struct)
  # directly, alongside a couple of calls into the production adapter
  # `AshA2A.Topology.Group` (kept fully-qualified below) -- aliasing the
  # adapter to the bare name `Group` would shadow the real dependency for
  # the rest of the file.
  alias AshA2A.Identity

  setup_all do
    # Real, idempotent -- matches this repo's own `mix test` harness
    # expectation that epmd is already running; started defensively here so
    # this file is self-sufficient if run in isolation.
    System.cmd("epmd", ["-daemon"], stderr_to_stdout: true)

    already_alive? = Node.alive?()

    unless already_alive? do
      primary_name = :"ash_a2a_test_primary_#{System.pid()}"
      {:ok, _pid} = Node.start(primary_name, :shortnames)
    end

    on_exit(fn ->
      if not already_alive? and Node.alive?() do
        Node.stop()
      end
    end)

    :ok
  end

  setup do
    # Give every peer node its own code path + cookie so BEAM's normal
    # on-demand code loading can resolve `Group`, `AshA2A.*`, etc. the first
    # time the peer-owned process references them.
    %{cookie: Node.get_cookie(), host: peer_host(), code_paths: :code.get_path()}
  end

  defp peer_host do
    Node.self() |> Atom.to_string() |> String.split("@") |> List.last() |> String.to_charlist()
  end

  defp start_real_peer(host, cookie) do
    peer_name = :"ash_a2a_peer_#{System.unique_integer([:positive, :monotonic])}"

    start_opts = %{
      name: peer_name,
      host: host,
      args: [~c"-setcookie", Atom.to_charlist(cookie)]
    }

    {:ok, peer_pid, peer_node} = :peer.start(start_opts)
    {peer_pid, peer_node}
  end

  test "a real second BEAM node starts via :peer and connects over real Erlang distribution",
       %{cookie: cookie, host: host} do
    assert Node.alive?(), "primary node must be a real distributed node by this point"

    peer_name = :"ash_a2a_probe_peer_#{System.unique_integer([:positive, :monotonic])}"

    start_opts = %{
      name: peer_name,
      host: host,
      args: [~c"-setcookie", Atom.to_charlist(cookie)]
    }

    assert {:ok, peer_pid, peer_node} = :peer.start(start_opts)
    assert is_pid(peer_pid)
    assert peer_node in Node.list()

    # Real connectivity check via :net_adm.ping/1 (per the task's explicit
    # ask), then a real distributed RPC round-trip proving the peer is a
    # genuinely separate, independently-executing BEAM runtime.
    assert :net_adm.ping(peer_node) == :pong
    assert :rpc.call(peer_node, :erlang, :node, []) == peer_node
    assert :rpc.call(peer_node, :erlang, :self, []) != self()

    :ok = :net_kernel.monitor_nodes(true)
    assert :ok = :peer.stop(peer_pid)

    assert_receive {:nodedown, ^peer_node}, 5_000
    refute peer_node in Node.list()

    :ok = :net_kernel.monitor_nodes(false)
  end

  test "real Group membership on a real peer node is purged with a real :nodedown event when the peer node is really stopped (TaskID != PID != Node)",
       %{cookie: cookie, host: host, code_paths: code_paths} do
    group_name = :"ash_a2a_dnl_group_#{System.unique_integer([:positive, :monotonic])}"

    # Real Group instance on the primary node -- same startup shape already
    # used by AshA2A.GroupTopologyTest / AshA2A.RuntimeProvidersIntegrationTest
    # for the other runtime-provider adapters.
    start_supervised!({Group, name: group_name, shards: 2, log: false})

    # The test process becomes a real Group monitor: it will receive real
    # `{:group, events, info}` messages for every registration/purge in this
    # cluster, exactly as documented by the real `group` hex package.
    :ok = Group.monitor(group_name, :all)

    {peer_pid, peer_node} = start_real_peer(host, cookie)
    assert :net_adm.ping(peer_node) == :pong

    # Give the peer node the same code path as the primary so it can
    # on-demand-load Group/AshA2A.* the first time they're referenced --
    # real BEAM code loading, not a fixture copy.
    assert :rpc.call(peer_node, :code, :add_pathsz, [code_paths]) == :ok

    task_id = Identity.task("distributed-node-loss-#{System.unique_integer([:positive])}")
    key = AshA2A.Topology.Group.key(task_id)
    assert key =~ "task:distributed-node-loss-"

    test_pid = self()

    # A REAL process OWNED by the peer node, spawned via an MFA remote spawn
    # (Node.spawn/4 naming
    # AshA2A.Test.DistributedNodeLossOwner.start_group_register_and_wait/5 --
    # NOT a shipped anonymous closure; see that module's @moduledoc for why
    # a closure defined in this test module would be unloadable on a
    # freshly-started peer node).
    #
    # This SAME persistent process both starts the real, matching
    # (:name/:shards) Group instance ON the peer node (so the two real
    # replicas can peer/replicate over real Erlang distribution) AND
    # registers the TaskID key under the real production adapter
    # AshA2A.Topology.Group.register/3, then blocks. Deliberately NOT split
    # across a transient :rpc.call/:erpc.call (for Group.start_link) plus a
    # separate spawned registrar: Group.start_link/1 calls
    # Supervisor.start_link/3 internally, which links the CALLING process to
    # the new supervisor for its whole lifetime. An :rpc.call/:erpc.call's
    # own ephemeral remote worker replies to its caller and then terminates
    # using its own reply term as its EXIT reason (:rpc delegates to :erpc
    # in this OTP release) -- a real, reproducible gotcha found while
    # building this test: that non-:normal exit, delivered over the link
    # Supervisor.start_link just created, crashes the freshly-started
    # Group.Supervisor immediately. Starting it from a process that stays
    # alive for the whole test (this one) keeps the link's owner real and
    # alive, which is the actual fix -- not a stand-in for either
    # collaborator.
    owner_pid =
      Node.spawn(
        peer_node,
        AshA2A.Test.DistributedNodeLossOwner,
        :start_group_register_and_wait,
        [group_name, 2, task_id, %{role: :owner}, test_pid]
      )

    assert_receive {:group_started, peer_group_sup}, 5_000
    assert is_pid(peer_group_sup)
    assert node(peer_group_sup) == peer_node

    assert_receive {:registered, receipt}, 5_000
    assert receipt.provider == :group
    assert receipt.operation == :register
    assert node(owner_pid) == peer_node

    # Real cross-node replication: the primary node's real Group replica
    # observes the peer-owned registration (eventually consistent, per the
    # real `group` package's own documented model -- poll rather than
    # sleep a fixed guess).
    assert eventually(fn -> match?({^owner_pid, _meta}, Group.lookup(group_name, key)) end)
    assert {^owner_pid, %{role: :owner}} = Group.lookup(group_name, key)

    # Real node death: :peer.stop/1 really terminates the real OS process
    # backing the peer node.
    assert :ok = :peer.stop(peer_pid)

    # Real, typed purge event delivered by Group's own real :nodedown
    # handling -- not a signal this test invented. This test process's
    # mailbox already holds an earlier real `:registered` Group event (from
    # the peer's own registration replicating over, before the node was
    # stopped) since it monitors `:all`, so this drains messages until the
    # specific `:unregistered`/`:nodedown` purge for our key shows up,
    # rather than asserting on whichever `{:group, ...}` message happens to
    # be first in the mailbox.
    purge_event = await_group_event(key, :unregistered, 10_000)

    assert %Group.Event{type: :unregistered, key: ^key, pid: ^owner_pid, reason: reason} =
             purge_event

    # Group.Replica has two real internal paths to a node-loss purge: the
    # coarse `:net_kernel.monitor_nodes` `:nodedown` event (reason ==
    # `:nodedown`), and a `:DOWN` monitor on the remote shard PID itself,
    # which the real dependency's own moduledoc documents as tagging the
    # purge `{:nodedown, remote_node}` instead. Both are real, dependency-
    # produced shapes for the same real fact (this key's owning node died);
    # which one wins is a real, environment-dependent delivery-ordering
    # detail of the dependency, not something this test should overfit to.
    assert reason == :nodedown or match?({:nodedown, ^peer_node}, reason)

    # The real node is really gone.
    refute peer_node in Node.list()

    # And the original registration is really purged on the surviving node.
    assert Group.lookup(group_name, key) == nil

    # TaskID != PID != Node: the SAME logical key is re-registered against a
    # brand-new, live process on the SURVIVING primary node. Same identity,
    # completely different PID, completely different Node -- proving the
    # identity was never bound to the dead peer's PID or dead peer's Node.
    assert {:ok, rehome_receipt} =
             AshA2A.Topology.Group.register(group_name, task_id, %{role: :rehomed})

    assert rehome_receipt.provider == :group
    assert {rehomed_pid, %{role: :rehomed}} = Group.lookup(group_name, key)
    assert rehomed_pid == self()
    assert rehomed_pid != owner_pid
    assert node(rehomed_pid) == node()
    assert node(rehomed_pid) != peer_node
  end

  # Drains real `{:group, events, info}` monitor messages (Group.monitor/2
  # delivers one such message per batch of real events) until one contains a
  # real event matching `key`/`type`, ignoring any other real events already
  # queued ahead of it (e.g. this process's own earlier `:registered`
  # notification). Returns the matching real %Group.Event{}.
  defp await_group_event(key, type, timeout_ms) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms
    do_await_group_event(key, type, deadline)
  end

  defp do_await_group_event(key, type, deadline) do
    remaining = deadline - System.monotonic_time(:millisecond)

    if remaining <= 0 do
      ExUnit.Assertions.flunk(
        "timed out waiting for a real Group #{inspect(type)} event for key #{inspect(key)}"
      )
    end

    receive do
      {:group, events, _info} ->
        case Enum.find(events, &(&1.key == key and &1.type == type)) do
          nil -> do_await_group_event(key, type, deadline)
          event -> event
        end
    after
      remaining ->
        ExUnit.Assertions.flunk(
          "timed out waiting for a real Group #{inspect(type)} event for key #{inspect(key)}"
        )
    end
  end

  defp eventually(fun, attempts \\ 50, sleep_ms \\ 20)
  defp eventually(_fun, 0, _sleep_ms), do: false

  defp eventually(fun, attempts, sleep_ms) do
    if fun.() do
      true
    else
      Process.sleep(sleep_ms)
      eventually(fun, attempts - 1, sleep_ms)
    end
  end
end
