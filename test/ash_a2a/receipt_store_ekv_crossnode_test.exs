defmodule AshA2A.ReceiptStoreEkvCrossnodeTest do
  @moduledoc """
  Real, 2-node `EKV` cluster falsifier for `AshA2A.ReceiptStore.Ekv`'s own
  moduledoc claim: "Cross-node claim races are covered the same way, since
  EKV's CAS is cluster-wide, not process-local." That claim was real and
  unfalsified (`lib/ash_a2a/receipt_store/ekv.ex` genuinely uses EKV's
  per-key linearizable `if_vsn:` CAS, and `deps/ekv/README.md` confirms
  `:ekv` genuinely replicates across connected Erlang nodes) -- but
  `test/ash_a2a/receipt_store_ekv_test.exs`'s own 25-racer concurrent-claim
  test, real as it is, only ever runs `cluster_size: 1` against ONE local
  `EKV` instance in ONE OS process. The specific gap this file closes: that
  claim had never actually been exercised against a real multi-node `EKV`
  cluster in this repo. This is that exercise, not a new mechanism -- every
  line below calls the exact, unmodified `AshA2A.ReceiptStore.Ekv` module
  already used single-node in `receipt_store_ekv_test.exs`.

  Every collaborator here is real, per this repo's Chicago-style testing
  discipline (`~/.claude/rules/testing-chicago-style.md`) -- no
  `unittest.mock`/`Mox`/`:meck`/`Mock(` equivalent anywhere in this file:

    * TWO real, separate, connected `EKV` cluster member nodes, each a
      genuinely separate OS process started via OTP's real `:peer` module
      (`:peer.start_link/1`), the exact same pattern
      `test/ash_a2a/multinode_cluster_test.exs` already established for two
      simultaneous real peers -- `start_real_peer/3` and `stop_if_alive/1`
      below are a deliberate, near-verbatim copy of that file's own private
      helpers (private functions cannot be called across modules, and this
      file's peers additionally each run a real local `EKV` member, which
      that file's peers do not), including its documented, empirically-found
      `try/after` (not `on_exit/1`) cleanup discipline for `:peer.stop/1`.
    * A REAL two-voter `EKV` cluster (`cluster_size: 2`, so CAS quorum
      requires both real nodes to agree) -- one real `EKV.start_link/1`
      member per real peer node, each against its own real on-disk
      `data_dir`, connected over real Erlang distribution (no libcluster
      needed here: `:peer.start_link/1`'s default connection mode already
      auto-connects each peer to this primary node, and an explicit
      `Node.ping/1` from peer A to peer B below forces -- and proves -- the
      real third mesh edge peer-to-peer). Each member is started from a
      real, persistent, `Node.spawn/4`-owned process
      (`AshA2A.Test.MultinodeEkvOwner`, `test/support/multinode_ekv_owner.ex`)
      for the same real, previously-diagnosed `Supervisor.start_link/3`-
      links-the-caller reason documented there and on
      `test/support/horde_poc_owner.ex`.
    * REAL, genuinely concurrent cross-node racers: `Task.async/1` on the
      primary test process, each wrapping its own `:erpc.call/5` of the
      exact, unmodified `AshA2A.ReceiptStore.Ekv.claim/2` -- one dispatched
      to execute ON peer node A, one ON peer node B -- against the identical
      fresh `command_id`, adversarially confirming exactly one real
      cluster-wide winner and a real, contract-correct response for the
      loser, never a same-node illusion.
    * REAL cross-node durability: `commit/2` issued on one real node,
      `fetch/2` issued on the OTHER real node, confirming the committed
      receipt is genuinely visible there -- through real `EKV` replication,
      not a shared process or shared memory (`:erpc.call/5`'s own remote
      execution guarantees the read runs on that other node's real BEAM
      process, with its own real, separately-mounted `data_dir`).

  `eventually/3` (adapted from the identical helper already proven in
  `test/ash_a2a/libcluster_horde_poc_test.exs` for real δ-CRDT convergence)
  bounds a real, small, honestly-disclosed wait for `EKV`'s eventual local
  read-visibility to converge after a cluster-wide CAS commit -- `fetch/2`
  calls `EKV.get/2` (an eventual read), not `EKV.get/3, consistent: true`,
  so a strict zero-wait assertion immediately after `commit/2` returns would
  be asserting a stronger real-time guarantee than this store's own
  production `fetch/2` contract actually promises.

  REAL, ADVERSARIALLY-DISCOVERED FINDING (v26.9.16): local sampling of the
  "concurrent claim/2 across two real EKV peer nodes" test below, run 9
  independent times against this real 2-voter cluster, observed 1 run
  (~11%) where BOTH real racers received `{:error, :in_flight}` and
  NEITHER received `{:execute, ...}` -- i.e. the command was never
  actually claimed by anyone, yet both callers were told (via `:in_flight`)
  that someone else had it in flight. This is consistent with a genuine
  dueling-proposer / accept-vs-local-apply-visibility race specific to
  `attempt_fresh_claim/3`'s CAS-conflict rescue path
  (`lib/ash_a2a/receipt_store/ekv.ex`): on `EKV.put(if_vsn: nil)` returning
  `{:error, :conflict}`/`{:error, :unconfirmed}`, it re-reads with a single
  eventual `EKV.get/2` (not a consistent/barrier read) and, if that re-read
  observes `nil`, unconditionally returns `{:error, :in_flight}` -- a
  response that is only actually true if SOME accepted value exists
  cluster-wide, which a `cluster_size: 1` local CAS (no consensus round;
  `test/ash_a2a/receipt_store_ekv_test.exs`'s own 25-racer test) can never
  falsify, since there is no separate "ballot accepted" vs "locally
  visible to an eventual read" window without real multi-node consensus.
  This test's own assertion (`assert length(winners) == 1`) is the correct,
  honest adversarial check for that gap and is deliberately left strict --
  an intermittent failure here is a real reproduction of this real,
  already-observed gap, not test flakiness to be papered over by loosening
  the assertion or adding an internal retry. Fixing
  `attempt_fresh_claim/3`'s rescue path (e.g. a consistent re-read, or a
  bounded internal retry-the-put loop) is real, separate follow-up work
  this task's own scope excluded ("construct that real falsifier, not
  build a new mechanism").
  """

  use ExUnit.Case, async: false

  @moduletag :serial
  @moduletag :serial_solo
  alias AshA2A.{Command, Identity, Receipt}
  alias AshA2A.ReceiptStore.Ekv
  alias AshA2A.Test.MultinodeEkvOwner

  setup_all do
    # Real, idempotent -- matches this repo's own `mix test` harness
    # expectation that epmd is already running; started defensively here so
    # this file is self-sufficient if run in isolation (same precedent as
    # `AshA2A.MultinodeClusterTest`).
    System.cmd("epmd", ["-daemon"], stderr_to_stdout: true)

    already_alive? = Node.alive?()

    unless already_alive? do
      primary_name = :"ash_a2a_ekv_crossnode_primary_#{System.pid()}"
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

  # Near-verbatim copy of `AshA2A.MultinodeClusterTest`'s own private
  # `start_real_peer/3` -- private functions cannot be called across
  # modules, and this file's own peers additionally each run a real local
  # `EKV` member on top, which that file's peers do not.
  defp start_real_peer(host, cookie, code_paths) do
    peer_name = :"ash_a2a_ekv_crossnode_peer_#{System.unique_integer([:positive, :monotonic])}"

    start_opts = %{
      name: peer_name,
      host: host,
      args: [~c"-setcookie", Atom.to_charlist(cookie)]
    }

    {:ok, peer_pid, peer_node} = :peer.start_link(start_opts)

    assert :ok = :rpc.call(peer_node, :code, :add_pathsz, [code_paths])

    {peer_pid, peer_node}
  end

  # Same real, empirically-found reason `AshA2A.MultinodeClusterTest`'s
  # @moduledoc documents: `:peer.stop/1` on a `:peer.start_link/1`-started
  # peer must be called FROM THE SAME process that called `start_link`, so
  # cleanup lives in each test's own `try/after`, not `on_exit/1`.
  defp stop_if_alive(peer_pid) do
    if Process.alive?(peer_pid) do
      :peer.stop(peer_pid)
    end

    :ok
  end

  # Fires the real `Node.spawn/4` that starts one local `EKV` member on
  # `peer_node`, owned by a real, persistent process (see
  # `MultinodeEkvOwner`'s @moduledoc for why this indirection is real and
  # load-bearing, not decoration). Returns immediately (`Node.spawn/4`
  # itself does not block) -- deliberately split from
  # `await_ekv_member_started/1` below so BOTH real cluster members can be
  # told to start CONCURRENTLY. This split is real and load-bearing, not
  # decoration: with `wait_for_quorum:` set, `EKV.start_link/1` itself
  # blocks the owner process, on that node, until the real 2-of-2 CAS
  # quorum is reachable -- so starting node B only AFTER awaiting node A's
  # reply would starve node A's own quorum wait for the entire window (node
  # B would not even begin joining until node A had already given up). An
  # earlier version of this file called `start_ekv_member/2` (spawn + await
  # in one step) sequentially for node A then node B and reproduced exactly
  # that real deadlock: node A's own log showed
  # `[error] ... startup quorum wait failed: :timeout` because node B had
  # not been told to start yet.
  defp spawn_ekv_member(peer_node, ekv_opts, reply_to) do
    Node.spawn(peer_node, MultinodeEkvOwner, :start_ekv_member_and_wait, [ekv_opts, reply_to])
  end

  # Blocks for the real `{:ekv_member_started, ^peer_node, sup_pid}` reply
  # from a member previously started via `spawn_ekv_member/3`.
  defp await_ekv_member_started(peer_node) do
    receive do
      {:ekv_member_started, ^peer_node, sup_pid} ->
        sup_pid

      {:ekv_member_start_failed, ^peer_node, reason} ->
        flunk("real EKV member failed to start on #{inspect(peer_node)}: #{inspect(reason)}")
    after
      30_000 ->
        flunk("real EKV member on #{inspect(peer_node)} did not report readiness within 30s")
    end
  end

  defp real_command(command_id, opts \\ []) do
    Command.new("AshA2A.Test.Fixture.Echo.read",
      command_id: command_id,
      agent_id: Keyword.get(opts, :agent_id, "agent-1"),
      principal_id: Keyword.get(opts, :principal_id, "anonymous"),
      input: Keyword.get(opts, :input, %{})
    )
  end

  defp real_receipt(command, execution_id, opts \\ []) do
    reply = Keyword.get(opts, :reply, {:reply, %{ok: true}})
    Receipt.from_reply(command, execution_id, :observe, reply)
  end

  defp fresh_ekv_name do
    :"ash_a2a_ekv_crossnode_#{System.unique_integer([:positive, :monotonic])}"
  end

  defp fresh_data_dir(tag) do
    Path.join(
      System.tmp_dir!(),
      "ash_a2a_ekv_crossnode_#{tag}_#{System.unique_integer([:positive])}"
    )
  end

  defp eventually(fun, attempts \\ 100, sleep_ms \\ 50)
  defp eventually(_fun, 0, _sleep_ms), do: false

  defp eventually(fun, attempts, sleep_ms) do
    if fun.() do
      true
    else
      Process.sleep(sleep_ms)
      eventually(fun, attempts - 1, sleep_ms)
    end
  end

  # NOTE: ExUnit derives an internal function (and, inside `try/after`, an
  # anonymous-fun) name from "test " <> describe <> " " <> test-name; Erlang
  # atom names are capped at 255 bytes, so these two `describe`/test-name
  # pairs are deliberately kept short -- the detailed real-collaborator
  # explanation lives in this module's @moduledoc and in code comments
  # instead, where atom length does not apply. A first version of this file
  # used long, fully-descriptive names here (matching this repo's usual
  # style) and hit a real `** (SystemLimitError) a system limit has been
  # reached` from `:erlang.list_to_atom/1` at compile time -- this is the
  # fix, not a style downgrade.
  describe "cross-node claim atomicity" do
    test "concurrent claim/2 across two real EKV peer nodes: exactly one cluster-wide winner",
         %{cookie: cookie, host: host, code_paths: code_paths} do
      assert Node.alive?(), "primary node must be a real distributed node by this point"

      {peer_pid_a, node_a} = start_real_peer(host, cookie, code_paths)
      {peer_pid_b, node_b} = start_real_peer(host, cookie, code_paths)

      try do
        # Real starting membership + real peer-to-peer mesh edge (not just
        # each peer's own link back to this primary).
        assert node_a in Node.list()
        assert node_b in Node.list()
        assert :erpc.call(node_a, Node, :ping, [node_b], 10_000) == :pong
        assert :erpc.call(node_b, Node, :ping, [node_a], 10_000) == :pong

        ekv_name = fresh_ekv_name()
        data_dir_a = fresh_data_dir("a")
        data_dir_b = fresh_data_dir("b")
        on_exit(fn -> File.rm_rf!(data_dir_a) end)
        on_exit(fn -> File.rm_rf!(data_dir_b) end)

        base_opts = [name: ekv_name, cluster_size: 2, wait_for_quorum: :timer.seconds(25)]
        test_pid = self()

        # Both real members are told to start CONCURRENTLY -- see
        # `spawn_ekv_member/3`'s comment for why sequential spawn+await
        # would deadlock each member's own `wait_for_quorum:` wait.
        _owner_a =
          spawn_ekv_member(node_a, Keyword.put(base_opts, :data_dir, data_dir_a), test_pid)

        _owner_b =
          spawn_ekv_member(node_b, Keyword.put(base_opts, :data_dir, data_dir_b), test_pid)

        sup_a = await_ekv_member_started(node_a)
        sup_b = await_ekv_member_started(node_b)

        assert node(sup_a) == node_a
        assert node(sup_b) == node_b

        store_opts = [name: ekv_name]
        command_id = "ekv-crossnode-claim-#{System.unique_integer([:positive])}"
        command = real_command(command_id)

        # Real, genuinely concurrent cross-node racers -- one `Task.async/1`
        # per real node, each wrapping its own real `:erpc.call/5` of the
        # exact, unmodified `AshA2A.ReceiptStore.Ekv.claim/2`.
        task_a =
          Task.async(fn ->
            {node_a, :erpc.call(node_a, Ekv, :claim, [command, store_opts], 15_000)}
          end)

        task_b =
          Task.async(fn ->
            {node_b, :erpc.call(node_b, Ekv, :claim, [command, store_opts], 15_000)}
          end)

        [result_a, result_b] = Task.await_many([task_a, task_b], 20_000)
        results = [result_a, result_b]

        {winners, losers} =
          Enum.split_with(results, fn {_node, result} ->
            match?({:execute, %Identity{kind: :execution}}, result)
          end)

        # Exactly one real cluster-wide winner -- never zero (the race must
        # be resolved by someone), never two-or-more (that would be the
        # double-dispatch this CAS fix exists to prevent, now proven across
        # two real physical nodes instead of one local process).
        assert length(winners) == 1,
               "expected exactly one real cross-node claim winner, got: #{inspect(results)}"

        assert length(losers) == 1

        # The real loser must see a real, contract-correct
        # `decide_claim/2` response -- `:in_flight` (nothing committed yet)
        # or a real `:replay` (if timing let the winner's commit land
        # first) -- per this task's own instruction not to force a single
        # outcome, only that the response is one of the two the contract
        # actually allows.
        assert Enum.all?(losers, fn {_node, result} ->
                 match?({:error, :in_flight}, result) or match?({:replay, %Receipt{}}, result)
               end),
               "loser must get a real decide_claim/2-contract response, got: #{inspect(losers)}"

        [{winner_node, {:execute, execution_id}}] = winners
        [{loser_node, _loser_result}] = losers

        assert winner_node in [node_a, node_b]
        assert loser_node in [node_a, node_b]
        assert winner_node != loser_node

        receipt = real_receipt(command, execution_id)
        assert :ok = :erpc.call(winner_node, Ekv, :commit, [receipt, store_opts], 15_000)

        # Real cross-node durability: fetch/2 issued on the OTHER real node
        # (never the winner's own node) must eventually see the real
        # committed receipt, through real EKV replication -- bounded, honest
        # polling for eventual local read-visibility (fetch/2's own real
        # contract; see this module's @moduledoc).
        assert eventually(fn ->
                 case :erpc.call(loser_node, Ekv, :fetch, [command.command_id, store_opts], 5_000) do
                   {:ok, %Receipt{receipt_id: rid}} -> rid == receipt.receipt_id
                   _ -> false
                 end
               end),
               "committed receipt must really replicate to the other real node's local EKV replica"

        assert {:ok, fetched_from_loser} =
                 :erpc.call(loser_node, Ekv, :fetch, [command.command_id, store_opts], 5_000)

        assert fetched_from_loser.receipt_id == receipt.receipt_id
        assert fetched_from_loser.command_id == command.command_id
        assert fetched_from_loser.execution_id == execution_id

        # And the winner's own node, for good measure -- proving both real
        # nodes converge on the identical execution_id/receipt_id, i.e. no
        # split-brain / no data corruption.
        assert {:ok, fetched_from_winner} =
                 :erpc.call(winner_node, Ekv, :fetch, [command.command_id, store_opts], 5_000)

        assert fetched_from_winner.receipt_id == receipt.receipt_id
        assert fetched_from_winner.execution_id == execution_id
      after
        stop_if_alive(peer_pid_a)
        stop_if_alive(peer_pid_b)
      end
    end
  end

  describe "cross-node commit/fetch durability" do
    test "commit on node A replicates for fetch on node B; retry claimed from node B replays",
         %{cookie: cookie, host: host, code_paths: code_paths} do
      {peer_pid_a, node_a} = start_real_peer(host, cookie, code_paths)
      {peer_pid_b, node_b} = start_real_peer(host, cookie, code_paths)

      try do
        assert :erpc.call(node_a, Node, :ping, [node_b], 10_000) == :pong

        ekv_name = fresh_ekv_name()
        data_dir_a = fresh_data_dir("commit_a")
        data_dir_b = fresh_data_dir("commit_b")
        on_exit(fn -> File.rm_rf!(data_dir_a) end)
        on_exit(fn -> File.rm_rf!(data_dir_b) end)

        base_opts = [name: ekv_name, cluster_size: 2, wait_for_quorum: :timer.seconds(25)]
        test_pid = self()

        # Concurrent spawn -- same real deadlock reason as the sibling test
        # above (`spawn_ekv_member/3`'s comment).
        spawn_ekv_member(node_a, Keyword.put(base_opts, :data_dir, data_dir_a), test_pid)
        spawn_ekv_member(node_b, Keyword.put(base_opts, :data_dir, data_dir_b), test_pid)
        await_ekv_member_started(node_a)
        await_ekv_member_started(node_b)

        store_opts = [name: ekv_name]
        command_id = "ekv-crossnode-commit-#{System.unique_integer([:positive])}"
        command = real_command(command_id)

        # Deterministic (not race-dependent): claim + commit both issued
        # ON NODE A.
        assert {:execute, execution_id} =
                 :erpc.call(node_a, Ekv, :claim, [command, store_opts], 15_000)

        receipt = real_receipt(command, execution_id)
        assert :ok = :erpc.call(node_a, Ekv, :commit, [receipt, store_opts], 15_000)

        # fetch/2 issued ON NODE B -- must really see it via real EKV
        # replication (bounded, honest wait for eventual local
        # read-visibility; see this module's @moduledoc).
        assert eventually(fn ->
                 case :erpc.call(node_b, Ekv, :fetch, [command.command_id, store_opts], 5_000) do
                   {:ok, %Receipt{receipt_id: rid}} -> rid == receipt.receipt_id
                   _ -> false
                 end
               end),
               "receipt committed on node A must really replicate to node B's local EKV replica"

        assert {:ok, fetched} =
                 :erpc.call(node_b, Ekv, :fetch, [command.command_id, store_opts], 5_000)

        assert fetched.receipt_id == receipt.receipt_id
        assert fetched.command_id == command.command_id
        assert fetched.execution_id == execution_id
        refute fetched.replayed?

        # A same-id/same-fingerprint retry claimed FROM NODE B (the node
        # that only ever learned about this entry through real
        # replication, never claimed or committed it itself) must replay
        # the real committed receipt through the exact same
        # fingerprint-match `decide_claim/2` logic a first-time reader
        # uses -- never a second real execution_id.
        retry_command = real_command(command_id)

        assert {:replay, replayed} =
                 :erpc.call(node_b, Ekv, :claim, [retry_command, store_opts], 15_000)

        assert replayed.receipt_id == receipt.receipt_id
        assert replayed.execution_id == execution_id
        assert replayed.replayed?
      after
        stop_if_alive(peer_pid_a)
        stop_if_alive(peer_pid_b)
      end
    end
  end
end
