# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshA2A.MultinodeRouterCountersTest do
  @moduledoc """
  Real, small cross-node telemetry roll-up demo for the new `:phrase` slot
  on `AshA2A.Telemetry.RouterCounters`: proves the extended 3-slot counter
  composes correctly across a real, 2-node cluster.

  Each of two real, separate `:peer`-started BEAM nodes (the same real
  infrastructure `AshA2A.MultinodeClusterTest` already established --
  `:peer.start_link/1`, real Erlang distribution, a real extended code
  path) independently attaches its own `RouterCounters` instance and
  drives its own real facts-tier and phrase-tier dispatches through
  `AshA2A.Planning.RequestRouter.route/3`, entirely on that node, via
  `AshA2A.Test.MultinodeRouterCounters.drive_and_report/3` run through a
  real `:erpc.call/5`. The primary test process (the caller) then merges
  both nodes' real, independently-observed counts maps with plain
  addition (`Map.merge/3` + `+`) -- no new distributed aggregation
  protocol, per this task's own explicit scope: this demo proves the
  counter composes across nodes, it does not build a new subsystem.

  Real collaborators throughout, per this repo's Chicago-style testing
  discipline: two real OS-process BEAM peers, real `:erpc.call/5`
  round-trips, real `RequestRouter.route/3` dispatch through the real
  deterministic solver (`native/hddl_cli`), and a real `RouterCounters`
  instance per node. Zero LLM call (both tiers driven are deterministic
  by construction), zero network I/O, zero mock/stub of any kind.
  """

  use ExUnit.Case, async: false

  alias AshA2A.Test.Fixture.HddlDeterministicFixture
  alias AshA2A.Test.MultinodeRouterCounters

  setup_all do
    # Real, idempotent -- matches this repo's own `mix test` harness
    # expectation that epmd is already running; started defensively here
    # so this file is self-sufficient if run in isolation (same
    # precedent as `AshA2A.MultinodeClusterTest`).
    System.cmd("epmd", ["-daemon"], stderr_to_stdout: true)

    already_alive? = Node.alive?()

    unless already_alive? do
      primary_name = :"ash_a2a_router_counters_primary_#{System.pid()}"
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
    %{cookie: Node.get_cookie(), host: peer_host(), code_paths: :code.get_path()}
  end

  defp peer_host do
    Node.self() |> Atom.to_string() |> String.split("@") |> List.last() |> String.to_charlist()
  end

  # Starts one real, additional BEAM node via `:peer.start_link/1`,
  # extending its code path so it can on-demand-load `AshA2A.*`/
  # `AshA2A.Test.*` modules the first time an `:erpc.call/5` references
  # them -- identical mechanism to `AshA2A.MultinodeClusterTest`'s own
  # `start_real_peer/3`. Deliberately does NOT register `on_exit/1`
  # cleanup itself: `:peer.stop/1` must run on the same process that
  # linked the peer (see that module's @moduledoc for the real,
  # empirically-found reason), so callers wrap their own test body in
  # `try/after` and call `stop_if_alive/1` there instead.
  defp start_real_peer(host, cookie, code_paths) do
    peer_name = :"ash_a2a_router_counters_peer_#{System.unique_integer([:positive, :monotonic])}"

    start_opts = %{
      name: peer_name,
      host: host,
      args: [~c"-setcookie", Atom.to_charlist(cookie)]
    }

    {:ok, peer_pid, peer_node} = :peer.start_link(start_opts)

    assert :ok = :rpc.call(peer_node, :code, :add_pathsz, [code_paths])

    {peer_pid, peer_node}
  end

  defp stop_if_alive(peer_pid) do
    if Process.alive?(peer_pid) do
      :peer.stop(peer_pid)
    end

    :ok
  end

  # The real, correctly-summed merge of two real per-node counts maps --
  # plain key-wise addition, exactly the "simple `:erpc.call` +
  # `Map.merge`-with-add" shape this task's own instructions call for;
  # no new aggregation protocol.
  defp merge_counts(counts_a, counts_b) do
    Map.merge(counts_a, counts_b, fn _key, a, b -> a + b end)
  end

  describe "real 2-node RouterCounters roll-up" do
    test "two independent real peer nodes each drive their own real facts/phrase dispatches, and the caller's merge produces the real, correctly-summed combined counts",
         %{cookie: cookie, host: host, code_paths: code_paths} do
      {pid_a, node_a} = start_real_peer(host, cookie, code_paths)
      {pid_b, node_b} = start_real_peer(host, cookie, code_paths)

      try do
        assert node_a != node_b

        {remote_node_a, counts_a} =
          :erpc.call(
            node_a,
            MultinodeRouterCounters,
            :drive_and_report,
            [HddlDeterministicFixture, 3, 2],
            15_000
          )

        {remote_node_b, counts_b} =
          :erpc.call(
            node_b,
            MultinodeRouterCounters,
            :drive_and_report,
            [HddlDeterministicFixture, 1, 4],
            15_000
          )

        # Real proof each ran on its own real peer, not a same-node
        # illusion and not the OTHER peer -- the same discriminating
        # assertion shape `AshA2A.MultinodeClusterTest` already uses for
        # `GoalFacts.admit/2`.
        assert remote_node_a == node_a
        assert remote_node_b == node_b
        assert remote_node_a != remote_node_b
        assert remote_node_a != node()
        assert remote_node_b != node()

        # Each node's own real, independently-observed counts. The llm
        # slot is untouched by this demo (zero text-tier dispatches
        # driven on either node) -- proof the new phrase slot does not
        # perturb the pre-existing two slots.
        assert counts_a == %{deterministic: 3, llm: 0, phrase: 2}
        assert counts_b == %{deterministic: 1, llm: 0, phrase: 4}

        # The real, correctly-summed combined counts across the 2-node
        # cluster.
        assert merge_counts(counts_a, counts_b) == %{deterministic: 4, llm: 0, phrase: 6}
      after
        stop_if_alive(pid_a)
        stop_if_alive(pid_b)
      end
    end
  end
end
