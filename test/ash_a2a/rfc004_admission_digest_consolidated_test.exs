# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
# SPDX-License-Identifier: MIT

# ==============================================================================
# Consolidated Test Suite: RFC004, Admission, and Digest
# Target File 2 of Worker 08
# Consolidated from 21 source files:
#   - test/ash_a2a/receipt_store_ekv_crossnode_test.exs
#   - test/ash_a2a/receipt_store_ekv_test.exs
#   - test/ash_a2a/reconciliation_mape_k_test.exs
#   - test/ash_a2a/rfc004_agent_scope_test.exs
#   - test/ash_a2a/rfc004_authority_effect_kill_test.exs
#   - test/ash_a2a/rfc004_fence_test.exs
#   - test/ash_a2a/rfc004_outbox_integrity_test.exs
#   - test/ash_a2a/rfc004_spg_independence_test.exs
#   - test/ash_a2a/sa2a_conformance_test.exs
#   - test/ash_a2a/sa2a_formal_invariants_conformance_test.exs
#   - test/ash_a2a/scheduled_sweep_qualification_test.exs
#   - test/ash_a2a/sec_m11_effect_instance_test.exs
#   - test/ash_a2a/sec_m14_canonical_identity_test.exs
#   - test/ash_a2a/semantic_admission_hash_test.exs
#   - test/ash_a2a/semantic_admission_pipeline_test.exs
#   - test/ash_a2a/semantic_admission_standing_test.exs
#   - test/ash_a2a/semantic_admission_test.exs
#   - test/ash_a2a/semantic_admission_vacuity_test.exs
#   - test/ash_a2a/semantic_bounds_test.exs
#   - test/ash_a2a/semantic_canonical_digest_test.exs
#   - test/ash_a2a/semantic_canonical_term_digest_test.exs
# ==============================================================================

# --- SECTION 1: Original test/ash_a2a/receipt_store_ekv_crossnode_test.exs ---
# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
#
# SPDX-License-Identifier: MIT

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

# --- SECTION 2: Original test/ash_a2a/receipt_store_ekv_test.exs ---
# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshA2A.ReceiptStoreEkvTest do
  @moduledoc """
  Exercises `AshA2A.ReceiptStore.Ekv` against a real, on-disk `EKV` instance
  -- started via `start_supervised!/1` with a real temp `data_dir` under
  `System.tmp_dir!/0` and `cluster_size: 1`, the exact same real-local-EKV
  pattern already used by
  `test/ash_a2a_runtime_providers_integration_test.exs` -- rather than any
  mock/stub of `EKV` or of the `AshA2A.ReceiptStore` behaviour. No
  Mock/mox/patch/monkeypatch anywhere in this file.
  """

  use ExUnit.Case, async: false

  @moduletag :serial
  @moduletag :serial_shard
  import AshA2A.Test.MessageHelpers

  alias AshA2A.{Command, CommandBus, Identity, Receipt}
  alias AshA2A.ReceiptStore.{Ekv, Memory}
  alias AshA2A.Test.Fixture.Echo

  setup do
    ekv_name = :"ash_a2a_receipt_ekv_test_#{System.unique_integer([:positive])}"

    data_dir =
      Path.join(
        System.tmp_dir!(),
        "ash_a2a_receipt_store_ekv_test_#{System.unique_integer([:positive])}"
      )

    on_exit(fn -> File.rm_rf!(data_dir) end)

    # cluster_size: 1 -- a real single-voter setup, sufficient for these
    # tests; mirrors test/ash_a2a_runtime_providers_integration_test.exs's
    # real local EKV setup exactly.
    start_supervised!({EKV, name: ekv_name, data_dir: data_dir, cluster_size: 1})

    %{store_opts: [name: ekv_name]}
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

  describe "AshA2A.ReceiptStore.Ekv real disk-backed claim/commit/fetch" do
    test "declares itself durable via a real durable?/0 function" do
      assert Ekv.durable?()
    end

    test "claim -> commit -> fetch round-trips through real on-disk storage", %{
      store_opts: store_opts
    } do
      command = real_command("ekv-roundtrip-1")

      assert {:execute, %Identity{kind: :execution} = execution_id} =
               Ekv.claim(command, store_opts)

      receipt = real_receipt(command, execution_id)

      assert :ok = Ekv.commit(receipt, store_opts)

      assert {:ok, fetched} = Ekv.fetch(command.command_id, store_opts)
      assert fetched.receipt_id == receipt.receipt_id
      assert fetched.command_id == command.command_id
      assert fetched.execution_id == execution_id
      refute fetched.replayed?
    end

    test "fetch on an unclaimed command id returns :error", %{store_opts: store_opts} do
      unclaimed_id = Identity.command("ekv-never-claimed")
      assert :error = Ekv.fetch(unclaimed_id, store_opts)
    end

    test "a claimed-but-not-yet-committed command id is :in_flight", %{store_opts: store_opts} do
      command = real_command("ekv-in-flight-1")

      assert {:execute, _execution_id} = Ekv.claim(command, store_opts)

      # Same id, same fingerprint (identical command content), but nothing
      # has been committed yet -- Memory's handle_call/{:claim, ...} clause
      # for this exact same-fingerprint/no-receipt-yet case replies
      # {:error, :in_flight}; this store must decide the same way.
      same_command_again = real_command("ekv-in-flight-1")
      assert {:error, :in_flight} = Ekv.claim(same_command_again, store_opts)
    end

    test "same-id/same-fingerprint replays the already-committed receipt, no second claim", %{
      store_opts: store_opts
    } do
      command = real_command("ekv-replay-1")

      assert {:execute, execution_id} = Ekv.claim(command, store_opts)
      receipt = real_receipt(command, execution_id)
      assert :ok = Ekv.commit(receipt, store_opts)

      # A real retry: identical command_id and fingerprint (same input).
      retry_command = real_command("ekv-replay-1")

      assert {:replay, replayed} = Ekv.claim(retry_command, store_opts)
      assert replayed.receipt_id == receipt.receipt_id
      assert replayed.replayed?
    end

    test "same-id/different-fingerprint is a real :command_conflict", %{store_opts: store_opts} do
      command = real_command("ekv-conflict-1", input: %{})
      assert {:execute, execution_id} = Ekv.claim(command, store_opts)
      receipt = real_receipt(command, execution_id)
      assert :ok = Ekv.commit(receipt, store_opts)

      conflicting_command = real_command("ekv-conflict-1", input: %{other: true})
      assert {:error, :command_conflict} = Ekv.claim(conflicting_command, store_opts)
    end

    test "commit on an unclaimed command id is refused", %{store_opts: store_opts} do
      command = real_command("ekv-unclaimed-commit-1")
      execution_id = Identity.execution(Ash.UUIDv7.generate())
      receipt = real_receipt(command, execution_id)

      assert {:error, :unclaimed_command} = Ekv.commit(receipt, store_opts)
    end

    test "concurrent claim/2 racers on one fresh command_id: exactly one wins, no double-dispatch",
         %{store_opts: store_opts} do
      command_id = "ekv-concurrent-claim-#{System.unique_integer([:positive])}"
      racer_count = 25

      # Real OS processes racing a real EKV instance -- no mocking, no
      # serialized loop. A barrier holds every task at the door until every
      # one of them has reported ready, then releases all of them at once so
      # they enter `Ekv.claim/2` as concurrently as the BEAM scheduler and
      # EKV's own shard process allow. This is the actual TOCTOU window the
      # `if_vsn: nil` CAS fix closes: before the fix, every racer could
      # observe `EKV.get/2` returning `nil` for this same fresh command_id
      # and every racer's unconditional `EKV.put/3` would then "win".
      parent = self()
      barrier = make_ref()

      tasks =
        for _ <- 1..racer_count do
          Task.async(fn ->
            command = real_command(command_id, input: %{})
            send(parent, {:ready, barrier, self()})

            receive do
              {:go, ^barrier} -> :ok
            end

            Ekv.claim(command, store_opts)
          end)
        end

      for _ <- 1..racer_count do
        receive do
          {:ready, ^barrier, pid} -> send(pid, {:go, barrier})
        end
      end

      results = Task.await_many(tasks, 10_000)

      {executes, non_executes} =
        Enum.split_with(results, &match?({:execute, %Identity{kind: :execution}}, &1))

      # Exactly one real winner -- never zero (the race must be resolved by
      # someone), never two-or-more (that would be the double-dispatch this
      # fix exists to prevent).
      assert length(executes) == 1

      # Every other real racer observed the winner's in-flight claim through
      # the same fingerprint-match decision logic a first-time reader uses --
      # never a second distinct successful claim, and never :command_conflict
      # (every racer submitted the exact same command content, so fingerprints
      # match) or :replay (no commit happened during the race).
      assert Enum.all?(non_executes, &match?({:error, :in_flight}, &1))
      assert length(non_executes) == racer_count - 1

      # The single winner can still commit and fetch normally afterward --
      # the CAS fix does not disturb the rest of the store's real behavior.
      [{:execute, execution_id}] = executes
      winning_command = real_command(command_id, input: %{})
      receipt = real_receipt(winning_command, execution_id)
      assert :ok = Ekv.commit(receipt, store_opts)
      assert {:ok, fetched} = Ekv.fetch(winning_command.command_id, store_opts)
      assert fetched.receipt_id == receipt.receipt_id
    end

    test "data survives a real EKV process restart against the same data_dir" do
      ekv_name = :"ash_a2a_receipt_ekv_restart_test_#{System.unique_integer([:positive])}"

      data_dir =
        Path.join(
          System.tmp_dir!(),
          "ash_a2a_receipt_store_ekv_restart_test_#{System.unique_integer([:positive])}"
        )

      on_exit(fn -> File.rm_rf!(data_dir) end)

      ekv_opts = [name: ekv_name, data_dir: data_dir, cluster_size: 1]
      store_opts = [name: ekv_name]
      # EKV.child_spec/1 derives id: {EKV, name} -- unique per this test's
      # unique_integer-suffixed ekv_name, and the same id used below to stop
      # and restart the exact same logical child.
      child_id = {EKV, ekv_name}

      pid1 = start_supervised!({EKV, ekv_opts})
      command = real_command("ekv-restart-survives-1")

      assert {:execute, execution_id} = Ekv.claim(command, store_opts)
      receipt = real_receipt(command, execution_id)
      assert :ok = Ekv.commit(receipt, store_opts)

      # Stop the real EKV process entirely (not just the logical entry) and
      # start a brand new one against the same real on-disk data_dir --
      # proving persistence is on disk, not just in this process's memory.
      :ok = stop_supervised(child_id)
      refute Process.alive?(pid1)

      start_supervised!({EKV, ekv_opts})

      assert {:ok, fetched} = Ekv.fetch(command.command_id, store_opts)
      assert fetched.receipt_id == receipt.receipt_id
    end
  end

  describe "standing marking via a real AshA2A.CommandBus.run/4 call" do
    test "a receipt committed through AshA2A.ReceiptStore.Ekv ends up standing: :durable", %{
      store_opts: store_opts
    } do
      command =
        Command.new("AshA2A.Test.Fixture.Echo.read",
          command_id: "ekv-command-bus-durable-1",
          agent_id: "agent-1",
          principal_id: "anonymous",
          input: %{}
        )

      message = data_message(%{})

      assert {:ok, receipt} =
               CommandBus.run(command, message, Echo, store: Ekv, store_opts: store_opts)

      assert receipt.standing == :durable
      assert receipt.status == :completed

      assert {:ok, stored} = Ekv.fetch(command.command_id, store_opts)
      assert stored.standing == :durable
    end

    test "a receipt committed through the default AshA2A.ReceiptStore.Memory still ends up standing: :observed (no regression)" do
      name = Module.concat(__MODULE__, "MemoryStore#{System.unique_integer([:positive])}")
      start_supervised!({Memory, name: name})

      command =
        Command.new("AshA2A.Test.Fixture.Echo.read",
          command_id: "memory-command-bus-observed-1",
          agent_id: "agent-1",
          principal_id: "anonymous",
          input: %{}
        )

      message = data_message(%{})

      assert {:ok, receipt} =
               CommandBus.run(command, message, Echo, store: Memory, store_opts: [name: name])

      assert receipt.standing == :observed
      assert receipt.status == :completed

      assert {:ok, stored} = Memory.fetch(command.command_id, name: name)
      assert stored.standing == :observed
    end
  end
end

# --- SECTION 3: Original test/ash_a2a/reconciliation_mape_k_test.exs ---
# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshA2A.Reconciliation.MapeKTest do
  @moduledoc """
  Real MAPE-K loop over a real `AshA2A.ReceiptStore.Memory` and a real
  filesystem outbox. Asserts final durable state and the Knowledge map; no
  mocks. The probe is a plain function reading a real Agent-held external
  ledger (a real collaborator, not an interaction verifier).
  """
  use ExUnit.Case, async: false

  @moduletag :serial
  @moduletag :serial_shard
  @moduletag :tmp_dir

  alias AshA2A.{Command, Receipt, ReceiptOutbox, Reconciliation}
  alias AshA2A.Reconciliation.MapeK
  alias AshA2A.ReceiptStore.Memory

  setup %{tmp_dir: dir} do
    previous = Application.get_env(:ash_a2a, :receipt_outbox_dir)
    Application.put_env(:ash_a2a, :receipt_outbox_dir, Path.join(dir, "outbox"))
    on_exit(fn -> Application.put_env(:ash_a2a, :receipt_outbox_dir, previous) end)
    name = :"mapek_store_#{System.unique_integer([:positive])}"
    start_supervised!({Memory, name: name})
    %{opts: [name: name]}
  end

  defp anchor(opts) do
    command =
      Command.new("AshA2A.Chicago.Fixtures.ChaosReconciliation.Effect.apply_effect",
        command_id: "mapek-#{System.unique_integer([:positive])}",
        agent_id: "a",
        principal_id: "p",
        input: %{}
      )

    {:execute, execution_id} = Memory.claim(command, opts)
    receipt = Receipt.pending(command, execution_id, :external_do)
    :ok = ReceiptOutbox.append(receipt)
    {command.command_id, receipt}
  end

  test "loop resolves pending anchors via the probe and records Knowledge", %{opts: opts} do
    {id1, r1} = anchor(opts)
    {id2, _r2} = anchor(opts)
    unseen = AshA2A.Identity.command("mapek-unseen-#{System.unique_integer([:positive])}")

    {:ok, ledger} = Agent.start_link(fn -> MapSet.new([r1.receipt_id]) end)

    probe = fn receipt ->
      if Agent.get(ledger, &MapSet.member?(&1, receipt.receipt_id)),
        do: {:executed, %{"seen" => true}},
        else: {:not_executed, %{"seen" => false}}
    end

    assert {:ok, k} = MapeK.run([id1, id2, unseen], Memory, opts, probe: probe)

    assert %{state: :reconciled, settled?: true} = k[id1.value]
    assert %{state: :reconciled, settled?: true} = k[id2.value]
    assert %{state: :not_attempted, settled?: true, plans: []} = k[unseen.value]
    assert [:reconcile] = k[id1.value].plans

    # Final durable state, independently read.
    assert {:ok, %{state: :reconciled, resolved_as: :executed}} =
             Reconciliation.classify(id1, Memory, opts)

    assert {:ok, %{state: :reconciled, resolved_as: :not_executed}} =
             Reconciliation.classify(id2, Memory, opts)
  end

  test "without a probe the loop defers and never infers an outcome", %{opts: opts} do
    {id, _} = anchor(opts)
    assert {:ok, k} = MapeK.run([id], Memory, opts, max_iterations: 2)
    assert %{state: :prepared_unknown_outcome, settled?: false} = k[id.value]

    assert {:ok, %{state: :prepared_unknown_outcome}} =
             Reconciliation.classify(id, Memory, opts)
  end
end

# --- SECTION 4: Original test/ash_a2a/rfc004_agent_scope_test.exs ---
# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshA2A.Test.Rfc004.Scope.Item do
  @moduledoc "Real fixture resource for RFC-SA2A-004 S21 agent-scope tests."

  use Ash.Resource,
    domain: AshA2A.Test.Rfc004.Scope.Domain,
    data_layer: Ash.DataLayer.Ets,
    extensions: [AshA2A]

  attributes do
    uuid_primary_key(:id)
    attribute(:label, :string, public?: true, allow_nil?: false)
  end

  actions do
    defaults([:read, create: [:label]])

    action :peek, :map do
      run(fn _input, _context -> {:ok, %{peeked: true}} end)
    end
  end

  a2a do
    semantic_requests(true)
    skill(:create_item, :create)
    skill(:list_items, :read)
    skill(:peek, :peek, consequence: :observe)
  end
end

defmodule AshA2A.Test.Rfc004.Scope.Domain do
  @moduledoc false
  use Ash.Domain, extensions: [AshA2A]

  resources do
    resource(AshA2A.Test.Rfc004.Scope.Item)
  end
end

defmodule AshA2A.Test.Rfc004.Scope.Agent do
  @moduledoc false
  use AshA2A.Agent,
    resource_or_domain: AshA2A.Test.Rfc004.Scope.Item,
    name: "rfc004_scope_agent",
    strict_observe_generic_actions: true
end

defmodule AshA2A.Test.Rfc004.Scope.OptInAgent do
  @moduledoc false
  use AshA2A.Agent,
    resource_or_domain: AshA2A.Test.Rfc004.Scope.Item,
    name: "rfc004_scope_optin_agent",
    strict_observe_generic_actions: true,
    observe_generic_actions: [:peek]
end

defmodule AshA2A.Rfc004AgentScopeTest do
  @moduledoc """
  RFC-SA2A-004 S21 (agent lane): continuation lookup is scoped to the
  verified principal, and a generic `:action` declared `consequence:
  :observe` is not silently dispatched unless explicitly opted in.

  Real collaborators throughout: real agent GenServers, real
  `CommandBus`/`ReceiptStore`/`PackageStore`. The only injected seam is the
  sanctioned `Compiler.compile/3` `generate_object` seam used to build the
  stored package without a live network LLM call (see
  `ash_a2a_agent_semantic_replan_test.exs`).
  """

  use ExUnit.Case, async: false

  @moduletag :serial
  @moduletag :serial_shard
  import AshA2A.Test.MessageHelpers

  alias AshA2A.Semantic.{Compiler, ExecutionPackage, PackageStore}
  alias AshA2A.Test.Rfc004.Scope.{Agent, Item, OptInAgent}

  setup do
    AshA2A.Test.AuthorityGrantCase.grant!([
      {"scope-a", Item, ["create_item"]},
      {"scope-b", Item, ["create_item"]}
    ])

    {_sup, _registry} =
      AshA2A.Test.AgentSupervisorCase.start_supervised_agents!(__MODULE__, [Agent, OptInAgent])

    :ok
  end

  defp auth(identity), do: [metadata: %{"a2a.auth" => %{identity: identity}}]

  defp compile_package!(text, owner_identity) do
    extract = fn _, _, _, _ -> {:ok, extraction()} end
    plan = fn _, _, _, _ -> {:ok, plan_envelope()} end

    assert {:ok, %ExecutionPackage{} = package} =
             Compiler.compile(Item, text, generate_object: extract, plan_generate_object: plan)

    package = AshA2A.Agent.__bind_package__(package, owner_identity)
    :ok = PackageStore.put(package)
    package
  end

  defp extraction do
    AshA2A.Semantic.IR.fields()
    |> Map.new(&{Atom.to_string(&1), []})
    |> Map.put("authority", "none")
    |> Map.put("goals", [
      %{
        "id" => "create-a-labeled-item",
        "kind" => "goal",
        "description" => "create a labeled item",
        "source_quote" => "create a labeled item"
      }
    ])
  end

  defp plan_envelope do
    %{
      "request_id" => "rfc004-scope-plan-#{System.unique_integer([:positive])}",
      "authority" => "none",
      "capability_ids" => [AshA2A.CapabilityIndex.Compiler.capability_id(Item, :create)],
      "hddl" => "(:task create-item)",
      "fond" => "(:policy observe-or-replan)",
      "rationale" => "create the item, then observe the real outcome"
    }
  end

  defp close_as(identity, fingerprint) do
    message =
      data_message(%{"label" => "widget"}, %{
        metadata: %{skill: "create_item", continuation_fingerprint: fingerprint}
      })

    {:ok, task} = Agent.call(Agent, message, auth(identity))
    task
  end

  defp replan_as(identity, fingerprint) do
    message =
      data_message(%{}, %{
        metadata: %{semantic_request: true, continuation_fingerprint: fingerprint}
      })

    {:ok, task} = Agent.call(Agent, message, auth(identity) ++ [timeout: 170_000])
    task
  end

  defp error_text(%{status: %{message: %AshA2A.Protocol.Message{} = m}}),
    do: AshA2A.Protocol.Message.text(m)

  defp error_text(_), do: nil

  test "principal B cannot replan principal A's continuation; refusal equals not-found" do
    package = compile_package!("create a labeled item (scope)", "scope-a")
    assert close_as("scope-a", package.fingerprint).status.state == :completed

    foreign = replan_as("scope-b", package.fingerprint)
    absent = replan_as("scope-b", String.duplicate("0", 64))

    assert foreign.status.state == :failed
    assert error_text(foreign) =~ "continuation_receipt_not_found"
    # Indistinguishable from a fingerprint that never existed (modulo the echoed fingerprint).
    assert error_text(absent) =~ "continuation_receipt_not_found"
    refute error_text(foreign) =~ "continuation_package_not_found"
  end

  test "principal B holding its own receipt still cannot use A's stored package" do
    package = compile_package!("create a labeled item (scope, own receipt)", "scope-a")
    # B commits a receipt under the same fingerprint (command_id) as itself.
    assert close_as("scope-b", package.fingerprint).status.state == :completed

    task = replan_as("scope-b", package.fingerprint)
    assert task.status.state == :failed
    assert error_text(task) =~ "continuation_package_not_found"
  end

  test "an unbound (no principal) stored package is refused for every principal" do
    extract = fn _, _, _, _ -> {:ok, extraction()} end
    plan = fn _, _, _, _ -> {:ok, plan_envelope()} end

    {:ok, package} =
      Compiler.compile(Item, "create a labeled item (unbound)",
        generate_object: extract,
        plan_generate_object: plan
      )

    :ok = PackageStore.put(package)
    assert close_as("scope-a", package.fingerprint).status.state == :completed

    task = replan_as("scope-a", package.fingerprint)
    assert task.status.state == :failed
    assert error_text(task) =~ "continuation_package_not_found"
  end

  test "principal A still resolves its own continuation (never a continuation_* refusal)" do
    package = compile_package!("create a labeled item (scope, owner)", "scope-a")
    assert close_as("scope-a", package.fingerprint).status.state == :completed

    # The exact principal-scoped lookup the real replan performs before
    # re-synthesis (no live LLM): A resolves its own receipt AND package.
    assert {:ok, receipt, resolved} =
             AshA2A.Agent.__resolve_continuation__(package.fingerprint, "scope-a")

    assert receipt.command_id == AshA2A.Identity.command(package.fingerprint)
    assert receipt.principal_id == AshA2A.Identity.principal("scope-a")
    assert resolved.fingerprint == package.fingerprint

    # ... while the very same fingerprint is not-found for B (same lookup).
    assert {:error, %{code: :continuation_receipt_not_found}} =
             AshA2A.Agent.__resolve_continuation__(package.fingerprint, "scope-b")
  end

  test "a generic :action declared :observe is refused unless explicitly opted in" do
    message = data_message(%{}, %{metadata: %{skill: "peek"}})

    {:ok, refused} = Agent.call(Agent, message, auth("scope-a"))
    # v1.0: admission-phase refusal is :rejected, not :failed.
    assert refused.status.state == :rejected
    assert error_text(refused) =~ "consequence_unclassified"

    {:ok, allowed} = OptInAgent.call(OptInAgent, message, auth("scope-a"))
    assert allowed.status.state == :completed
  end

  test "a :read skill declared observe by default is unaffected" do
    message = data_message(%{}, %{metadata: %{skill: "list_items"}})
    {:ok, task} = Agent.call(Agent, message, auth("scope-a"))
    assert task.status.state == :completed
  end
end

# --- SECTION 5: Original test/ash_a2a/rfc004_authority_effect_kill_test.exs ---
# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshA2A.Rfc004AuthorityEffectKillTest.TripOnConfirmStore do
  @moduledoc """
  A real `AshA2A.ReceiptStore` (it delegates every callback to the real
  `ReceiptStore.Memory`) that additionally trips a real `AshA2A.KillSwitch`
  class at `confirm_claim/3` -- the store call that runs strictly AFTER the
  bus's initial kill-switch check and the pre-DO anchor, and strictly BEFORE
  DO. It is how a test puts an operator's "trip" in the pre-DO window without
  faking the bus.
  """
  @behaviour AshA2A.ReceiptStore

  alias AshA2A.ReceiptStore.Memory

  @impl true
  defdelegate claim(command, opts), to: Memory
  @impl true
  defdelegate commit(receipt, opts), to: Memory
  @impl true
  defdelegate fetch(command_id, opts), to: Memory
  @impl true
  defdelegate claim_actuation(actuation, command, opts), to: Memory
  @impl true
  defdelegate commit_actuation(actuation, receipt, opts), to: Memory
  @impl true
  defdelegate release_actuation(actuation, opts), to: Memory

  @impl true
  def confirm_claim(command_id, execution_id, opts) do
    :ok = AshA2A.KillSwitch.trip(Keyword.fetch!(opts, :trip_class), :tripped_pre_do)
    Memory.confirm_claim(command_id, execution_id, opts)
  end
end

defmodule AshA2A.Rfc004AuthorityEffectKillTest.NoVerifyBroker do
  @moduledoc "A module that is a broker in name only: exports neither verify/2 nor granted?/3."
  def issue(_subject, _capability, _opts), do: {:error, :never}
end

defmodule AshA2A.Rfc004AuthorityEffectKillTest do
  @moduledoc """
  RFC-SA2A-004 S10/S11 witnesses, real collaborators only: the real
  `AshA2A.Authority.Broker.InMemory` (configured in config/test.exs), the real
  `AshA2A.KillSwitch`, the real Memory receipt store, and the real
  `CountingActuator` whose counter is the state assertion for "DO did not run".
  """
  use ExUnit.Case, async: false

  @moduletag :serial
  @moduletag :serial_shard
  import AshA2A.Test.MessageHelpers

  alias AshA2A.{Authority, Command, CommandBus, Identity, KillSwitch}
  alias AshA2A.Authority.Broker.InMemory
  alias AshA2A.Test.Fixture.{CountingActuator, KeyedActuationCounter}

  @capability "AshA2A.Test.Fixture.CountingActuator.actuate"

  setup do
    Application.put_env(:ash_a2a, :receipt_commit_retry_delays_ms, [1, 1])

    on_exit(fn ->
      Application.delete_env(:ash_a2a, :receipt_commit_retry_delays_ms)
      Application.delete_env(:ash_a2a, :kill_switch_class)
    end)

    start_supervised!(KeyedActuationCounter)
    memory = Module.concat(__MODULE__, "Store#{System.unique_integer([:positive])}")
    start_supervised!({AshA2A.ReceiptStore.Memory, name: memory})
    %{store_opts: [name: memory]}
  end

  defp uniq(prefix), do: "#{prefix}-#{System.unique_integer([:positive])}"

  defp command(command_id, key, authority_opts) do
    principal = Identity.principal("rfc004-principal")
    authority = Authority.new(principal, @capability, authority_opts)

    Command.new(@capability,
      command_id: command_id,
      agent_id: "rfc004-agent",
      principal_id: principal,
      authority: authority,
      input: %{effect_key: key}
    )
  end

  defp run(command, key, store_opts, extra \\ []) do
    CommandBus.run(
      command,
      data_message(%{"effect_key" => key}),
      CountingActuator,
      Keyword.merge([store_opts: store_opts], extra)
    )
  end

  test "authority revoked at the broker before DO is refused with a typed refusal and DO never runs",
       %{store_opts: store_opts} do
    key = uniq("revoked")
    cmd = command(uniq("cmd"), key, token_id: uniq("tok"))

    # Struct-level admission still passes (unexpired, matching); only the
    # authoritative broker knows the grant is gone.
    assert Authority.admits?(cmd.authority, cmd)
    assert :ok = InMemory.revoke(cmd.authority)

    assert {:error, %{code: :authority_revoked, receipt: receipt}} = run(cmd, key, store_opts)
    assert KeyedActuationCounter.count(key) == 0
    assert receipt.command_id == cmd.command_id

    # The claim was closed with a receipt, so it is not left in flight.
    assert {:ok, stored} = AshA2A.ReceiptStore.Memory.fetch(cmd.command_id, store_opts)
    assert stored.receipt_id == receipt.receipt_id
  end

  test "an already-expired authority is refused at initial admission and DO never runs", %{
    store_opts: store_opts
  } do
    key = uniq("expired")

    cmd =
      command(uniq("cmd"), key,
        token_id: uniq("tok"),
        expires_at: DateTime.add(DateTime.utc_now(), -5, :second)
      )

    assert {:error, %{code: code}} = run(cmd, key, store_opts)
    assert code in [:authority_mismatch, :authority_expired]
    assert KeyedActuationCounter.count(key) == 0
  end

  test "a declared authority input constraint the command does not satisfy is refused at admission",
       %{store_opts: store_opts} do
    key = uniq("constraint")

    wrong = command(uniq("cmd"), key, constraints: %{input: %{effect_key: "someone-else"}})
    assert {:error, %{code: :authority_mismatch}} = run(wrong, key, store_opts)
    assert KeyedActuationCounter.count(key) == 0

    right = command(uniq("cmd"), key, constraints: %{input: %{effect_key: key}})
    assert {:ok, receipt} = run(right, key, store_opts)
    assert receipt.terminal_status == :executed
    assert KeyedActuationCounter.count(key) == 1
  end

  test "a fresh request (new command id) for the same effect cannot cross DO twice under the default mode",
       %{store_opts: store_opts} do
    key = uniq("dup")
    assert CommandBus.actuation_dedup_mode() == :strict

    assert {:ok, _} = run(command(uniq("a"), key, token_id: "dup-auth"), key, store_opts)
    assert {:ok, second} = run(command(uniq("b"), key, token_id: "dup-auth"), key, store_opts)

    assert KeyedActuationCounter.count(key) == 1
    assert second.metadata.outcome == :deduplicated
  end

  test "kill switch named only via Application env refuses the CommandBus path", %{
    store_opts: store_opts
  } do
    class = uniq("env-class")
    Application.put_env(:ash_a2a, :kill_switch_class, class)
    assert :ok = KillSwitch.trip(class, :incident_env)

    key = uniq("ks")
    cmd = command(uniq("cmd"), key, token_id: uniq("tok"))

    assert {:error, %{code: :kill_switch_tripped, detail: :incident_env}} =
             run(cmd, key, store_opts)

    assert KeyedActuationCounter.count(key) == 0
    assert :error = AshA2A.ReceiptStore.Memory.fetch(cmd.command_id, store_opts)
  end

  test "un-tripped env kill switch class lets the command proceed", %{store_opts: store_opts} do
    class = uniq("env-clear")
    Application.put_env(:ash_a2a, :kill_switch_class, class)

    key = uniq("ks-clear")
    assert {:ok, _} = run(command(uniq("cmd"), key, token_id: uniq("tok")), key, store_opts)
    assert KeyedActuationCounter.count(key) == 1
  end

  test "kill switch tripped AFTER the initial check but BEFORE DO is re-checked and refuses with zero DO",
       %{store_opts: store_opts} do
    class = uniq("trip-window")
    key = uniq("ks-window")
    cmd = command(uniq("cmd"), key, token_id: uniq("tok"))

    # Untripped at admission: the initial check passes. The store trips the
    # class during confirm_claim, i.e. inside the pre-DO window.
    refute KillSwitch.tripped?(class)

    assert {:error, %{code: :kill_switch_tripped, receipt: receipt}} =
             CommandBus.run(
               cmd,
               data_message(%{"effect_key" => key}),
               CountingActuator,
               store: AshA2A.Rfc004AuthorityEffectKillTest.TripOnConfirmStore,
               store_opts: Keyword.put(store_opts, :trip_class, class),
               kill_switch_class: class
             )

    assert KillSwitch.tripped?(class)
    assert KeyedActuationCounter.count(key) == 0
    assert receipt.command_id == cmd.command_id
  end

  test "a broker that cannot be consulted before DO fails closed with :authority_revalidation_unavailable",
       %{store_opts: store_opts} do
    # (a) a module exporting neither verify/2 nor granted?/3
    key = uniq("noverify")
    cmd = command(uniq("cmd"), key, token_id: uniq("tok"))

    assert {:error, %{code: :authority_revalidation_unavailable, receipt: %{}}} =
             run(cmd, key, store_opts,
               authority_broker: AshA2A.Rfc004AuthorityEffectKillTest.NoVerifyBroker
             )

    assert KeyedActuationCounter.count(key) == 0

    # (b) a real InMemory broker whose process is not running (GenServer exit)
    key2 = uniq("deadbroker")
    cmd2 = command(uniq("cmd"), key2, token_id: uniq("tok"))

    assert {:error, %{code: :authority_revalidation_unavailable}} =
             run(cmd2, key2, store_opts,
               authority_broker: {InMemory, [name: :rfc004_no_such_broker_process]}
             )

    assert KeyedActuationCounter.count(key2) == 0
  end

  test "a STANDING broker grant is revalidated with granted?/3: proceeds while standing, refused once revoked",
       %{store_opts: store_opts} do
    subject = Identity.principal(uniq("standing-principal"))
    assert {:ok, _} = AshA2A.Authority.Grant.grant(subject, @capability)

    authority = AshA2A.Authority.Grant.authorize(subject.value, @capability)
    assert authority.admitted_by

    build = fn id, key ->
      Command.new(@capability,
        command_id: id,
        agent_id: "rfc004-agent",
        principal_id: subject,
        authority: authority,
        input: %{effect_key: key}
      )
    end

    key1 = uniq("standing-ok")
    assert {:ok, receipt} = run(build.(uniq("cmd"), key1), key1, store_opts)
    assert receipt.terminal_status == :executed
    assert KeyedActuationCounter.count(key1) == 1

    assert :ok = AshA2A.Authority.Grant.revoke(subject, @capability)

    key2 = uniq("standing-revoked")

    assert {:error, %{code: :authority_revoked}} =
             run(build.(uniq("cmd"), key2), key2, store_opts)

    assert KeyedActuationCounter.count(key2) == 0
  end
end

# --- SECTION 6: Original test/ash_a2a/rfc004_fence_test.exs ---
# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshA2A.RFC004FenceTest do
  @moduledoc "RFC-SA2A-004 §11.4/§21: forged resolved_skill and forged anchors are refused."
  use ExUnit.Case, async: false

  alias AshA2A.{Authority, BrceAnchor, Command, Dispatcher, Identity, Receipt, ReceiptOutbox}
  alias AshA2A.Chicago.Fixtures.Brce, as: Fx
  alias AshA2A.Chicago.Fixtures.Brce.Ledger

  setup do
    BrceAnchor.clear()
    on_exit(&BrceAnchor.clear/0)
    {:ok, record} = AshA2A.Info.skill(Ledger, :record)
    %{record: record}
  end

  test "forged resolved_skill is refused before the action runs", %{record: record} do
    label = "rfc004-forged-skill-#{System.unique_integer([:positive])}"
    anchor = anchor(record.id)
    :ok = ReceiptOutbox.append(anchor)
    on_exit(fn -> ReceiptOutbox.remove(anchor) end)
    forged = %{record | consequence: :observe}
    :ok = BrceAnchor.put(anchor)

    assert {:error,
            {:skill_lookup, %{code: :capability_mismatch, reason: :resolved_skill_not_in_index}}} =
             Dispatcher.dispatch(:record, message(label), Ledger, [], nil, resolved_skill: forged)

    refute label in Fx.ledger_labels()
  end

  test "forged anchor with no outbox entry is refused", %{record: record} do
    label = "rfc004-forged-anchor-#{System.unique_integer([:positive])}"
    :ok = BrceAnchor.put(anchor(record.id))

    assert {:error,
            {:brce_gate, %{code: :brce_prepared_receipt_required, reason: :anchor_not_durable}}} =
             Dispatcher.dispatch(:record, message(label), Ledger)

    refute label in Fx.ledger_labels()
  end

  test "legitimate path dispatches exactly once", %{record: record} do
    label = "rfc004-legit-#{System.unique_integer([:positive])}"
    anchor = anchor(record.id)
    :ok = ReceiptOutbox.append(anchor)
    on_exit(fn -> ReceiptOutbox.remove(anchor) end)
    :ok = BrceAnchor.put(anchor)

    # A consequence-bearing dispatch is admitted only inside the kernel's dispatcher fence
    # (the W4 DispatchInversion entry), and only with the durable anchor.
    assert {:reply, _} =
             AshA2A.ConsequenceKernel.Dispatch.DispatcherFence.enter(fn ->
               Dispatcher.dispatch(:record, message(label), Ledger, [], nil,
                 resolved_skill: record
               )
             end)

    assert Enum.count(Fx.ledger_labels(), &(&1 == label)) == 1
  end

  test "a durably anchored dispatch outside the kernel fence is refused before the action runs",
       %{record: record} do
    label = "rfc004-nofence-#{System.unique_integer([:positive])}"
    anchor = anchor(record.id)
    :ok = ReceiptOutbox.append(anchor)
    on_exit(fn -> ReceiptOutbox.remove(anchor) end)
    :ok = BrceAnchor.put(anchor)

    assert {:error, {:kernel_fence, :consequence_kernel_required}} =
             Dispatcher.dispatch(:record, message(label), Ledger, [], nil, resolved_skill: record)

    refute label in Fx.ledger_labels()
  end

  defp anchor(capability_id) do
    principal = Identity.principal("rfc004-fence-test")

    command =
      Command.new(capability_id,
        command_id: "rfc004-fence-" <> Ash.UUIDv7.generate(),
        agent_id: "rfc004-fence-agent",
        principal_id: principal,
        authority: Authority.new(principal, capability_id),
        input: %{"label" => "anchor"}
      )

    Receipt.pending(command, Identity.execution(Ash.UUIDv7.generate()), :change)
  end

  defp message(label),
    do: AshA2A.Protocol.Message.new_user([AshA2A.Protocol.Part.Data.new(%{"label" => label})])
end

# --- SECTION 7: Original test/ash_a2a/rfc004_outbox_integrity_test.exs ---
# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshA2A.RFC004OutboxIntegrityTest do
  @moduledoc "RFC-SA2A-004 section 12: integrity-protected prepare journal."
  use ExUnit.Case, async: false

  @moduletag :serial

  alias AshA2A.{Command, Identity, Receipt, ReceiptOutbox, ReceiptStore}

  setup do
    dir = Path.join(System.tmp_dir!(), "outbox_integrity_#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)

    saved =
      for k <- [:receipt_outbox_dir, :receipt_outbox_key, :receipt_binding_key],
          do: {k, Application.fetch_env(:ash_a2a, k)}

    Application.put_env(:ash_a2a, :receipt_outbox_dir, dir)
    Application.delete_env(:ash_a2a, :receipt_outbox_key)
    Application.delete_env(:ash_a2a, :receipt_binding_key)

    on_exit(fn ->
      for {k, v} <- saved do
        case v do
          {:ok, val} -> Application.put_env(:ash_a2a, k, val)
          :error -> Application.delete_env(:ash_a2a, k)
        end
      end

      File.rm_rf!(dir)
    end)

    {:ok, dir: dir}
  end

  defp receipt do
    command = %Command{
      command_id: Identity.command("rfc004-outbox-#{System.unique_integer([:positive])}"),
      agent_id: Identity.agent("agent"),
      principal_id: Identity.principal("principal"),
      capability_id: Identity.runtime("cap"),
      input: %{},
      submitted_at: DateTime.utc_now(),
      fingerprint: "fp"
    }

    Receipt.pending(command, Identity.execution(Ash.UUIDv7.generate()), :external_do)
  end

  defp new_store do
    name = Module.concat(__MODULE__, "S#{System.unique_integer([:positive])}")
    {:ok, _} = GenServer.start(ReceiptStore.Memory, %{}, name: name)
    [name: name]
  end

  test "keyed append + reconcile round-trips" do
    Application.put_env(:ash_a2a, :receipt_outbox_key, "k1-secret")
    r = receipt()
    assert :ok = ReceiptOutbox.append(r)
    assert [%Receipt{}] = ReceiptOutbox.entries()

    assert {:ok, %{committed: 1, remaining: 0}} =
             ReceiptOutbox.reconcile(ReceiptStore.Memory, new_store())

    assert ReceiptOutbox.count() == 0
  end

  test "well-formed forged entry planted without the key is refused under a key" do
    r = receipt()
    # Planted while no key is configured (an attacker's write path).
    assert :ok = ReceiptOutbox.append(r)
    Application.put_env(:ash_a2a, :receipt_outbox_key, "k1-secret")

    opts = new_store()

    assert {:ok, %{committed: 0, remaining: 1}} =
             ReceiptOutbox.reconcile(ReceiptStore.Memory, opts)

    assert {:error, :not_found} = ReceiptStore.Memory.fetch(r.command_id, opts) |> normalize()
    assert [{_file, :outbox_untagged_entry}] = ReceiptOutbox.corrupt_entries()
    assert ReceiptOutbox.entries() == []
  end

  test "raw legacy term bytes are refused under a key" do
    r = receipt()
    File.mkdir_p!(ReceiptOutbox.dir())

    File.write!(
      ReceiptOutbox.entry_path_for(r.command_id, r.receipt_id),
      :erlang.term_to_binary({1, r})
    )

    Application.put_env(:ash_a2a, :receipt_binding_key, "binding-key")

    assert {:ok, %{committed: 0, remaining: 1}} =
             ReceiptOutbox.reconcile(ReceiptStore.Memory, new_store())
  end

  test "tampered bytes are refused" do
    Application.put_env(:ash_a2a, :receipt_outbox_key, "k1-secret")
    r = receipt()
    :ok = ReceiptOutbox.append(r)
    path = ReceiptOutbox.entry_path_for(r.command_id, r.receipt_id)
    bytes = File.read!(path)
    keep = byte_size(bytes) - 1
    <<head::binary-size(^keep), last>> = bytes
    File.write!(path, <<head::binary, Bitwise.bxor(last, 1)>>)

    assert [{_file, reason}] = ReceiptOutbox.corrupt_entries()
    assert reason in [:outbox_bad_tag]

    assert {:ok, %{committed: 0, remaining: 1}} =
             ReceiptOutbox.reconcile(ReceiptStore.Memory, new_store())
  end

  test "entry tagged under a different key is refused" do
    Application.put_env(:ash_a2a, :receipt_outbox_key, "k1-secret")
    :ok = ReceiptOutbox.append(receipt())
    Application.put_env(:ash_a2a, :receipt_outbox_key, "other-key")
    assert [{_f, :outbox_bad_tag}] = ReceiptOutbox.corrupt_entries()
  end

  test "no key: dev/test still round-trips" do
    r = receipt()
    assert :ok = ReceiptOutbox.append(r)
    assert ReceiptOutbox.anchored?(r)

    assert {:ok, %{committed: 1, remaining: 0}} =
             ReceiptOutbox.reconcile(ReceiptStore.Memory, new_store())
  end

  defp normalize({:ok, _} = ok), do: ok
  defp normalize(_), do: {:error, :not_found}
end

# --- SECTION 8: Original test/ash_a2a/rfc004_spg_independence_test.exs ---
# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshA2A.Rfc004SpgIndependenceTest do
  use ExUnit.Case, async: true

  alias AshA2A.SpgConformance

  defp temp_corpus do
    dir = Path.join(System.tmp_dir!(), "spg_corpus_#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    File.cp_r!(SpgConformance.corpus_dir(), dir)
    on_exit(fn -> File.rm_rf!(dir) end)
    dir
  end

  test "committed corpus digest pin verifies against the shipped corpus" do
    assert {:ok, "sha256:" <> _} = SpgConformance.verify_pinned()
  end

  test "mutating a case in a real temp copy changes the digest and is refused" do
    dir = temp_corpus()
    assert {:ok, digest} = SpgConformance.verify_pinned(dir)

    path = Path.join(dir, "001_exact_subject_match.json")
    mutated = path |> SpgConformance.load_file!() |> put_in(["replay", "seed"], 999)
    File.write!(path, JSON.encode!(mutated))

    assert {:error, {:corpus_digest_mismatch, ^digest, actual}} =
             SpgConformance.verify_pinned(dir)

    refute actual == digest
  end

  test "missing pin is refused" do
    assert {:error, {:corpus_pin_unreadable, :enoent}} =
             SpgConformance.verify_pinned(SpgConformance.corpus_dir(), "/nonexistent/pin")
  end

  test "independent evaluator agrees with every admit fixture in independent families" do
    cases = SpgConformance.load_all()
    report = SpgConformance.independent_report(cases)

    independent = SpgConformance.independent_families()
    admits = Enum.filter(cases, &(&1["family"] in independent and &1["expect"] == "admit"))
    assert length(admits) > 0

    assert Enum.all?(admits, fn c ->
             match?({:admit, _}, SpgConformance.independent_evaluator(c))
           end)

    assert report.evaluated == Enum.count(cases, &(&1["family"] in independent))
    assert report.evaluated == length(report.agree) + length(report.disagree)
  end

  test "FINDING: refuse fixtures carry no concrete witness, independent evaluator admits them" do
    cases = SpgConformance.load_all()
    report = SpgConformance.independent_report(cases)

    refuse_ids =
      cases
      |> Enum.filter(
        &(&1["family"] in SpgConformance.independent_families() and &1["expect"] == "refuse")
      )
      |> Enum.map(& &1["case_id"])

    assert Enum.sort(Enum.map(report.disagree, &elem(&1, 0))) == Enum.sort(refuse_ids)

    independent = Enum.filter(cases, &(&1["family"] in SpgConformance.independent_families()))

    assert {:error, %{failures: failures}} =
             SpgConformance.run_cases(independent, &SpgConformance.independent_evaluator/1)

    assert Enum.sort(Enum.map(failures, &elem(&1, 0))) == Enum.sort(refuse_ids)
    assert Enum.all?(failures, fn {_, {:error, reason}} -> reason == :false_admission end)
  end

  test "independent evaluator refuses concrete-field violations without reading checks" do
    c =
      SpgConformance.load_file!(
        Path.join(SpgConformance.corpus_dir(), "001_exact_subject_match.json")
      )

    bad_sha = put_in(c, ["subject", "base_sha"], "xyz")

    assert {:refuse, "SPG_INDEPENDENT_IDENTITY_MISMATCH"} =
             SpgConformance.independent_evaluator(bad_sha)

    bad_proc = put_in(c, ["procedure", "identity"], "urn:ash-a2a:spg:identity:other")

    assert {:refuse, "SPG_INDEPENDENT_IDENTITY_MISMATCH"} =
             SpgConformance.independent_evaluator(bad_proc)

    no_auth = put_in(c, ["boundary", "authority_explicit"], false)

    assert {:refuse, "SPG_INDEPENDENT_AUTHORITY_UNBOUND"} =
             SpgConformance.independent_evaluator(no_auth)
  end

  test "family split is documented and covers every corpus family exactly once" do
    families = SpgConformance.load_all() |> Enum.map(& &1["family"]) |> Enum.uniq() |> Enum.sort()
    split = SpgConformance.independent_families() ++ SpgConformance.self_checked_families()
    assert Enum.sort(split) == families
  end
end

# --- SECTION 9: Original test/ash_a2a/sa2a_conformance_test.exs ---
# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshA2A.SA2AConformanceTest do
  @moduledoc """
  Real cross-runtime conformance tests.

  Every test here drives the real prebuilt `praxis-graphlaw` WASM module
  through two genuinely different real hosts -- a real `:wasmex` instance in
  this BEAM and a real OS subprocess running a real standalone JavaScript
  engine -- over the real corpus on disk, and asserts on real returned
  digests. No collaborator is mocked and no assertion is interaction-based.

  The suite skips only when the real WASM module or the real out-of-BEAM
  executable is genuinely absent from this machine, and says so by name
  rather than substituting a double.
  """

  use ExUnit.Case, async: false

  @moduletag :serial
  @moduletag :serial_solo
  alias AshA2A.GraphLaw.{Runtime, RuntimeB, WasmexSession}
  alias AshA2A.SA2A.{Conformance, ResultProjection, StateMachine, Vector}

  doctest AshA2A.GraphLaw.Runtime
  doctest AshA2A.SA2A.ResultProjection

  @moduletag :sa2a_conformance

  # Real ExUnit skip, resolved at test-module compile time: when either real
  # runtime is genuinely absent from this host, the whole module is skipped
  # with a NAMED reason (visible via `mix test --include skip`) instead of
  # green-passing through a context-key branch that asserts nothing.
  case {WasmexSession.available?([]), RuntimeB.available?([])} do
    {:ok, :ok} ->
      :ok

    {a, b} ->
      @moduletag skip:
                   "cross-runtime conformance unavailable: runtime A: #{inspect(a)}; runtime B: #{inspect(b)}"
  end

  setup_all do
    {:ok, receipt} = run_court()
    {:ok, receipt: receipt}
  end

  # `run/1` returns {:ok, receipt} on a clean run and {:error, receipt} when a
  # falsifier fired. Both carry the same receipt; these tests assert on its
  # real contents rather than on the overall verdict, so a later GraphLaw fix
  # flipping the verdict does not silently change what is being checked.
  defp run_court(opts \\ []) do
    case Conformance.run(opts) do
      {:ok, receipt} -> {:ok, receipt}
      {:error, %{"profile" => _} = receipt} -> {:ok, receipt}
      {:error, reason} -> {:error, reason}
    end
  end

  defp assertion(receipt, name), do: receipt["assertions"][Atom.to_string(name)]

  defp vectors_by_id(receipt, side) do
    Map.new(receipt[side]["vectors"], &{&1["vector"], &1})
  end

  describe "the two configured runtimes" do
    test "are genuinely different hosts, not one runtime run twice" do
      assert Runtime.identity(WasmexSession) != Runtime.identity(RuntimeB)
      assert WasmexSession.host_id() == "BEAM/Wasmex"
      assert RuntimeB.host_id() == "Node/StandaloneJS"
    end

    test "runtime B is a real out-of-BEAM process that reports its own engine", %{} = _context do
      {:ok, %{session: session, wasm_digest: digest}} = RuntimeB.open([])

      try do
        engine = RuntimeB.reported_engine(session)
        # The live subprocess named itself; this is not a constant in Elixir.
        assert engine =~ ~r/^(v8|javascriptcore)-\d/
        assert String.match?(digest, ~r/\A[0-9a-f]{64}\z/)
        assert {:ok, version} = RuntimeB.call(session, :graphlaw_version, [])
        assert version =~ "praxis-graphlaw v"
      after
        RuntimeB.close(session)
      end
    end

    test "load byte-identical wasm and report the same module digest", %{} = context do
      receipt = context.receipt
      same_wasm = assertion(receipt, :same_wasm)

      assert same_wasm["computed"]
      assert same_wasm["value"]
      assert receipt["runtime_a"]["wasm_digest"] == receipt["runtime_b"]["wasm_digest"]
      assert receipt["wasm_digest_algorithm"] == "sha256"
    end

    test "supply byte-identical deterministic entropy to the wasm import" do
      node = System.find_executable("node")

      if node do
        script = """
        const out = [];
        for (let i = 0; i < 64; i++) out.push((i * 2654435761) % 256);
        process.stdout.write(out.join(','));
        """

        {stdout, 0} = System.cmd(node, ["-e", script])

        from_out_of_beam = stdout |> String.split(",") |> Enum.map(&String.to_integer/1)
        from_beam = Runtime.deterministic_random_bytes(64) |> :binary.bin_to_list()

        # The court's digests are only comparable because both hosts fill
        # getRandomValues identically. This checks the real contract between
        # the two real implementations, not either one in isolation.
        assert from_beam == from_out_of_beam
      else
        IO.puts("skipped: no node executable on PATH")
      end
    end
  end

  describe "cross-runtime agreement over the real corpus" do
    test "the corpus is non-empty and every vector really loaded" do
      assert {:ok, vectors} = Vector.load_all([])
      assert length(vectors) >= 8
      assert Enum.all?(vectors, &(&1.base != ""))
      assert Enum.all?(vectors, &String.match?(&1.digest, ~r/\A[0-9a-f]{64}\z/))
    end

    test "wasm, admission, output semantics and evidence identity all agree", %{} = context do
      receipt = context.receipt

      for name <- [:same_wasm, :same_admission, :same_output_semantics, :same_evidence_identity] do
        result = assertion(receipt, name)
        assert result["computed"], "#{name} was not computed: #{inspect(result["detail"])}"
        assert result["value"], "#{name} failed: #{inspect(result["divergences"])}"
      end
    end

    test "every vector's output graph hash is identical across the two hosts", %{} = context do
      receipt = context.receipt
      a = vectors_by_id(receipt, "runtime_a")
      b = vectors_by_id(receipt, "runtime_b")

      for {id, va} <- a do
        vb = Map.fetch!(b, id)
        assert va["output_graph_hash"] == vb["output_graph_hash"], "diverged on #{id}"
        assert String.match?(va["output_graph_hash"], ~r/\A[0-9a-f]{64}\z/)
        assert va["evidence_hash"] == vb["evidence_hash"], "evidence diverged on #{id}"
      end
    end

    test "RFC S12: prefix relabelling and triple reordering preserve graph identity",
         %{} = context do
      receipt = context.receipt

      for side <- ["runtime_a", "runtime_b"] do
        vectors = vectors_by_id(receipt, side)
        v001 = Map.fetch!(vectors, "v001_minimal_admit")
        v002 = Map.fetch!(vectors, "v002_prefix_and_order_invariance")

        # Same abstract graph, different prefix label and reversed triple
        # order: the canonical identity must not notice.
        assert v001["input_graph_hash"] == v002["input_graph_hash"],
               "#{side} gave the same graph two identities"
      end
    end

    test "refusals agree on the S41 state reached and the typed reason", %{} = context do
      receipt = context.receipt
      a = vectors_by_id(receipt, "runtime_a")
      b = vectors_by_id(receipt, "runtime_b")

      shacl = Map.fetch!(a, "v004_shacl_min_count_violation")
      shex = Map.fetch!(a, "v009_shex_violation")

      assert shacl["admission"] == "REFUSED"
      assert shacl["refusal_reason"] =~ "STRUCTURALLY_VALID:SHACL:REFUSED"
      assert shex["admission"] == "REFUSED"
      assert shex["refusal_reason"] =~ "SEMANTICALLY_VALID:SHEX:REFUSED"

      for id <- ["v004_shacl_min_count_violation", "v009_shex_violation"] do
        assert Map.fetch!(a, id)["refusal_reason"] == Map.fetch!(b, id)["refusal_reason"]
        assert Map.fetch!(a, id)["state_reached"] == Map.fetch!(b, id)["state_reached"]
        assert Map.fetch!(a, id)["state_trace"] == Map.fetch!(b, id)["state_trace"]
      end
    end

    test "admitted vectors really walked the whole S41 prefix", %{} = context do
      admitted =
        context.receipt["runtime_a"]["vectors"]
        |> Enum.filter(&(&1["admission"] == "ADMITTED"))

      assert admitted != []

      expected = Enum.map(StateMachine.states(), &(&1 |> Atom.to_string() |> String.upcase()))

      for vector <- admitted do
        reached = Enum.map(vector["state_trace"], &List.first(String.split(&1, ["(", "="])))
        assert reached == expected, "#{vector["vector"]} took a different route to ADMITTED"
      end
    end
  end

  describe "graph_hash stability (open falsifier against praxis-graphlaw v26.7.5)" do
    @tag :falsifier
    test "ground graphs are stable and blank-node graphs are not", %{} = _context do
      {:ok, vectors} = Vector.load_all([])
      by_id = Map.new(vectors, &{&1.id, &1})
      ground = Map.fetch!(by_id, "v001_minimal_admit").base
      with_bnodes = Map.fetch!(by_id, "v006_blank_nodes").base

      {:ok, %{session: session}} = WasmexSession.open([])

      {ground_hashes, bnode_hashes} =
        try do
          g = for _ <- 1..4, do: elem(WasmexSession.call(session, :graph_hash, [ground]), 1)

          b =
            for _ <- 1..4, do: elem(WasmexSession.call(session, :graph_hash, [with_bnodes]), 1)

          {g, b}
        after
          WasmexSession.close(session)
        end

      assert Enum.uniq(ground_hashes) |> length() == 1,
             "a ground graph must have exactly one identity, got #{inspect(ground_hashes)}"

      # This assertion documents a real, currently-open defect in
      # praxis-graphlaw v26.7.5: repeated graph_hash/1 calls on the same
      # blank-node graph return different digests, so input identity is not
      # a function of the input. When the engine is fixed this test will
      # fail loudly -- which is the point. Update it together with
      # priv/sa2a_conformance_vectors/v006_blank_nodes/vector.json, do not relax it.
      assert length(Enum.uniq(bnode_hashes)) > 1,
             "blank-node graph_hash appears to have become stable " <>
               "(#{inspect(bnode_hashes)}); if praxis-graphlaw fixed this, " <>
               "remove the OPEN_FALSIFIER status from v006 and invert this assertion"
    end

    @tag :falsifier
    test "the court reports that instability instead of passing over it", %{} = context do
      result = assertion(context.receipt, :same_input_identity)

      # Both runtimes agree digit-for-digit on the unstable sequence, so a
      # cross-runtime-only check would have reported true here. It must not.
      assert result["computed"]
      refute result["value"]
      assert result["detail"] =~ "not a function of the input graph"

      divergences = result["divergences"]
      assert Enum.all?(divergences, &(&1["vector"] == "v006_blank_nodes"))

      assert divergences
             |> Enum.map(& &1["runtime"])
             |> Enum.sort() == ["BEAM/Wasmex", "Node/StandaloneJS"]

      assert context.receipt["result"] == "FAIL"
    end
  end

  describe "the court refuses degenerate runs" do
    test "refuses to run one runtime twice" do
      assert {:error, reason} =
               Conformance.run(runtime_a: WasmexSession, runtime_b: WasmexSession)

      assert reason.code == :sa2a_identical_runtimes
      assert reason.message =~ "cannot establish cross-runtime conformance"

      # The two runtimes resolved to the same module, and the refusal says so
      # by name rather than inferring it from a matching identity pair.
      assert reason.same_module
      assert reason.message =~ "resolve to the same module"

      # It refuses before any vector executes, so there is no receipt and
      # therefore no trivially-passing 5/5 to misread.
      refute is_map_key(reason, :assertions)
    end

    test "refuses two distinct modules that report the same host and engine identity" do
      # AshA2A.Test.EchoHostRuntime is a different module from WasmexSession and really
      # delegates every call to it, but reports WasmexSession's own {host_id,
      # engine_id}. That is one runtime wearing two names, and it is refused
      # on identity even though the module check does not fire.
      assert {:error, reason} =
               Conformance.run(runtime_a: WasmexSession, runtime_b: AshA2A.Test.EchoHostRuntime)

      assert reason.code == :sa2a_identical_runtimes
      refute reason.same_module
      assert reason.message =~ "same {host_id, engine_id}"
    end

    @tag :graphlaw_engine
    test "refuses an empty corpus rather than passing vacuously" do
      dir = Path.join(System.tmp_dir!(), "sa2a_empty_#{System.unique_integer([:positive])}")
      File.mkdir_p!(dir)

      try do
        assert {:error, reason} = Conformance.run(corpus_dir: dir)
        assert reason.code == :sa2a_corpus_empty
        assert reason.message =~ "cannot establish conformance"
      after
        File.rm_rf!(dir)
      end
    end

    @tag :graphlaw_engine
    test "refuses a corpus directory that does not exist" do
      assert {:error, reason} = Conformance.run(corpus_dir: "/nonexistent/sa2a/corpus")
      assert reason.code == :sa2a_corpus_not_found
    end

    test "an assertion that cannot be computed fails the run, it is not skipped",
         %{} = _context do
      # A real, genuinely degraded host: real wasm for every call except
      # graph_hash, which it really refuses. See its @moduledoc.
      #
      # Paired with the out-of-BEAM host: the degraded host executes in the
      # same in-BEAM Wasmtime engine as WasmexSession, so pairing those two
      # is refused on observed runtime identity (RFC-SA2A-002 S126) before
      # any assertion could be computed.
      assert {:error, receipt} =
               Conformance.run(
                 runtime_a: RuntimeB,
                 runtime_b: AshA2A.Test.DegradedGraphLawRuntime
               )

      input = assertion(receipt, :same_input_identity)
      output = assertion(receipt, :same_output_semantics)

      refute input["computed"]
      assert input["value"] == nil
      assert input["detail"] =~ "could not be computed"

      # The refusal names the real call that failed, in the real runtime
      # that failed it, rather than reporting a blanket absence.
      failed = Enum.flat_map(input["divergences"], & &1["failed_steps"])
      assert "graph_hash_input" in failed
      assert "BEAM/Wasmex(degraded)" in Enum.map(input["divergences"], & &1["runtime"])

      refute output["computed"]
      assert output["value"] == nil

      assert receipt["result"] == "FAIL"

      # The degraded host still really executed everything else, so the
      # failure is attributable rather than blanket.
      assert assertion(receipt, :same_wasm)["value"]
    end
  end

  describe "an engine error is never projected into a comparable value" do
    # The corpus minus v006_blank_nodes. v006 carries a real, separate, open
    # praxis-graphlaw defect (unstable blank-node graph_hash), which makes the
    # full corpus FAIL for a reason that has nothing to do with these tests.
    # On this subset two healthy runtimes really do return {:ok, "PASS"} --
    # asserted below as the control -- so a FAIL here is attributable to the
    # degradation under test and to nothing else.
    defp corpus_without_v006 do
      dir = Path.join(System.tmp_dir!(), "sa2a_no_v006_#{System.unique_integer([:positive])}")
      File.mkdir_p!(dir)

      # Read from the loader's own resolved directory rather than a hardcoded
      # path, so this helper follows the corpus wherever `Vector` puts it.
      for source <- Path.wildcard(Path.join(Vector.corpus_dir(), "*")),
          File.dir?(source),
          Path.basename(source) != "v006_blank_nodes" do
        File.cp_r!(source, Path.join(dir, Path.basename(source)))
      end

      dir
    end

    test "control: two healthy runtimes really do PASS on this corpus", %{} = _context do
      dir = corpus_without_v006()

      try do
        assert {:ok, receipt} = Conformance.run(corpus_dir: dir)
        assert receipt["result"] == "PASS"
      after
        File.rm_rf!(dir)
      end
    end

    @tag :falsifier
    test "two runtimes whose run_hooks both failed must not be reported as agreeing",
         %{} = _context do
      dir = corpus_without_v006()

      try do
        # The verifier's exact scenario. Two real, genuinely different hosts
        # -- a real :wasmex instance and a real out-of-BEAM JS subprocess --
        # each running the real wasm module for every call except
        # run_hooks/2, the one call that decides ADMITTED, which each really
        # refuses. See AshA2A.Test.HooksDegradedRuntimeA's @moduledoc.
        #
        # Before the fix this returned {:ok, receipt} with "result" =>
        # "PASS" and all five assertions computed=true value=true: both
        # hosts' failures were projected into the identical well-formed
        # %{"status" => "ABSENT"} graph, hashed to the identical digest
        # d8d7d578.., and the match was called conformance. Two hosts
        # agreeing that they both failed is not conformance.
        assert {:error, receipt} =
                 Conformance.run(
                   runtime_a: AshA2A.Test.HooksDegradedRuntimeA,
                   runtime_b: AshA2A.Test.HooksDegradedRuntimeB,
                   corpus_dir: dir
                 )

        assert receipt["result"] == "FAIL"

        for name <- [
              :same_admission,
              :same_output_semantics,
              :same_evidence_identity,
              :same_input_identity
            ] do
          result = assertion(receipt, name)

          refute result["computed"],
                 "#{name} claimed to be computed in a run where run_hooks never executed"

          # Not merely falsy: genuinely absent, so "could not tell" can
          # never be read back as "checked and it held".
          assert result["value"] == nil, "#{name} reported a truth value it never computed"
        end

        # The failure stays attributable rather than blanket: the two hosts
        # really did load the identical module, and the court still says so.
        assert assertion(receipt, :same_wasm)["computed"]
        assert assertion(receipt, :same_wasm)["value"] == true
      after
        File.rm_rf!(dir)
      end
    end

    @tag :falsifier
    test "the ABSENT projection digest appears nowhere in the receipt", %{} = _context do
      dir = corpus_without_v006()

      try do
        {:error, receipt} =
          Conformance.run(
            runtime_a: AshA2A.Test.HooksDegradedRuntimeA,
            runtime_b: AshA2A.Test.HooksDegradedRuntimeB,
            corpus_dir: dir
          )

        # The exact digest the old code manufactured, computed live here by
        # the real wasm module over the real ABSENT projection rather than
        # pasted in as a constant.
        {:ok, %{session: session}} = WasmexSession.open([])

        absent_digest =
          try do
            vector = hd(receipt["runtime_a"]["vectors"])["vector"]
            turtle = ResultProjection.hook_result_turtle(vector, %{"status" => "ABSENT"})
            {:ok, digest} = WasmexSession.call(session, :graph_hash, [turtle])
            digest
          after
            WasmexSession.close(session)
          end

        assert String.match?(absent_digest, ~r/\A[0-9a-f]{64}\z/)

        for side <- ["runtime_a", "runtime_b"], vector <- receipt[side]["vectors"] do
          refute vector["computed"],
                 "#{vector["vector"]} claimed a complete observation without run_hooks"

          assert vector["output_graph_hash"] == nil,
                 "#{side}/#{vector["vector"]} manufactured an output hash from a failure"

          refute vector["evidence_hash"] == absent_digest
          assert vector["evidence_hash"] == nil
        end

        # Nor at the rollup level: a digest over an incomplete observation
        # set is a well-formed digest of a failure.
        for side <- ["runtime_a", "runtime_b"] do
          refute receipt[side]["observations_complete"]
          assert receipt[side]["output_graph_hash"] == nil
          assert receipt[side]["evidence_hash"] == nil
          assert receipt[side]["admission_digest"] == nil
        end

        # And the whole receipt still round-trips, nulls included.
        assert {:ok, decoded} = JSON.decode(JSON.encode!(receipt))
        assert decoded["result"] == "FAIL"
      after
        File.rm_rf!(dir)
      end
    end

    @tag :falsifier
    test "a failure in one runtime alone is enough; agreement is not required to fail",
         %{} = _context do
      dir = corpus_without_v006()

      try do
        # Only runtime B's hooks are broken. The court must refuse to
        # compare, not report a divergence it did not actually observe.
        assert {:error, receipt} =
                 Conformance.run(
                   runtime_a: WasmexSession,
                   runtime_b: AshA2A.Test.HooksDegradedRuntimeB,
                   corpus_dir: dir
                 )

        assert receipt["result"] == "FAIL"
        refute assertion(receipt, :same_admission)["computed"]
        assert assertion(receipt, :same_admission)["value"] == nil

        # The healthy side is still reported as healthy, per vector.
        assert Enum.all?(receipt["runtime_a"]["vectors"], & &1["computed"])
        refute Enum.any?(receipt["runtime_b"]["vectors"], & &1["computed"])
        assert receipt["runtime_a"]["observations_complete"]
        refute receipt["runtime_b"]["observations_complete"]
      after
        File.rm_rf!(dir)
      end
    end

    test "the moduledoc claim and the real behaviour agree", %{} = _context do
      # The claim, read out of the compiled module rather than out of the
      # source file, so weakening it is what breaks this test.
      {:docs_v1, _, :elixir, _, %{"en" => doc}, _, _} = Code.fetch_docs(Conformance)

      assert doc =~ "An assertion that could not be computed is a **failure**, never a skip"
      assert doc =~ ~s(`run/1` returns `{:error, receipt}` when any of the five is absent or)

      dir = corpus_without_v006()

      try do
        # The behaviour that claim describes, measured: an absent assertion
        # really does produce {:error, _}, and the returned tuple really
        # does agree with the receipt's own verdict field.
        result =
          Conformance.run(
            runtime_a: AshA2A.Test.HooksDegradedRuntimeA,
            runtime_b: AshA2A.Test.HooksDegradedRuntimeB,
            corpus_dir: dir
          )

        assert {:error, receipt} = result
        assert receipt["result"] == "FAIL"

        all_true? =
          Enum.all?(Conformance.assertion_names(), fn name ->
            a = assertion(receipt, name)
            a["computed"] == true and a["value"] == true
          end)

        refute all_true?

        assert Enum.any?(Conformance.assertion_names(), fn name ->
                 assertion(receipt, name)["computed"] == false
               end)
      after
        File.rm_rf!(dir)
      end
    end
  end

  describe "the receipt" do
    test "carries exactly the specified top-level shape", %{} = context do
      receipt = context.receipt

      for key <- ~w(profile graphlaw_version wasm_digest root_manifest_digest
                      runtime_a runtime_b assertions) do
        assert Map.has_key?(receipt, key), "receipt is missing #{key}"
      end

      assert receipt["profile"] == "SA2A-STRICT-v26.9.20"
      assert receipt["graphlaw_version"] =~ "praxis-graphlaw v"
      assert String.match?(receipt["root_manifest_digest"], ~r/\A[0-9a-f]{64}\z/)

      for side <- ["runtime_a", "runtime_b"] do
        for key <- ~w(host input_graph_hash admission output_graph_hash evidence_hash) do
          assert Map.has_key?(receipt[side], key), "#{side} is missing #{key}"
        end
      end

      assert receipt["runtime_a"]["host"] == "BEAM/Wasmex"
      assert receipt["runtime_b"]["host"] == "Node/StandaloneJS"

      assert Map.keys(receipt["assertions"]) |> Enum.sort() ==
               Conformance.assertion_names() |> Enum.map(&Atom.to_string/1) |> Enum.sort()
    end

    test "is JSON-encodable, which is what makes it machine-readable", %{} = context do
      encoded = JSON.encode!(context.receipt)
      assert {:ok, decoded} = JSON.decode(encoded)
      assert decoded["profile"] == "SA2A-STRICT-v26.9.20"
    end

    test "both runtimes independently computed the same root manifest digest",
         %{} = context do
      receipt = context.receipt

      # Each host ran blake3_hex over the identical corpus manifest string
      # inside its own wasm instance.
      assert receipt["runtime_a"]["root_manifest_digest"] ==
               receipt["runtime_b"]["root_manifest_digest"]

      assert receipt["root_manifest_digest"] == receipt["runtime_a"]["root_manifest_digest"]
    end

    test "declares the scope it does and does not establish", %{} = context do
      scope = context.receipt["scope"]

      assert scope["stops_at"] == "ADMITTED"
      assert scope["actuation"] == "none"
      refute scope["authority_consulted"]
      refute scope["command_bus_invoked"]
      assert "universal semantic equivalence" in scope["does_not_establish"]
      assert "production readiness" in scope["does_not_establish"]
      assert "cross-implementation equivalence" in scope["does_not_establish"]
    end
  end

  describe "scope discipline: the court stops at ADMITTED" do
    test "the conformance modules reference no actuation boundary at all" do
      sources =
        for file <- [
              "lib/ash_a2a/sa2a/conformance.ex",
              "lib/ash_a2a/sa2a/state_machine.ex",
              "lib/ash_a2a/sa2a/vector.ex",
              "lib/ash_a2a/sa2a/result_projection.ex",
              "lib/ash_a2a/graph_law/wasm.ex",
              "lib/ash_a2a/graph_law/runtime_b.ex"
            ],
            do: {file, File.read!(file)}

      for {file, source} <- sources do
        # Real file contents, not a recorded call expectation: these modules
        # must not be able to actuate anything, so the names simply do not
        # appear in them outside prose saying they must not.
        code =
          source
          |> String.split("\n")
          |> Enum.reject(&String.match?(&1, ~r/^\s*(#|\|\||@moduledoc|@doc)/))
          |> Enum.join("\n")

        refute code =~ "CommandBus.", "#{file} reaches the consequence boundary"
        refute code =~ "Authority.", "#{file} consults authority"
        refute code =~ "ReceiptOutbox", "#{file} claims a receipt"
      end
    end
  end

  describe "canonical projection" do
    test "identical hook results project to identical turtle and different ones do not" do
      admitted = %{"status" => "ADMITTED", "verdicts" => [], "receipts" => [], "schedule" => []}
      refused = %{"status" => "REFUSED", "verdicts" => [], "receipts" => [], "schedule" => []}

      assert ResultProjection.hook_result_turtle("v", admitted) ==
               ResultProjection.hook_result_turtle("v", admitted)

      refute ResultProjection.hook_result_turtle("v", admitted) ==
               ResultProjection.hook_result_turtle("v", refused)
    end

    test "validation summary sorts the one map whose json order is not guaranteed" do
      # PlaygroundResult.hash_algorithms is a Rust HashMap, so the raw
      # validate_all JSON is not canonical. Two orderings, one summary.
      one = %{"hash_algorithms" => %{"BLAKE3" => "1.0", "RDFC" => "1.0"}, "dialects" => []}
      other = %{"hash_algorithms" => %{"RDFC" => "1.0", "BLAKE3" => "1.0"}, "dialects" => []}

      assert ResultProjection.validation_summary(one) ==
               ResultProjection.validation_summary(other)

      assert ResultProjection.validation_summary(one) =~ "hash_algorithms=BLAKE3=1.0,RDFC=1.0"
    end

    test "a real projected hook result is parseable turtle with a real canonical hash",
         %{} = _context do
      {:ok, %{session: session}} = WasmexSession.open([])

      try do
        {:ok, raw} =
          WasmexSession.call(session, :run_hooks, ["@prefix ex: <http://example.org/> .\n", ""])

        decoded = JSON.decode!(raw)
        turtle = ResultProjection.hook_result_turtle("probe", decoded)

        assert {:ok, hash} = WasmexSession.call(session, :graph_hash, [turtle])
        assert String.match?(hash, ~r/\A[0-9a-f]{64}\z/)
      after
        WasmexSession.close(session)
      end
    end
  end
end

# --- SECTION 10: Original test/ash_a2a/sa2a_formal_invariants_conformance_test.exs ---
# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshA2A.Sa2aFormalInvariantsConformanceTest do
  use ExUnit.Case, async: true
  import RDF.Sigils

  @canonical_dir Path.expand("../../priv/sa2a/canonical", __DIR__)

  test "sa2a-patch.ttl parses cleanly and contains all 4 formal invariants" do
    patch_path = Path.join(@canonical_dir, "sa2a-patch.ttl")
    assert File.exists?(patch_path)

    {:ok, graph} = RDF.Turtle.read_file(patch_path)
    assert RDF.Graph.triple_count(graph) >= 30

    # 1. Disjointness axioms
    owl_disjoint = ~I<http://www.w3.org/2002/07/owl#disjointWith>

    construct_cap =
      ~I<https://spec.seanchatmangpt.dev/sa2a/ontology/CAP/CoreCapabilities/ConstructCapability>

    do_cap = ~I<https://spec.seanchatmangpt.dev/sa2a/ontology/CAP/CoreCapabilities/DoCapability>

    assert RDF.Graph.include?(graph, {construct_cap, owl_disjoint, do_cap})

    cmd_envelope =
      ~I<https://spec.seanchatmangpt.dev/sa2a/ontology/BP/ExecutionEnvelopes/CommandEnvelope>

    act_receipt = ~I<https://spec.seanchatmangpt.dev/sa2a/ontology/EVI/Receipts/ActuationReceipt>

    assert RDF.Graph.include?(graph, {cmd_envelope, owl_disjoint, act_receipt})

    # 2. Standing enumeration individuals
    standing_class =
      ~I<https://spec.seanchatmangpt.dev/sa2a/ontology/EVI/Receipts/VerificationStanding>

    for standing <- [
          ~I<https://spec.seanchatmangpt.dev/sa2a/ontology/EVI/Receipts/StandingPass>,
          ~I<https://spec.seanchatmangpt.dev/sa2a/ontology/EVI/Receipts/StandingRefused>,
          ~I<https://spec.seanchatmangpt.dev/sa2a/ontology/EVI/Receipts/StandingBlocked>
        ] do
      assert RDF.Graph.include?(graph, {standing, RDF.type(), standing_class})
    end

    # 3. Cryptographic lease shape
    lease_shape = ~I<https://spec.seanchatmangpt.dev/sa2a/shapes/core#ActuationLeaseShape>
    sh_nodeshape = ~I<http://www.w3.org/ns/shacl#NodeShape>
    assert RDF.Graph.include?(graph, {lease_shape, RDF.type(), sh_nodeshape})

    # 4. Idempotency key shape
    idempotency_shape =
      ~I<https://spec.seanchatmangpt.dev/sa2a/shapes/core#CommandEnvelopeIdempotencyShape>

    assert RDF.Graph.include?(graph, {idempotency_shape, RDF.type(), sh_nodeshape})
  end

  test "AllSA2A.ttl contains the integrated patch invariants" do
    all_path = Path.join(@canonical_dir, "AllSA2A.ttl")
    {:ok, graph} = RDF.Turtle.read_file(all_path)

    owl_disjoint = ~I<http://www.w3.org/2002/07/owl#disjointWith>

    construct_cap =
      ~I<https://spec.seanchatmangpt.dev/sa2a/ontology/CAP/CoreCapabilities/ConstructCapability>

    do_cap = ~I<https://spec.seanchatmangpt.dev/sa2a/ontology/CAP/CoreCapabilities/DoCapability>

    assert RDF.Graph.include?(graph, {construct_cap, owl_disjoint, do_cap})

    cmd_envelope =
      ~I<https://spec.seanchatmangpt.dev/sa2a/ontology/BP/ExecutionEnvelopes/CommandEnvelope>

    act_receipt = ~I<https://spec.seanchatmangpt.dev/sa2a/ontology/EVI/Receipts/ActuationReceipt>

    assert RDF.Graph.include?(graph, {cmd_envelope, owl_disjoint, act_receipt})
  end

  test "runtime AshA2A.Json canonical encoding supports all formal invariant fields" do
    alias AshA2A.{Authority, Command, Json, Receipt}

    cmd =
      Command.new("cap:system:eval",
        agent_id: "agent:001",
        principal_id: "principal:001",
        input: %{"mode" => "strict"}
      )

    authority = Authority.new(cmd.principal_id, cmd.capability_id, source: :transport_verified)
    cmd_with_auth = %{cmd | authority: authority}
    exec_id = AshA2A.Identity.execution("exec:001")

    receipt =
      Receipt.from_reply(
        cmd_with_auth,
        exec_id,
        :observe,
        {:reply, :ok}
      )

    receipt_map =
      receipt
      |> Map.from_struct()
      |> Map.take([:receipt_id, :fingerprint, :status, :terminal_status, :standing])
      |> Map.new(fn
        {k, %AshA2A.Identity{value: v}} -> {Atom.to_string(k), to_string(v)}
        {k, v} -> {Atom.to_string(k), to_string(v)}
      end)

    json_output = Json.canonical(receipt_map)
    assert is_binary(json_output)
    {:ok, decoded} = Jason.decode(json_output)

    # Validate essential fields required by SHACL shapes
    assert is_binary(decoded["receipt_id"])
    assert is_binary(decoded["fingerprint"])
    assert decoded["status"] == "completed"
    assert decoded["terminal_status"] == "executed"
  end
end

# --- SECTION 11: Original test/ash_a2a/scheduled_sweep_qualification_test.exs ---
# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshA2A.ScheduledSweepQualificationTest do
  @moduledoc """
  `ash_oban` cron-scheduled-actions qualification.

  `mix.exs` has declared `{:ash_oban, "~> 0.8"}` since v26.9.14, but zero
  resource in this repository used it: `grep -rln "AshOban" lib/ test/`
  returned nothing before this file (confirmed directly, not assumed). This
  is the real gap -- the dependency was dead weight, not that AshOban itself
  was unimplementable.

  `AshOban.Test.Fixture.ScheduledSweep` (`test/support/scheduled_sweep_fixture.ex`)
  declares a real `oban do scheduled_actions do schedule ... end end` cron entry.
  This file proves, against a real PostgreSQL-backed `oban_jobs` table and a
  real `Oban` instance (no mocked queue, no stubbed cron clock, per this
  workspace's Chicago-style testing discipline):

    1. The real cron-scheduled Oban job, run via `AshOban.Test.schedule_and_run_triggers/2`
       (Oban's own real, documented drain-queue test helper -- not a hand-rolled
       scheduler loop), really calls the real `:sweep` create action and
       persists a real, ETS-backed record -- confirmed via `Ash.read!/2`
       against the real resulting records, not by inspecting Oban job
       bookkeeping alone.
    2. The `default_actor` configured in the DSL really reaches the action
       (the persisted `swept_by` field), proving AshOban's actor-passing
       path is real, not merely that a job got enqueued.
    3. Running the same scheduler twice enqueues and executes two real,
       independent jobs (unlike `AshA2A.CommandBus`'s own idempotent replay
       semantics -- a cron tick is not a command with a stable identity to
       replay against; each real tick is its own real execution by design).

  Needs a real, reachable PostgreSQL instance for `AshA2A.Test.Repo`
  (`config/test.exs`) -- Oban's own job queue is always Postgres-backed
  regardless of what data layer the scheduled resource itself uses;
  `setup_all` checks that for real and raises with setup instructions
  (matching `test/ash_a2a/oban_delivery_qualification_test.exs`'s own
  convention) rather than crashing opaquely if none is reachable.

  Uses the literal default `Oban` process name (not a custom-named instance,
  unlike `oban_delivery_qualification_test.exs`'s `AshA2A.Test.Oban`):
  `AshOban.schedule/3` calls the bare arity-1 `Oban.insert!/1` internally
  (confirmed by reading `deps/ash_oban/lib/ash_oban.ex` directly, not
  assumed), which always targets the process registered under the literal
  name `Oban` -- a custom name has no effect on where AshOban itself inserts
  the job, only on `AshOban.Test`'s own drain step, so the two must agree.
  Confirmed via grep that no other test file in this suite starts a
  supervised process under that same literal name, so this is safe under
  this repo's serialized `async: false` test execution.
  """

  use ExUnit.Case, async: false

  @moduletag :serial
  @moduletag :serial_solo
  alias AshA2A.Test.Fixture.ScheduledSweep

  setup_all do
    repo_config = ensure_postgres_reachable!()

    {:ok, _} = Application.ensure_all_started(:postgrex)
    start_supervised!(AshA2A.Test.Repo)

    apply_oban_migration!()

    start_supervised!(
      {Oban,
       name: Oban,
       repo: AshA2A.Test.Repo,
       queues: [maintenance: 5],
       plugins: false,
       testing: :manual}
    )

    %{repo_config: repo_config}
  end

  setup do
    on_exit(fn ->
      # Real cleanup so each test's own oban_jobs rows do not leak into the
      # next test in this file.
      AshA2A.Test.Repo.query!("TRUNCATE oban_jobs", [])
    end)

    # The ETS-backed AshA2A.Test.Fixture.ScheduledSweep table is shared
    # across every test in this async: false file (no per-test reset API
    # is used -- matching this repo's own established pattern in
    # oban_delivery_qualification_test.exs of scoping by what a test itself
    # created, rather than assuming a clean slate). Capture the real
    # pre-existing IDs so each test can assert on its own real delta.
    %{before_ids: existing_sweep_ids()}
  end

  test "a real cron-scheduled Oban job really calls the real :sweep action and persists a real record",
       %{before_ids: before_ids} do
    result =
      AshOban.Test.schedule_and_run_triggers({ScheduledSweep, :periodic_sweep},
        scheduled_actions?: true,
        oban: Oban
      )

    assert result.success == 1
    assert result.failure == 0

    assert [%ScheduledSweep{swept_at: %DateTime{}, swept_by: "system"}] =
             new_sweeps(before_ids)
  end

  test "the default_actor configured in the DSL really reaches the action", %{
    before_ids: before_ids
  } do
    AshOban.Test.schedule_and_run_triggers({ScheduledSweep, :periodic_sweep},
      scheduled_actions?: true,
      oban: Oban
    )

    assert [%ScheduledSweep{swept_by: swept_by}] = new_sweeps(before_ids)
    # The literal default_actor: %{id: "system"} declared in the DSL, not a
    # placeholder -- proving AshOban's actor-passing path is real.
    assert swept_by == "system"
  end

  test "running the scheduler twice really executes two independent real sweeps", %{
    before_ids: before_ids
  } do
    AshOban.Test.schedule_and_run_triggers({ScheduledSweep, :periodic_sweep},
      scheduled_actions?: true,
      oban: Oban
    )

    AshOban.Test.schedule_and_run_triggers({ScheduledSweep, :periodic_sweep},
      scheduled_actions?: true,
      oban: Oban
    )

    sweeps = new_sweeps(before_ids)
    assert length(sweeps) == 2
    assert Enum.all?(sweeps, &(&1.swept_by == "system"))

    # Two real, distinct records -- not the same row observed twice.
    assert sweeps |> Enum.map(& &1.id) |> Enum.uniq() |> length() == 2
  end

  defp existing_sweep_ids do
    ScheduledSweep
    |> Ash.read!(domain: AshA2A.Test.Fixture.ScheduledSweepDomain)
    |> MapSet.new(& &1.id)
  end

  defp new_sweeps(before_ids) do
    ScheduledSweep
    |> Ash.read!(domain: AshA2A.Test.Fixture.ScheduledSweepDomain)
    |> Enum.reject(&MapSet.member?(before_ids, &1.id))
  end

  defp apply_oban_migration! do
    case Ecto.Migrator.up(
           AshA2A.Test.Repo,
           20_260_913_000_001,
           AshA2A.Test.Repo.Migrations.AddObanJobsTable,
           log: false
         ) do
      :ok -> :ok
      :already_up -> :ok
    end
  end

  defp ensure_postgres_reachable! do
    repo_config = Application.fetch_env!(:ash_a2a, AshA2A.Test.Repo)

    connect_opts = [
      hostname: Keyword.fetch!(repo_config, :hostname),
      port: Keyword.fetch!(repo_config, :port),
      username: Keyword.fetch!(repo_config, :username),
      password: Keyword.fetch!(repo_config, :password),
      database: Keyword.fetch!(repo_config, :database),
      timeout: 2_000,
      connect_timeout: 2_000
    ]

    case Postgrex.start_link(connect_opts) do
      {:ok, pid} ->
        # Postgrex connects lazily by default: start_link alone succeeds even
        # with the database down, deferring failure to opaque pool timeouts.
        # Force a synchronous round trip so an unreachable database fails at
        # this gate, fast, with the run instructions below.
        try do
          Postgrex.query!(pid, "SELECT 1", [])
        rescue
          error ->
            GenServer.stop(pid)

            raise """
            Real Postgres not reachable at #{connect_opts[:hostname]}:#{connect_opts[:port]}/#{connect_opts[:database]} \
            for AshA2A.Test.Repo (test/ash_a2a/scheduled_sweep_qualification_test.exs).
            Reason: #{Exception.message(error)}

            This test needs a real, dedicated local Postgres instance -- Oban's own
            job queue is always Postgres-backed. This release cycle expects one
            already running at that host/port/db (see config/test.exs for the
            exact connection opts this test reads). Start one and re-run, e.g.:

              docker run --rm -p 55432:5432 -e POSTGRES_PASSWORD=postgres \\
                -e POSTGRES_DB=ash_a2a_test postgres:16

            then: mix test test/ash_a2a/scheduled_sweep_qualification_test.exs
            """
        end

        GenServer.stop(pid)
        repo_config

      {:error, reason} ->
        raise """
        Real Postgres not reachable at #{connect_opts[:hostname]}:#{connect_opts[:port]}/#{connect_opts[:database]} \
        for AshA2A.Test.Repo (test/ash_a2a/scheduled_sweep_qualification_test.exs).
        Reason: #{inspect(reason)}

        This test needs a real, dedicated local Postgres instance -- Oban's own
        job queue is always Postgres-backed. This release cycle expects one
        already running at that host/port/db (see config/test.exs for the
        exact connection opts this test reads). Start one and re-run, e.g.:

          docker run --rm -p 55432:5432 -e POSTGRES_PASSWORD=postgres \\
            -e POSTGRES_DB=ash_a2a_test postgres:16

        then: mix test test/ash_a2a/scheduled_sweep_qualification_test.exs
        """
    end
  end
end

# --- SECTION 12: Original test/ash_a2a/sec_m11_effect_instance_test.exs ---
# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshA2A.SecM11EffectInstanceTest do
  use ExUnit.Case, async: true

  test "effect identity binds request and subject" do
    assert {:ok, x} =
             AshA2A.EffectInstance.new(%{
               request: %{"x" => 1},
               subject: %{"id" => "s"},
               effect: %{"op" => "create"}
             })

    assert x.request_id != x.effect_id
    assert x.subject_digest =~ "sha256:"
  end
end

# --- SECTION 13: Original test/ash_a2a/sec_m14_canonical_identity_test.exs ---
# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshA2A.SecM14CanonicalIdentityTest do
  use ExUnit.Case, async: true

  test "same JSON value has stable portable digest" do
    assert {:ok, a} = AshA2A.Identity.Canonical.digest(%{"b" => 2, "a" => 1})
    assert {:ok, ^a} = AshA2A.Identity.Canonical.digest(%{"a" => 1, "b" => 2})
    assert a =~ ~r/^sha256:[0-9a-f]{64}$/
  end
end

# --- SECTION 14: Original test/ash_a2a/semantic_admission_hash_test.exs ---
# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshA2A.SemanticAdmissionHashTest do
  @moduledoc """
  Chicago-school tests for RFC-SA2A-001 S12/S31/S33/S52/S60.

  Every digest asserted here came out of the REAL `praxis-graphlaw` wasm
  module executed in a REAL subprocess. Nothing is mocked, stubbed or
  hand-computed in Elixir. Where the engine artifact is absent the tests
  produce a NAMED, VISIBLE SKIP rather than substituting a fake engine --
  a mocked hash would certify nothing at all, which is the entire point of
  the admission hash.

  The chain is anchored to an external constant: `blake3_hex("abc")` is
  asserted against the published BLAKE3 test vector, so a silently-wrong
  engine cannot pass these tests just by being self-consistent.
  """
  use ExUnit.Case, async: true

  alias AshA2A.GraphLaw.WasmDriver
  alias AshA2A.Semantic.AdmissionHash

  doctest AshA2A.Semantic.AdmissionHash

  # Published BLAKE3 test vector for the 3-byte input "abc".
  @blake3_abc "6437b3ac38465133ffb63b75273a8db548c558465d79db03fd359c6cd5bd9d85"

  @base_ttl """
  @prefix ex: <http://example.org/> .
  ex:a ex:p ex:b .
  ex:b ex:p ex:c .
  """

  # Same graph: different prefix LABEL and different triple ORDER.
  @relabelled_ttl """
  @prefix zz: <http://example.org/> .
  zz:b zz:p zz:c .
  zz:a zz:p zz:b .
  """

  # One triple genuinely changed.
  @mutated_ttl """
  @prefix ex: <http://example.org/> .
  ex:a ex:p ex:b .
  ex:b ex:p ex:ZZZ .
  """

  @validators ["shacl-core", "shex-2.1"]
  @rules ["n3-log-implies", "owl-rl"]
  @profile "sa2a/profile/strict"

  # Evaluated at compile time so the engine-backed tests can produce a NAMED,
  # VISIBLE ExUnit skip (with the resolved path in the reason) instead of
  # silently degrading to a fabricated engine.
  @engine_skip (if AshA2A.GraphLaw.WasmDriver.available?() do
                  false
                else
                  "praxis-graphlaw wasm engine unavailable at " <>
                    AshA2A.GraphLaw.WasmDriver.wasm_path() <>
                    " (set GRAPHLAW_WASM_PATH or config :ash_a2a, :graphlaw_wasm_path)"
                end)

  describe "encoding (pure, no engine required)" do
    test "netstring framing is prefix-free" do
      assert AdmissionHash.netstring("abc") == "3:abc,"
      assert AdmissionHash.netstring("") == "0:,"
      # A netstring carrying its own framing characters is still unambiguous.
      assert AdmissionHash.netstring("3:x,") == "4:3:x,,"
    end

    test "THE BOUNDARY CASE: a byte cannot migrate across a component boundary" do
      # Under naive `Validators || Rules` concatenation these two genuinely
      # different admissions both produce the preimage "abc" and therefore
      # collide. Length-prefixing must separate them.
      a_validators = AdmissionHash.validators_preimage(["a"], :preserved_order)
      a_rules = AdmissionHash.rules_preimage(["bc"], :preserved_order)

      b_validators = AdmissionHash.validators_preimage(["ab"], :preserved_order)
      b_rules = AdmissionHash.rules_preimage(["c"], :preserved_order)

      refute a_validators <> a_rules == b_validators <> b_rules
      refute a_validators == b_validators
      refute a_rules == b_rules
    end

    test "list element boundaries are injective" do
      refute AdmissionHash.validators_preimage(["a", "bc"], :preserved_order) ==
               AdmissionHash.validators_preimage(["ab", "c"], :preserved_order)

      refute AdmissionHash.validators_preimage(["a,b"], :preserved_order) ==
               AdmissionHash.validators_preimage(["a", "b"], :preserved_order)
    end

    test "domain separation: identical content in different components differs" do
      refute AdmissionHash.validators_preimage(["x"]) == AdmissionHash.rules_preimage(["x"])
      refute AdmissionHash.rules_preimage(["x"]) == AdmissionHash.profile_preimage("x")
    end

    test "validators and rules default to set semantics; order can be preserved" do
      assert AdmissionHash.validators_preimage(["b", "a"]) ==
               AdmissionHash.validators_preimage(["a", "b"])

      assert AdmissionHash.validators_preimage(["a", "a", "b"]) ==
               AdmissionHash.validators_preimage(["a", "b"])

      refute AdmissionHash.validators_preimage(["b", "a"], :preserved_order) ==
               AdmissionHash.validators_preimage(["a", "b"], :preserved_order)
    end

    test "map profile key/value boundaries are injective and key-order-free" do
      assert AdmissionHash.profile_preimage(%{"a" => "1", "b" => "2"}) ==
               AdmissionHash.profile_preimage(%{"b" => "2", "a" => "1"})

      refute AdmissionHash.profile_preimage(%{"ab" => "c"}) ==
               AdmissionHash.profile_preimage(%{"a" => "bc"})
    end

    test "composite preimage frames all four component digests in a fixed order" do
      preimage = AdmissionHash.composite_preimage("g", "v", "r", "p")

      assert preimage ==
               "sa2a-admission-hash/v1\n" <>
                 "5:graph,1:g,10:validators,1:v,5:rules,1:r,7:profile,1:p,"

      # Swapping which component a digest belongs to changes the preimage.
      refute preimage == AdmissionHash.composite_preimage("v", "g", "r", "p")
    end

    test "components/0 fixes the composite order" do
      assert AdmissionHash.components() == [:graph, :validators, :rules, :profile]
    end
  end

  describe "real engine" do
    @describetag :graphlaw
    @describetag skip: @engine_skip

    test "blake3_hex is anchored to the published BLAKE3 vector for \"abc\"" do
      assert {:ok, @blake3_abc} = WasmDriver.blake3_hex("abc")
    end

    test "engine reports its version through the real subprocess" do
      assert {:ok, version} = WasmDriver.version()
      assert String.starts_with?(version, "praxis-graphlaw")
    end

    test "canonical_graph_digest is invariant under prefix relabelling and triple reorder" do
      assert {:ok, base} = AdmissionHash.canonical_graph_digest(@base_ttl)
      assert {:ok, relabelled} = AdmissionHash.canonical_graph_digest(@relabelled_ttl)
      assert {:ok, mutated} = AdmissionHash.canonical_graph_digest(@mutated_ttl)

      assert base == relabelled,
             "graph digest must be prefix-label and triple-order invariant, " <>
               "got #{base} vs #{relabelled}"

      refute base == mutated
      assert String.match?(base, ~r/^[0-9a-f]{64}$/)
    end

    test "canonical_graph_digest of a malformed document does not collide with the empty graph" do
      assert {:ok, empty} = AdmissionHash.canonical_graph_digest("")
      assert {:ok, malformed} = AdmissionHash.canonical_graph_digest("not turtle at all {{{")

      # Measured behaviour: the engine returns a digest rather than an
      # error for unparsable input, but it is NOT the empty-graph digest.
      # Asserted so a future engine change that silently collapses garbage
      # to the empty graph -- which would let a peer pass conformance with
      # no semantic state at all -- fails loudly here.
      refute empty == malformed
    end

    test "admission_hash binds all four components and is reproducible" do
      assert {:ok, h1} =
               AdmissionHash.admission_hash(@base_ttl, @validators, @rules, @profile)

      assert {:ok, h2} =
               AdmissionHash.admission_hash(@base_ttl, @validators, @rules, @profile)

      assert AdmissionHash.agree?(h1, h2)
      assert AdmissionHash.differing_components(h1, h2) == []
      assert String.match?(h1.admission_hash, ~r/^[0-9a-f]{64}$/)
      assert h1.encoding == "sa2a-admission-hash/v1"
      assert h1.algorithm == "blake3"
      assert h1.normalization == :sorted_set
      assert String.starts_with?(h1.engine_version, "praxis-graphlaw")
    end

    test "the composite hash is exactly BLAKE3 of the documented preimage" do
      assert {:ok, h} = AdmissionHash.admission_hash(@base_ttl, @validators, @rules, @profile)

      preimage =
        AdmissionHash.composite_preimage(
          h.graph_digest,
          h.validators_digest,
          h.rules_digest,
          h.profile_digest
        )

      assert {:ok, recomputed} = WasmDriver.blake3_hex(preimage)

      assert recomputed == h.admission_hash,
             "a verifier holding only the four component digests must be able to " <>
               "rebuild the composite; got #{recomputed} vs #{h.admission_hash}"
    end

    test "each of the four components independently changes the admission hash" do
      {:ok, base} = AdmissionHash.admission_hash(@base_ttl, @validators, @rules, @profile)

      {:ok, other_graph} =
        AdmissionHash.admission_hash(@mutated_ttl, @validators, @rules, @profile)

      {:ok, other_validators} =
        AdmissionHash.admission_hash(@base_ttl, ["shacl-core"], @rules, @profile)

      {:ok, other_rules} =
        AdmissionHash.admission_hash(@base_ttl, @validators, ["owl-rl"], @profile)

      {:ok, other_profile} =
        AdmissionHash.admission_hash(@base_ttl, @validators, @rules, "sa2a/profile/lax")

      for {label, variant} <- [
            graph: other_graph,
            validators: other_validators,
            rules: other_rules,
            profile: other_profile
          ] do
        refute base.admission_hash == variant.admission_hash,
               "changing #{label} must change the admission hash"

        assert AdmissionHash.differing_components(base, variant) == [label],
               "changing #{label} must localise to exactly that component, got " <>
                 inspect(AdmissionHash.differing_components(base, variant))

        refute AdmissionHash.agree?(base, variant)
      end
    end

    test "a graph that is only relabelled does NOT change the admission hash" do
      {:ok, a} = AdmissionHash.admission_hash(@base_ttl, @validators, @rules, @profile)
      {:ok, b} = AdmissionHash.admission_hash(@relabelled_ttl, @validators, @rules, @profile)

      # This is the S12 property the whole conformance claim rests on: two
      # peers that serialised the same O* differently still agree. Scope:
      # prefix labels and triple order only -- blank-node relabelling is not
      # covered (see the MEASURED ENGINE LIMITATION test below).
      assert AdmissionHash.agree?(b, a)
    end

    test "differing_components flags an incomparable normalization" do
      {:ok, sorted} =
        AdmissionHash.admission_hash(@base_ttl, ["b", "a"], @rules, @profile)

      {:ok, ordered} =
        AdmissionHash.admission_hash(@base_ttl, ["b", "a"], @rules, @profile,
          preserve_order: true
        )

      assert :normalization_mismatch in AdmissionHash.differing_components(sorted, ordered)
      refute AdmissionHash.agree?(sorted, ordered)
    end

    test "MEASURED ENGINE LIMITATION: a blank-node relabel changes graph_digest (not RDFC-1.0)" do
      # Recorded, not assumed. The same one-triple graph written with `_:b1`
      # and with `_:zzz9` is one RDF graph under RDFC-1.0 -- RDF.ex's in-BEAM
      # `RDF.Graph.canonical_hash/1` (the RFC S12 identity
      # `AshA2A.Semantic.AdmissionPipeline` uses) gives one digest for both --
      # but the engine's `graph_hash`, which this admission hash is wired to,
      # gives two. Two peers holding the same O* under different blank-node
      # labels therefore disagree on `h`, localised to `[:graph]`.
      #
      # Falsifier: if the engine becomes blank-node canonical, the first
      # `refute` fails and the "not RDFC-1.0" wording in AdmissionHash,
      # Ontology and WasmDriver docs must be revisited.
      b1 = "@prefix ex: <http://example.org/> .\n_:b1 ex:p ex:o .\n"
      zzz9 = "@prefix ex: <http://example.org/> .\n_:zzz9 ex:p ex:o .\n"

      {:ok, g1} = RDF.Turtle.read_string(b1)
      {:ok, g2} = RDF.Turtle.read_string(zzz9)
      assert RDF.Graph.canonical_hash(g1) == RDF.Graph.canonical_hash(g2)

      assert {:ok, d1} = AdmissionHash.canonical_graph_digest(b1)
      assert {:ok, d2} = AdmissionHash.canonical_graph_digest(zzz9)
      refute d1 == d2, "engine graph_hash is now blank-node canonical; see falsifier note"

      {:ok, h1} = AdmissionHash.admission_hash(b1, @validators, @rules, @profile)
      {:ok, h2} = AdmissionHash.admission_hash(zzz9, @validators, @rules, @profile)
      assert AdmissionHash.differing_components(h1, h2) == [:graph]
    end
  end

  describe "typed failure when the engine is absent" do
    test "a missing wasm artifact is a typed error, never a fabricated digest" do
      assert {:error, %{code: :graphlaw_wasm_not_found, path: path}} =
               AdmissionHash.canonical_graph_digest(@base_ttl,
                 wasm_path: "/nonexistent/praxis_graphlaw_wasm_bg.wasm"
               )

      assert path == "/nonexistent/praxis_graphlaw_wasm_bg.wasm"

      assert {:error, %{code: :graphlaw_wasm_not_found}} =
               AdmissionHash.admission_hash(@base_ttl, @validators, @rules, @profile,
                 wasm_path: "/nonexistent/praxis_graphlaw_wasm_bg.wasm"
               )
    end

    @tag skip: @engine_skip
    test "an unknown engine export is a typed error" do
      assert {:ok, [{:error, %{code: :graphlaw_call_error}}]} =
               WasmDriver.call_many([{"definitely_not_an_export", []}])
    end
  end
end

# --- SECTION 15: Original test/ash_a2a/semantic_admission_pipeline_test.exs ---
# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshA2A.SemanticAdmissionPipelineEngineTest do
  @moduledoc """
  Real end-to-end exercise of `AshA2A.Semantic.AdmissionPipeline` against the
  real `praxis-graphlaw` WebAssembly engine.

  Chicago school throughout: every assertion below is on real returned state --
  a real canonical graph hash out of the real wasm, a real SHACL/ShEx verdict,
  a real refusal struct, a real BLAKE3 admission digest. There are no mocks,
  no stubbed collaborators, and no interaction assertions.

  When the real GraphLaw wasm artifact is not present on this machine the whole
  module is a **named, visible skip** carrying the real reason string, rather
  than a silent substitution of a fake engine. `AshA2A.SemanticAdmissionPipelineTest`
  (same file) holds the engine-independent cases, which always run.
  """

  use ExUnit.Case, async: true

  alias AshA2A.GraphLaw.Wasm
  alias AshA2A.Semantic.IR
  alias AshA2A.Semantic.AdmissionRefusal, as: Refusal
  alias AshA2A.Semantic.AdmissionStanding, as: Standing
  alias AshA2A.Semantic.AdmissionPipeline
  alias AshA2A.Semantic.AdmissionPipeline.Result
  alias AshA2A.Test.SA2AAdmissionFixtures, as: Fixtures

  @graphlaw_availability AshA2A.GraphLaw.Wasm.availability()

  case @graphlaw_availability do
    :ok ->
      @moduletag :graphlaw

    {:error, detail} ->
      @moduletag skip:
                   "real GraphLaw wasm unavailable (#{inspect(detail)}) -- " <>
                     "these cases run the real engine and are never mocked"
  end

  defp engine_available?, do: Wasm.availability() == :ok

  describe "positive admission through every required stage" do
    @tag :graphlaw
    test "a conforming candidate reaches :admitted with a real engine-computed receipt identity" do
      if engine_available?() do
        assert {:ok, %Result{} = result} =
                 AdmissionPipeline.admit(Fixtures.candidate(), Fixtures.law_opts())

        assert result.standing == :admitted
        assert Standing.admitted?(result.standing)

        # RFC S4.2/S28: admission produces standing, never permission.
        assert result.authority == :none

        # Every required stage actually passed -- the S19 intersection.
        assert result.stages == AdmissionPipeline.required_stages()

        # The engine's own graph digest -- prefix- and order-invariant, but
        # NOT blank-node-relabel invariant, so not RDFC-1.0 (see
        # AshA2A.GraphLaw.Wasm.graph_hash/2). RFC S12 canonical identity is
        # the RDF.ex RDFC-1.0 hash carried alongside it.
        assert result.graph_hash =~ ~r/\A[0-9a-f]{64}\z/
        assert result.canonical_graph_hash =~ ~r/\A[0-9a-f]{64}\z/
        # Real BLAKE3 admission receipt identity, computed inside the wasm.
        assert result.admission_digest =~ ~r/\A[0-9a-f]{64}\z/
        assert result.engine_version =~ "praxis-graphlaw"

        # The grounded IR from the real `AshA2A.Semantic.Admission` composition
        # point comes back admitted, unchanged in kind.
        assert %IR{standing: :admitted, authority: :none} = result.ir
      end
    end

    @tag :graphlaw
    test "admission is replayable: the same candidate yields the same digests" do
      if engine_available?() do
        assert {:ok, first} = AdmissionPipeline.admit(Fixtures.candidate(), Fixtures.law_opts())
        assert {:ok, second} = AdmissionPipeline.admit(Fixtures.candidate(), Fixtures.law_opts())

        assert first.graph_hash == second.graph_hash
        assert first.admission_digest == second.admission_digest
      end
    end

    @tag :graphlaw
    test "canonical identity ignores prefix labels and triple order but not content" do
      if engine_available?() do
        relabelled = """
        @prefix zz: <http://example.org/> .
        @prefix sc: <http://schema.org/> .
        zz:a zz:owner zz:sean .
        zz:a a zz:Goal .
        zz:a sc:description "ship the admission pipeline" .
        """

        assert {:ok, base} = AdmissionPipeline.admit(Fixtures.candidate(), Fixtures.law_opts())

        assert {:ok, same} =
                 AdmissionPipeline.admit(
                   Fixtures.candidate(graph_ttl: relabelled),
                   Fixtures.law_opts()
                 )

        assert base.graph_hash == same.graph_hash

        # Different lawful content under the same admitted law. (A candidate
        # carrying its own permissive falsifier set is refused: law standing.)
        assert {:ok, other} =
                 AdmissionPipeline.admit(
                   Fixtures.candidate(
                     graph_ttl:
                       Fixtures.conforming_graph() <> ~s(ex:c ex:note "another lawful fact" .\n)
                   ),
                   Fixtures.law_opts()
                 )

        refute base.graph_hash == other.graph_hash
      end
    end

    @tag :graphlaw
    test "pinning the expected graph identity admits when it matches" do
      if engine_available?() do
        assert {:ok, base} = AdmissionPipeline.admit(Fixtures.candidate(), Fixtures.law_opts())

        assert {:ok, pinned} =
                 AdmissionPipeline.admit(
                   Fixtures.candidate(expected_graph_hash: base.graph_hash),
                   Fixtures.law_opts()
                 )

        assert pinned.graph_hash == base.graph_hash
      end
    end
  end

  describe "one real negative per stage, each refusing at the right stage" do
    @tag :graphlaw
    test "Parse: non-Turtle input refuses at :parse, not silently as 0 SHACL violations" do
      if engine_available?() do
        assert {:error, %Refusal{} = refusal} =
                 AdmissionPipeline.admit(
                   Fixtures.candidate(graph_ttl: Fixtures.not_turtle()),
                   Fixtures.law_opts()
                 )

        assert refusal.stage == :parse
        assert refusal.code == :parse_yielded_no_triples
        assert refusal.determinacy == :violated
        assert refusal.standing == :candidate

        # The falsifier this test really rests on: the same input, handed
        # straight to the engine without the pipeline's parse witness, comes
        # back with a hash and a clean SHACL report. "A hash came back" and
        # "zero violations" are exactly what the Parse stage exists to stop.
        assert {:ok, hash} = Wasm.graph_hash(Fixtures.not_turtle())
        assert hash =~ ~r/\A[0-9a-f]{64}\z/

        assert {:ok, report} =
                 Wasm.validate_all(Fixtures.not_turtle(), "", Fixtures.shacl_shapes(), "", "")

        assert {:ok, %{"status" => "ADMITTED"}} = Wasm.dialect(report, "SHACL")
      end
    end

    @tag :graphlaw
    test "Identity: a mismatched pinned graph hash refuses at :identity" do
      if engine_available?() do
        assert {:error, %Refusal{} = refusal} =
                 AdmissionPipeline.admit(
                   Fixtures.candidate(expected_graph_hash: String.duplicate("0", 64)),
                   Fixtures.law_opts()
                 )

        assert refusal.stage == :identity
        assert refusal.code == :graph_identity_mismatch
        assert refusal.determinacy == :violated
        assert refusal.standing == :parsed
        assert refusal.evidence.expected == String.duplicate("0", 64)
        assert refusal.evidence.actual =~ ~r/\A[0-9a-f]{64}\z/
      end
    end

    @tag :graphlaw
    test "ShEx: a graph missing the ShEx-required predicate refuses at :shex" do
      if engine_available?() do
        assert {:error, %Refusal{} = refusal} =
                 AdmissionPipeline.admit(
                   Fixtures.candidate(graph_ttl: Fixtures.graph_missing_description()),
                   Fixtures.law_opts()
                 )

        assert refusal.stage == :shex
        assert refusal.code == :shex_nonconformant
        assert refusal.determinacy == :violated
        assert refusal.standing == :identified
        assert refusal.evidence["status"] == "REFUSED"
        assert refusal.evidence["triples_out"] >= 1
      end
    end

    @tag :graphlaw
    test "ShEx: an absent schema refuses as undetermined, never as a pass (RFC S43)" do
      if engine_available?() do
        assert {:error, %Refusal{} = refusal} =
                 AdmissionPipeline.admit(
                   Fixtures.candidate(shex_schema: "", shex_shape_map: ""),
                   Fixtures.law_opts()
                 )

        assert refusal.stage == :shex
        assert refusal.code == :shex_schema_not_supplied
        assert refusal.determinacy == :undetermined
      end
    end

    @tag :graphlaw
    test "SHACL: a graph that passes ShEx but violates SHACL refuses at :shacl" do
      if engine_available?() do
        assert {:error, %Refusal{} = refusal} =
                 AdmissionPipeline.admit(
                   Fixtures.candidate(graph_ttl: Fixtures.graph_missing_owner()),
                   Fixtures.law_opts()
                 )

        assert refusal.stage == :shacl
        assert refusal.code == :shacl_nonconformant
        assert refusal.determinacy == :violated
        assert refusal.standing == :shex_conformant
        assert refusal.evidence["status"] == "REFUSED"
      end
    end

    @tag :graphlaw
    test "SHACL: absent shapes refuse as undetermined (RFC S43)" do
      if engine_available?() do
        assert {:error, %Refusal{} = refusal} =
                 AdmissionPipeline.admit(
                   Fixtures.candidate(shacl_shapes: ""),
                   Fixtures.law_opts()
                 )

        assert refusal.stage == :shacl
        assert refusal.code == :shacl_shapes_not_supplied
        assert refusal.determinacy == :undetermined
      end
    end

    @tag :graphlaw
    test "SPARQLFalsifiers: a real N3 denial firing on a real triple refuses at :sparql_falsifiers" do
      if engine_available?() do
        assert {:error, %Refusal{} = refusal} =
                 AdmissionPipeline.admit(
                   Fixtures.candidate(graph_ttl: Fixtures.graph_with_forbidden()),
                   Fixtures.law_opts()
                 )

        assert refusal.stage == :sparql_falsifiers
        assert refusal.code == :falsifier_violated
        assert refusal.determinacy == :violated
        assert refusal.standing == :closed
        assert refusal.evidence["status"] == "REFUSED"
        assert refusal.evidence["triples_out"] >= 1
      end
    end

    @tag :graphlaw
    test "SPARQLFalsifiers: an empty falsifier set determines nothing and refuses" do
      if engine_available?() do
        assert {:error, %Refusal{} = refusal} =
                 AdmissionPipeline.admit(Fixtures.candidate(falsifiers: ""), Fixtures.law_opts())

        assert refusal.stage == :sparql_falsifiers
        assert refusal.code == :falsifiers_not_supplied
        assert refusal.determinacy == :undetermined
      end
    end

    @tag :graphlaw
    test "Provenance: an ungrounded source_quote refuses at :provenance via the real Admission module" do
      if engine_available?() do
        assert {:error, %Refusal{} = refusal} =
                 AdmissionPipeline.admit(
                   Fixtures.candidate(provenance: Fixtures.ungrounded_provenance()),
                   Fixtures.law_opts()
                 )

        assert refusal.stage == :provenance
        assert refusal.code == :provenance_not_grounded
        assert refusal.determinacy == :violated
        assert refusal.standing == :falsifiers_clear
        # The real error map from the existing `AshA2A.Semantic.Admission`,
        # carried through unchanged rather than re-derived here.
        assert %{code: :ungrounded_assertion} = refusal.detail
      end
    end

    @tag :graphlaw
    test "Provenance: a missing witness refuses rather than skipping the check" do
      if engine_available?() do
        assert {:error, %Refusal{} = refusal} =
                 AdmissionPipeline.admit(Fixtures.candidate(provenance: nil), Fixtures.law_opts())

        assert refusal.stage == :provenance
        assert refusal.code == :provenance_witness_missing
        assert refusal.determinacy == :undetermined
      end
    end

    @tag :graphlaw
    test "ProfileChecks: an absent profile refuses as undetermined (RFC S43)" do
      if engine_available?() do
        assert {:error, %Refusal{} = refusal} =
                 AdmissionPipeline.admit(Fixtures.candidate(profile_ttl: ""), Fixtures.law_opts())

        assert refusal.stage == :profile_checks
        assert refusal.code == :profile_not_supplied
        assert refusal.determinacy == :undetermined
        assert refusal.standing == :provenance_grounded
      end
    end
  end

  describe "RFC S44: a refusal leaves canonical state unchanged" do
    @tag :graphlaw
    test "every refusing stage leaves the real canonical graph digest byte-identical" do
      if engine_available?() do
        graph = Fixtures.conforming_graph()
        assert {:ok, before_digest} = Wasm.graph_hash(graph)

        refusing_candidates = [
          Fixtures.candidate(graph_ttl: Fixtures.not_turtle()),
          Fixtures.candidate(expected_graph_hash: String.duplicate("0", 64)),
          Fixtures.candidate(graph_ttl: Fixtures.graph_missing_description()),
          Fixtures.candidate(graph_ttl: Fixtures.graph_missing_owner()),
          Fixtures.candidate(graph_ttl: Fixtures.graph_with_forbidden()),
          Fixtures.candidate(provenance: Fixtures.ungrounded_provenance()),
          Fixtures.candidate(profile_ttl: "")
        ]

        for candidate <- refusing_candidates do
          assert {:error, %Refusal{}} = AdmissionPipeline.admit(candidate, Fixtures.law_opts())
        end

        # Real after-state, recomputed by the real engine -- not an inspection
        # of the pipeline source, and not the same value carried forward.
        assert {:ok, after_digest} = Wasm.graph_hash(graph)
        assert before_digest == after_digest

        # And the conforming candidate still admits afterwards with the same
        # identity it had before the refusals ran.
        assert {:ok, %Result{} = result} =
                 AdmissionPipeline.admit(Fixtures.candidate(), Fixtures.law_opts())

        assert result.graph_hash == before_digest
      end
    end
  end

  describe "telemetry" do
    @tag :graphlaw
    test "a real admission emits a real stage event per stage plus start and stop" do
      if engine_available?() do
        handler_id = "sa2a-admission-#{System.unique_integer([:positive])}"
        test_pid = self()

        :telemetry.attach_many(
          handler_id,
          [
            [:ash_a2a, :semantic, :admission, :start],
            [:ash_a2a, :semantic, :admission, :stage],
            [:ash_a2a, :semantic, :admission, :stop]
          ],
          fn event, measurements, metadata, _ ->
            send(test_pid, {:telemetry, event, measurements, metadata})
          end,
          nil
        )

        on_exit(fn -> :telemetry.detach(handler_id) end)

        assert {:ok, %Result{}} =
                 AdmissionPipeline.admit(Fixtures.candidate(), Fixtures.law_opts())

        assert_receive {:telemetry, [:ash_a2a, :semantic, :admission, :start], _, _}

        for stage <- AdmissionPipeline.required_stages() do
          assert_receive {:telemetry, [:ash_a2a, :semantic, :admission, :stage], _,
                          %{stage: ^stage, outcome: :ok}}
        end

        assert_receive {:telemetry, [:ash_a2a, :semantic, :admission, :stop], _,
                        %{outcome: :admitted, standing: :admitted}}
      end
    end

    @tag :graphlaw
    test "a refusal emits a real refused stage event naming the stage and code" do
      if engine_available?() do
        handler_id = "sa2a-admission-refuse-#{System.unique_integer([:positive])}"
        test_pid = self()

        :telemetry.attach(
          handler_id,
          [:ash_a2a, :semantic, :admission, :stage],
          fn event, measurements, metadata, _ ->
            send(test_pid, {:telemetry, event, measurements, metadata})
          end,
          nil
        )

        on_exit(fn -> :telemetry.detach(handler_id) end)

        assert {:error, %Refusal{}} =
                 AdmissionPipeline.admit(
                   Fixtures.candidate(graph_ttl: Fixtures.graph_missing_owner()),
                   Fixtures.law_opts()
                 )

        assert_receive {:telemetry, [:ash_a2a, :semantic, :admission, :stage], _,
                        %{
                          stage: :shacl,
                          outcome: :refused,
                          code: :shacl_nonconformant,
                          determinacy: :violated
                        }}
      end
    end
  end
end

defmodule AshA2A.SemanticAdmissionPipelineTest do
  @moduledoc """
  The engine-independent half of the admission-pipeline suite: the structural
  RFC S19 intersection properties, the fail-closed behaviour when the real
  engine is not reachable at all, and the candidate's own defaults.

  These cases run on every machine, including one without the GraphLaw wasm
  artifact -- which is exactly why the "engine unavailable" case belongs here:
  a missing engine must refuse, and that must be provable everywhere.
  """

  use ExUnit.Case, async: true

  alias AshA2A.Semantic.AdmissionRefusal, as: Refusal
  alias AshA2A.Semantic.AdmissionStanding, as: Standing
  alias AshA2A.Semantic.AdmissionPipeline
  alias AshA2A.Semantic.AdmissionPipeline.Candidate
  alias AshA2A.Test.SA2AAdmissionFixtures, as: Fixtures

  describe "RFC S19: the admitted set is structurally an intersection" do
    test "required_stages/0 is exactly the RFC S13 ordered stage list" do
      assert AdmissionPipeline.required_stages() == [
               :parse,
               :identity,
               :shex,
               :shacl,
               :rule_closure,
               :sparql_falsifiers,
               :provenance,
               :profile_checks
             ]
    end

    test "every required stage maps onto a distinct standing on the monotonic ladder" do
      standings = Keyword.values(AdmissionPipeline.stage_standing())

      assert length(Enum.uniq(standings)) == length(standings)
      assert Enum.all?(standings, &(Standing.rank(&1) != :error))

      # Each stage's standing is strictly one step above the previous one, so
      # no stage can be skipped on the way to :admitted.
      ranks =
        Enum.map(standings, fn standing ->
          {:ok, rank} = Standing.rank(standing)
          rank
        end)

      assert ranks == Enum.sort(ranks)

      assert ranks
             |> Enum.chunk_every(2, 1, :discard)
             |> Enum.all?(fn [a, b] -> b == a + 1 end)
    end
  end

  describe "engine unavailability is a refusal, never a pass" do
    @tag :graphlaw_engine
    test "a wrong wasm path refuses at :parse as undetermined" do
      assert {:error, %Refusal{} = refusal} =
               AdmissionPipeline.admit(
                 Fixtures.candidate(),
                 Keyword.merge(Fixtures.law_opts(), wasm_path: "/nonexistent/graphlaw.wasm")
               )

      assert refusal.stage == :parse
      assert refusal.code == :graphlaw_engine_unavailable
      assert refusal.determinacy == :undetermined
      assert %{code: :graphlaw_wasm_not_found} = refusal.detail
    end
  end

  describe "candidate shape" do
    test "a candidate requires a graph and defaults every law field to blank" do
      candidate = %Candidate{graph_ttl: "@prefix ex: <http://example.org/> ."}

      assert candidate.profile_ttl == ""
      assert candidate.shacl_shapes == ""
      assert candidate.shex_schema == ""
      assert candidate.shex_shape_map == ""
      assert candidate.falsifiers == ""
      assert candidate.provenance == nil
      assert candidate.expected_graph_hash == nil
    end

    test "the parse witness is the universal denial rule" do
      assert AdmissionPipeline.parse_witness() =~ "{ ?s ?p ?o } => false ."
    end
  end
end

# --- SECTION 16: Original test/ash_a2a/semantic_admission_standing_test.exs ---
# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshA2A.SemanticAdmissionStandingTest do
  @moduledoc """
  Real state-based tests for the monotonic standing ladder. No collaborators to
  fake: `AshA2A.Semantic.AdmissionStanding` is pure, and every assertion below is on a
  real returned value.
  """

  use ExUnit.Case, async: true

  alias AshA2A.Semantic.AdmissionStanding, as: Standing

  test "the ladder starts at :candidate and terminates at :admitted" do
    assert Standing.initial() == :candidate
    assert Standing.terminal() == :admitted
    assert List.first(Standing.stages()) == :candidate
    assert List.last(Standing.stages()) == :admitted
  end

  test "advance/2 moves exactly one step forward" do
    assert {:ok, :parsed} = Standing.advance(:candidate, :parsed)
    assert {:ok, :identified} = Standing.advance(:parsed, :identified)
    assert {:ok, :admitted} = Standing.advance(:profile_conformant, :admitted)
  end

  test "advance/2 refuses a skipped stage rather than clamping to it" do
    assert {:error, %{code: :standing_transition_invalid, from: :candidate, to: :admitted}} =
             Standing.advance(:candidate, :admitted)

    assert {:error, %{code: :standing_transition_invalid}} =
             Standing.advance(:candidate, :shacl_conformant)
  end

  test "advance/2 refuses a regression and a repeat" do
    assert {:error, %{code: :standing_transition_invalid}} = Standing.advance(:admitted, :parsed)
    assert {:error, %{code: :standing_transition_invalid}} = Standing.advance(:parsed, :parsed)
  end

  test "advance/2 refuses an unknown standing" do
    assert {:error, %{code: :standing_transition_invalid}} =
             Standing.advance(:candidate, :made_up)

    assert {:error, %{code: :standing_transition_invalid}} = Standing.advance(:made_up, :parsed)
  end

  test "reached?/2 is a real ordering on the ladder" do
    assert Standing.reached?(:admitted, :parsed)
    assert Standing.reached?(:parsed, :parsed)
    refute Standing.reached?(:parsed, :admitted)
    refute Standing.reached?(:made_up, :parsed)
  end

  test "walking the whole ladder one step at a time is the only way to :admitted" do
    final =
      Enum.reduce(tl(Standing.stages()), Standing.initial(), fn next, current ->
        {:ok, advanced} = Standing.advance(current, next)
        advanced
      end)

    assert final == :admitted
    assert Standing.admitted?(final)
  end
end

# --- SECTION 17: Original test/ash_a2a/semantic_admission_test.exs ---
# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshA2A.Semantic.AdmissionTest do
  use ExUnit.Case, async: true

  alias AshA2A.Semantic.{Admission, IR, Source}

  test "grounds semantic admission in the source and preserves no authority" do
    source = Source.new("The goal is to lead the people.")
    {:ok, ir} = IR.from_map(source.id, proposal("The goal is to lead the people."))

    assert {:ok, admitted} = Admission.admit(source, ir)
    assert admitted.standing == :admitted
    assert admitted.authority == :none

    {:ok, ungrounded} = IR.from_map(source.id, proposal("not in the source"))
    assert {:error, %{code: :ungrounded_assertion}} = Admission.admit(source, ungrounded)
  end

  test "fence rejects an IR that is not a fresh unauthoritied candidate" do
    source = Source.new("The goal is to lead the people.")
    {:ok, ir} = IR.from_map(source.id, proposal("The goal is to lead the people."))

    already_admitted = %{ir | standing: :admitted}

    assert {:error, %{code: :semantic_authority_ceiling_violated}} =
             Admission.admit(source, already_admitted)

    invalid_authority = %{ir | authority: :invalid}

    assert {:error, %{code: :semantic_authority_ceiling_violated}} =
             Admission.admit(source, invalid_authority)
  end

  test "source_match rejects an IR whose source_id does not match the source" do
    source = Source.new("The goal is to lead the people.")
    {:ok, ir} = IR.from_map("some-other-source-id", proposal("The goal is to lead the people."))

    assert {:error, %{code: :semantic_source_mismatch}} = Admission.admit(source, ir)
  end

  test "require_goal rejects an IR with no goals" do
    source = Source.new("The goal is to lead the people.")
    {:ok, ir} = IR.from_map(source.id, proposal("The goal is to lead the people."))

    goalless = %{ir | goals: []}
    assert {:error, %{code: :semantic_goal_missing}} = Admission.admit(source, goalless)
  end

  test "unique_ids rejects duplicate ids across fields" do
    text = "The goal is to lead the people."
    source = Source.new(text)

    duplicate_goals = [
      %{
        "id" => "lead",
        "kind" => "goal",
        "description" => "lead the people",
        "source_quote" => text
      },
      %{"id" => "lead", "kind" => "goal", "description" => "lead again", "source_quote" => text}
    ]

    {:ok, ir} =
      proposal(text)
      |> Map.put("goals", duplicate_goals)
      |> then(&IR.from_map(source.id, &1))

    assert {:error, %{code: :semantic_identity_invalid}} = Admission.admit(source, ir)
  end

  test "unique_ids rejects an item missing an id" do
    text = "The goal is to lead the people."
    source = Source.new(text)

    missing_id_goals = [
      %{"kind" => "goal", "description" => "lead the people", "source_quote" => text}
    ]

    {:ok, ir} =
      proposal(text)
      |> Map.put("goals", missing_id_goals)
      |> then(&IR.from_map(source.id, &1))

    assert {:error, %{code: :semantic_identity_invalid}} = Admission.admit(source, ir)
  end

  test "validate_item rejects a relations item missing a required field" do
    text = "The goal is to lead the people."
    source = Source.new(text)

    relation_missing_predicate = [
      %{
        "id" => "rel-1",
        "kind" => "relation",
        "subject" => "lead",
        "object" => "people",
        "source_quote" => text
      }
    ]

    {:ok, ir} =
      proposal(text)
      |> Map.put("relations", relation_missing_predicate)
      |> then(&IR.from_map(source.id, &1))

    assert {:error,
            %{
              code: :semantic_fields_missing,
              detail: %{field: :relations, missing: ["predicate"]}
            }} =
             Admission.admit(source, ir)
  end

  test "validate_item rejects an authorities item with a non-admissible mode" do
    text = "The goal is to lead the people."
    source = Source.new(text)

    granted_authority = [
      %{
        "id" => "auth-1",
        "kind" => "authority",
        "subject" => "leader",
        "scope" => "people",
        "mode" => "granted",
        "source_quote" => text
      }
    ]

    {:ok, ir} =
      proposal(text)
      |> Map.put("authorities", granted_authority)
      |> then(&IR.from_map(source.id, &1))

    assert {:error, %{code: :authority_grant_not_admissible}} = Admission.admit(source, ir)
  end

  test "a non-map item is rejected before validate_item ever inspects it" do
    # Real pipeline order (Admission.admit/2) runs unique_ids/1 before
    # validate_items/1, so a non-map item is caught there first (its "id"
    # lookup safely yields nil for a non-map, which then fails the
    # is_binary/1 uniqueness check) -- validate_item/3's own non-map catch-all
    # clause (-> :semantic_item_invalid) can never actually fire for this
    # input shape. This pins that real, observed behavior rather than
    # asserting a code path unique_ids/1 preempts.
    text = "The goal is to lead the people."
    source = Source.new(text)

    {:ok, ir} =
      proposal(text)
      |> Map.put("goals", ["oops"])
      |> then(&IR.from_map(source.id, &1))

    assert {:error, %{code: :semantic_identity_invalid}} = Admission.admit(source, ir)
  end

  test "validate_item rejects an entities item whose label carries a real corporate legal-entity suffix, admits an equivalent one without" do
    text = "The board discussed a partnership with Example Corp as a potential vendor."
    source = Source.new(text)

    entity_with_suffix = [
      %{
        "id" => "vendor-1",
        "kind" => "entity",
        "type" => "organization",
        "label" => "Example Corp",
        "source_quote" => "Example Corp"
      }
    ]

    {:ok, ir_with_suffix} =
      proposal(text)
      |> Map.put("entities", entity_with_suffix)
      |> then(&IR.from_map(source.id, &1))

    assert {:error, %{code: :real_named_entity_not_admissible, detail: "vendor-1"}} =
             Admission.admit(source, ir_with_suffix)

    text2 =
      "The board discussed a partnership with a generic external vendor as a potential option."

    source2 = Source.new(text2)

    entity_without_suffix = [
      %{
        "id" => "vendor-2",
        "kind" => "entity",
        "type" => "organization",
        "label" => "a generic external vendor",
        "source_quote" => "a generic external vendor"
      }
    ]

    {:ok, ir_without_suffix} =
      proposal(text2)
      |> Map.put("entities", entity_without_suffix)
      |> then(&IR.from_map(source2.id, &1))

    assert {:ok, %{standing: :admitted}} = Admission.admit(source2, ir_without_suffix)
  end

  defp proposal(quote) do
    IR.fields()
    |> Map.new(&{Atom.to_string(&1), []})
    |> Map.put("authority", "none")
    |> Map.put("goals", [
      %{
        "id" => "lead",
        "kind" => "goal",
        "description" => "lead the people",
        "source_quote" => quote
      }
    ])
  end
end

# --- SECTION 18: Original test/ash_a2a/semantic_admission_vacuity_test.exs ---
# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshA2A.SemanticAdmissionVacuityTest do
  @moduledoc """
  Regression tests for the two reproduced admission defects in which a law
  document that asserts **nothing** produced `standing: :admitted` --
  `Unknown(Valid(x)) => Admitted(x)`, which RFC S43 forbids.

  Every case below drives the real `AshA2A.Semantic.AdmissionPipeline` against
  the real `praxis-graphlaw` wasm with the verifier's own minimal reproducing
  input, and asserts on the real returned `AshA2A.Semantic.AdmissionRefusal`
  struct. Nothing is mocked; there is no double anywhere in this file. When the
  real wasm is absent the module is a named, visible skip rather than a silent
  substitution -- the same posture
  `AshA2A.SemanticAdmissionPipelineEngineTest` already takes.

  Each defect is written as a **pair**: the vacuous candidate must refuse, and
  the corresponding real-law candidate over the same graph must reach the
  verdict the engine really produces. A test that only asserted the refusal
  would pass just as well if the pipeline had started refusing everything.
  """

  use ExUnit.Case, async: true

  alias AshA2A.GraphLaw.Wasm
  alias AshA2A.Semantic.AdmissionPipeline
  alias AshA2A.Semantic.AdmissionPipeline.Result
  alias AshA2A.Semantic.AdmissionRefusal, as: Refusal
  alias AshA2A.Test.SA2AAdmissionFixtures, as: Fixtures

  @graphlaw_availability AshA2A.GraphLaw.Wasm.availability()

  case @graphlaw_availability do
    :ok ->
      @moduletag :graphlaw

    {:error, detail} ->
      @moduletag skip:
                   "real GraphLaw wasm unavailable (#{inspect(detail)}) -- " <>
                     "these cases run the real engine and are never mocked"
  end

  defp engine_available?, do: Wasm.availability() == :ok

  describe "DEFECT 1: a required stage whose failure still yielded standing" do
    @tag :graphlaw
    test "the verifier's minimal repro -- a lawful candidate with garbage profile_ttl" do
      if engine_available?() do
        # Measured before the fix: this exact candidate returned
        # {:ok, %Result{standing: :admitted}} with
        # profile_hash == "af1349b9...", i.e. BLAKE3 of the empty string --
        # the engine had parsed zero profile axioms and reported OWL_RL
        # ADMITTED, and the pipeline's blankness guard read that as a pass.
        garbage = Fixtures.candidate(profile_ttl: "@@@ not turtle at all ;;; <<<")

        assert {:error, %Refusal{} = refusal} =
                 AdmissionPipeline.admit(garbage, Fixtures.law_opts())

        assert refusal.stage == :profile_checks
        assert refusal.code == :turtle_not_parseable
        assert refusal.determinacy == :undetermined
        assert refusal.detail.reason =~ "Turtle scanner error"
      end
    end

    @tag :graphlaw
    test "a profile that parses but declares no OWL/RDFS axiom is equally undetermined" do
      if engine_available?() do
        for vacuous <- ["#", "@prefix ex: <http://example.org/> .", "   \n\n  "] do
          assert {:error, %Refusal{stage: :profile_checks} = refusal} =
                   AdmissionPipeline.admit(
                     Fixtures.candidate(profile_ttl: vacuous),
                     Fixtures.law_opts()
                   )

          assert refusal.code in [:profile_vacuous, :profile_not_supplied]
          assert refusal.determinacy == :undetermined
        end
      end
    end

    @tag :graphlaw
    test "the same candidate with the real profile still reaches :admitted" do
      if engine_available?() do
        assert {:ok, %Result{standing: :admitted} = result} =
                 AdmissionPipeline.admit(Fixtures.candidate(), Fixtures.law_opts())

        # The real profile is not the empty-graph digest.
        refute result.profile_hash ==
                 "af1349b9f5f9a1a6a0404dea36dcc9499bcb25c9adc112b7cc9a93cae41f3262"
      end
    end
  end

  describe "DEFECT 2: Unknown(Valid(x)) => Admitted(x) (RFC S43)" do
    @tag :graphlaw
    test "the verifier's minimal repro -- a positively-refused candidate with falsifiers \"#\"" do
      if engine_available?() do
        # The engine POSITIVELY refuses this graph under the real falsifier
        # set: ex:b a ex:Forbidden fires { ?s a ex:Forbidden } => false .
        assert {:error, %Refusal{stage: :sparql_falsifiers} = determined} =
                 AdmissionPipeline.admit(
                   Fixtures.candidate(graph_ttl: Fixtures.graph_with_forbidden()),
                   Fixtures.law_opts()
                 )

        assert determined.code == :falsifier_violated
        assert determined.determinacy == :violated

        # Change the falsifiers to a lone comment and nothing else. Measured
        # before the fix: {:ok, %Result{standing: :admitted}} -- the very graph
        # the law refuses, admitted, because zero rules found zero violations.
        # The host admits "#" as law here, so the vacuity guard -- not law
        # standing -- is what refuses.
        assert {:error, %Refusal{stage: :sparql_falsifiers} = vacuous} =
                 AdmissionPipeline.admit(
                   Fixtures.candidate(
                     graph_ttl: Fixtures.graph_with_forbidden(),
                     falsifiers: "#"
                   ),
                   Fixtures.law_opts([{"n3_rules", "#"}])
                 )

        assert vacuous.code == :falsifiers_vacuous
        assert vacuous.determinacy == :undetermined

        # Without the host admitting it, the same document has no standing.
        assert {:error, %Refusal{stage: :rule_closure, code: :law_without_standing}} =
                 AdmissionPipeline.admit(
                   Fixtures.candidate(
                     graph_ttl: Fixtures.graph_with_forbidden(),
                     falsifiers: "#"
                   ),
                   Fixtures.law_opts()
                 )
      end
    end

    @tag :graphlaw
    test "second instance -- a SHACL-nonconformant candidate with shacl_shapes \"#\"" do
      if engine_available?() do
        assert {:error, %Refusal{stage: :shacl} = determined} =
                 AdmissionPipeline.admit(
                   Fixtures.candidate(graph_ttl: Fixtures.graph_missing_owner()),
                   Fixtures.law_opts()
                 )

        assert determined.code == :shacl_nonconformant
        assert determined.determinacy == :violated

        assert {:error, %Refusal{stage: :shacl} = vacuous} =
                 AdmissionPipeline.admit(
                   Fixtures.candidate(
                     graph_ttl: Fixtures.graph_missing_owner(),
                     shacl_shapes: "#"
                   ),
                   Fixtures.law_opts()
                 )

        assert vacuous.code == :shacl_shapes_vacuous
        assert vacuous.determinacy == :undetermined
      end
    end

    @tag :graphlaw
    test "third instance -- a ShEx schema declaring zero shapes" do
      if engine_available?() do
        assert {:error, %Refusal{stage: :shex} = vacuous} =
                 AdmissionPipeline.admit(
                   Fixtures.candidate(shex_schema: ~s({"shapes":[]})),
                   Fixtures.law_opts()
                 )

        assert vacuous.code == :shex_schema_vacuous
        assert vacuous.determinacy == :undetermined

        assert {:error, %Refusal{stage: :shex} = empty_map} =
                 AdmissionPipeline.admit(
                   Fixtures.candidate(shex_shape_map: "[]"),
                   Fixtures.law_opts()
                 )

        assert empty_map.code == :shex_shape_map_vacuous
      end
    end

    @tag :graphlaw
    test "the three instances compose: vacuous law everywhere never yields standing" do
      if engine_available?() do
        # All three at once, over the graph the real law positively refuses.
        assert {:error, %Refusal{determinacy: :undetermined}} =
                 AdmissionPipeline.admit(
                   Fixtures.candidate(
                     graph_ttl: Fixtures.graph_with_forbidden(),
                     profile_ttl: "#",
                     shacl_shapes: "#",
                     falsifiers: "#"
                   ),
                   Fixtures.law_opts()
                 )
      end
    end
  end

  describe "RFC S12 canonical identity comes from RDF.ex, not the wasm export" do
    @tag :graphlaw
    test "an admitted result carries a real RDFC-1.0 canonical hash alongside the engine digest" do
      if engine_available?() do
        assert {:ok, %Result{} = result} =
                 AdmissionPipeline.admit(Fixtures.candidate(), Fixtures.law_opts())

        assert result.canonical_graph_hash =~ ~r/\A[0-9a-f]{64}\z/

        {:ok, graph} = RDF.Turtle.read_string(Fixtures.conforming_graph())
        assert result.canonical_graph_hash == RDF.Graph.canonical_hash(graph)
      end
    end

    @tag :graphlaw
    test "the canonical hash is blank-node-relabel invariant where the wasm digest is not" do
      if engine_available?() do
        b1 = "_:b1 <http://example.org/p> <http://example.org/o> ."
        zzz = "_:zzz9 <http://example.org/p> <http://example.org/o> ."

        {:ok, wasm_b1} = Wasm.graph_hash(b1)
        {:ok, wasm_zzz} = Wasm.graph_hash(zzz)

        {:ok, g1} = RDF.Turtle.read_string(b1)
        {:ok, g2} = RDF.Turtle.read_string(zzz)

        # Measured engine fact, asserted rather than described: the wasm
        # export is NOT blank-node-relabel invariant, so it is not RDFC-1.0.
        refute wasm_b1 == wasm_zzz

        # RDF.ex's RDFC-1.0 implementation is.
        assert RDF.Graph.canonical_hash(g1) == RDF.Graph.canonical_hash(g2)
      end
    end
  end
end

# --- SECTION 19: Original test/ash_a2a/semantic_bounds_test.exs ---
# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshA2A.Semantic.BoundsTest do
  @moduledoc """
  RFC-SA2A-001 S34 (fan-out / depth / parallelism ceilings), S35 (resource
  envelope, fail closed), S73 (no blank check: a subtask may not manufacture
  authority or budget for itself; delegation may only narrow).

  Real struct, real state assertions. No mocks -- there is nothing here to
  mock: `AshA2A.Semantic.Bounds` is a pure value type and every assertion is
  on its real returned state or its real typed refusal.
  """
  use ExUnit.Case, async: true

  doctest AshA2A.Semantic.Bounds

  alias AshA2A.Semantic.Bounds

  defp envelope(opts \\ []) do
    {:ok, bounds} =
      Bounds.new(
        Keyword.merge(
          [
            fan_out: 4,
            depth: 2,
            parallelism: 3,
            resources: %{tokens: 1000, wall_ms: 5_000},
            capabilities: ["Res.read", "Res.write"]
          ],
          opts
        )
      )

    bounds
  end

  describe "S35 -- construction fails closed" do
    test "every ceiling is required; an omitted one is an error, not unlimited" do
      assert {:error, %{code: :bounds_ceiling_missing, detail: :fan_out}} =
               Bounds.new(depth: 1, parallelism: 1)

      assert {:error, %{code: :bounds_ceiling_missing, detail: :depth}} =
               Bounds.new(fan_out: 1, parallelism: 1)

      assert {:error, %{code: :bounds_ceiling_missing, detail: :parallelism}} =
               Bounds.new(fan_out: 1, depth: 1)
    end

    test ":infinity and negatives are refused, not coerced" do
      assert {:error, %{code: :bounds_ceiling_invalid, detail: %{field: :fan_out}}} =
               Bounds.new(fan_out: :infinity, depth: 1, parallelism: 1)

      assert {:error, %{code: :bounds_ceiling_invalid, detail: %{field: :depth}}} =
               Bounds.new(fan_out: 1, depth: -1, parallelism: 1)

      assert {:error, %{code: :bounds_ceiling_invalid, detail: %{field: :parallelism}}} =
               Bounds.new(fan_out: 1, depth: 1, parallelism: 0)
    end

    test "a constructed envelope carries no authority and cannot be given any" do
      bounds = envelope()
      assert bounds.authority == :none
      assert Bounds.fence(bounds) == :ok

      # Even if a struct is forced into an authority-bearing shape, the fence
      # refuses it and delegation from it is impossible.
      forged = %{bounds | authority: :granted}
      assert {:error, %{code: :bounds_authority_ceiling_violated}} = Bounds.fence(forged)
      assert {:error, %{code: :bounds_authority_ceiling_violated}} = Bounds.delegate(forged, [])
    end
  end

  describe "S34 -- fan-out, depth, and parallelism ceilings" do
    test "at the ceiling is admitted; one over is refused with the real numbers" do
      bounds = envelope()

      assert Bounds.admit_fan_out(bounds, 4) == :ok

      assert Bounds.admit_fan_out(bounds, 5) ==
               {:error, %{code: :bounds_fan_out_exceeded, detail: %{ceiling: 4, requested: 5}}}

      assert Bounds.admit_depth(bounds, 2) == :ok

      assert Bounds.admit_depth(bounds, 3) ==
               {:error, %{code: :bounds_depth_exceeded, detail: %{ceiling: 2, requested: 3}}}

      assert Bounds.admit_parallelism(bounds, 3) == :ok

      assert Bounds.admit_parallelism(bounds, 4) ==
               {:error,
                %{code: :bounds_parallelism_exceeded, detail: %{ceiling: 3, requested: 4}}}
    end

    test "a zero ceiling admits nothing at all" do
      bounds = envelope(fan_out: 0)
      assert Bounds.admit_fan_out(bounds, 0) == :ok
      assert {:error, %{code: :bounds_fan_out_exceeded}} = Bounds.admit_fan_out(bounds, 1)
    end

    test "a capability outside the delegated set is refused" do
      bounds = envelope()
      assert Bounds.admit_capability(bounds, "Res.read") == :ok

      assert Bounds.admit_capability(bounds, "Res.destroy") ==
               {:error, %{code: :bounds_capability_not_delegated, detail: "Res.destroy"}}
    end
  end

  describe "S35 -- the resource envelope fails closed on exhaustion" do
    test "spending reduces real remaining state and exhaustion refuses" do
      bounds = envelope()

      assert {:ok, after_first} = Bounds.consume(bounds, :tokens, 600)
      assert after_first.resources[:tokens] == 400

      assert {:ok, after_second} = Bounds.consume(after_first, :tokens, 400)
      assert after_second.resources[:tokens] == 0

      assert Bounds.consume(after_second, :tokens, 1) ==
               {:error,
                %{
                  code: :bounds_resource_exhausted,
                  detail: %{key: :tokens, remaining: 0, requested: 1}
                }}

      # Refusal is not a clamp: the envelope is unchanged and the other
      # budget is untouched.
      assert after_second.resources[:wall_ms] == 5_000
    end

    test "an unknown resource key is a refusal, never an implicitly unlimited budget" do
      assert Bounds.consume(envelope(), :gpu_seconds, 1) ==
               {:error, %{code: :bounds_resource_unknown, detail: :gpu_seconds}}
    end

    test "a negative spend (a covert refund) is refused" do
      assert {:error, %{code: :bounds_resource_amount_invalid}} =
               Bounds.consume(envelope(), :tokens, -100)
    end
  end

  describe "S73 -- no blank check: delegation may only narrow" do
    test "a subtask requesting MORE fan-out than delegated is refused, naming the field" do
      parent = envelope(fan_out: 2)

      assert Bounds.delegate(parent, fan_out: 3) ==
               {:error,
                %{
                  code: :bounds_delegation_not_narrowing,
                  detail: %{field: :fan_out, parent: 2, requested: 3}
                }}
    end

    test "a subtask requesting MORE budget than delegated is refused, naming the resource" do
      parent = envelope(resources: %{tokens: 100})

      assert Bounds.delegate(parent, resources: %{tokens: 101}) ==
               {:error,
                %{
                  code: :bounds_delegation_not_narrowing,
                  detail: %{field: {:resources, :tokens}, parent: 100, requested: 101}
                }}
    end

    test "a subtask requesting a capability it was never delegated is refused" do
      parent = envelope(capabilities: ["Res.read"])

      assert {:error,
              %{
                code: :bounds_delegation_not_narrowing,
                detail: %{field: :capabilities, requested: ["Res.destroy"]}
              }} = Bounds.delegate(parent, capabilities: ["Res.read", "Res.destroy"])
    end

    test "a subtask cannot request a resource key its parent does not hold at all" do
      parent = envelope(resources: %{tokens: 100})

      assert Bounds.delegate(parent, resources: %{gpu_seconds: 1}) ==
               {:error, %{code: :bounds_resource_unknown, detail: :gpu_seconds}}
    end

    test "a subtask cannot ask for authority at all, even :none" do
      assert {:error, %{code: :bounds_authority_not_delegable, detail: :none}} =
               Bounds.delegate(envelope(), authority: :none)

      assert {:error, %{code: :bounds_authority_not_delegable, detail: :granted}} =
               Bounds.delegate(envelope(), authority: :granted)
    end

    test "delegation strictly consumes a level of depth and bottoms out" do
      parent = envelope(depth: 1)

      assert {:ok, %{child: child}} = Bounds.delegate(parent, [])
      assert child.depth == 0

      # ... and a depth-0 envelope cannot delegate further.
      assert Bounds.delegate(child, []) ==
               {:error, %{code: :bounds_depth_exhausted, detail: 0}}
    end

    test "a subtask cannot request depth equal to its parent's (that would be an infinite ladder)" do
      parent = envelope(depth: 2)

      assert Bounds.delegate(parent, depth: 2) ==
               {:error,
                %{
                  code: :bounds_delegation_not_narrowing,
                  detail: %{field: :depth, parent: 1, requested: 2}
                }}
    end

    test "a legal narrowing delegation produces a real child AND debits the real parent" do
      parent = envelope(fan_out: 4, depth: 2, parallelism: 3, resources: %{tokens: 1000})

      assert {:ok, %{child: child, parent: debited}} =
               Bounds.delegate(parent,
                 fan_out: 2,
                 parallelism: 1,
                 resources: %{tokens: 300},
                 capabilities: ["Res.read"]
               )

      assert child.fan_out == 2
      assert child.depth == 1
      assert child.parallelism == 1
      assert child.resources == %{tokens: 300}
      assert MapSet.to_list(child.capabilities) == ["Res.read"]
      assert child.authority == :none

      # The budget was MOVED, not copied: the parent really lost it.
      assert debited.resources == %{tokens: 700}
      assert debited.fan_out == parent.fan_out
    end

    test "budget cannot be manufactured by delegating twice: the second delegation sees the debited parent",
         %{} do
      parent = envelope(resources: %{tokens: 100}, depth: 2)

      assert {:ok, %{child: first, parent: after_first}} =
               Bounds.delegate(parent, resources: %{tokens: 60})

      assert first.resources == %{tokens: 60}
      assert after_first.resources == %{tokens: 40}

      # A second subtask asking for 60 again is refused -- there are only 40
      # left. Without the debit this would have handed out 120 of a 100 budget.
      assert Bounds.delegate(after_first, resources: %{tokens: 60}) ==
               {:error,
                %{
                  code: :bounds_delegation_not_narrowing,
                  detail: %{field: {:resources, :tokens}, parent: 40, requested: 60}
                }}

      assert {:ok, %{child: second, parent: after_second}} =
               Bounds.delegate(after_first, resources: %{tokens: 40})

      assert second.resources == %{tokens: 40}
      assert after_second.resources == %{tokens: 0}

      # Conservation: nothing was created.
      assert first.resources[:tokens] + second.resources[:tokens] +
               after_second.resources[:tokens] == 100
    end

    test "a grandchild cannot exceed what its parent was itself delegated" do
      root = envelope(fan_out: 8, depth: 3, parallelism: 4, resources: %{tokens: 1000})

      assert {:ok, %{child: child}} =
               Bounds.delegate(root, fan_out: 3, resources: %{tokens: 100})

      assert Bounds.delegate(child, fan_out: 4) ==
               {:error,
                %{
                  code: :bounds_delegation_not_narrowing,
                  detail: %{field: :fan_out, parent: 3, requested: 4}
                }}

      assert Bounds.delegate(child, resources: %{tokens: 150}) ==
               {:error,
                %{
                  code: :bounds_delegation_not_narrowing,
                  detail: %{field: {:resources, :tokens}, parent: 100, requested: 150}
                }}

      assert {:ok, %{child: grandchild}} =
               Bounds.delegate(child, fan_out: 1, resources: %{tokens: 10})

      assert grandchild.depth == 1
      assert grandchild.authority == :none
    end
  end

  describe "Bounds is an envelope, never a grant (S28)" do
    test "holding budget for a capability is not authority for it" do
      bounds = envelope(capabilities: ["AshA2A.Test.Fixture.AuthorityProbe.actuate"])

      # The envelope does not forbid it ...
      assert Bounds.admit_capability(bounds, "AshA2A.Test.Fixture.AuthorityProbe.actuate") == :ok

      # ... and the envelope still carries no authority whatsoever. There is
      # no function on this module that returns an AshA2A.Authority, by
      # construction.
      assert bounds.authority == :none

      refute :erlang.function_exported(Bounds, :authority, 1)

      refute Enum.any?(Bounds.__info__(:functions), fn {name, _arity} ->
               name in [:grant, :issue, :authorize, :elevate]
             end)
    end
  end
end

# --- SECTION 20: Original test/ash_a2a/semantic_canonical_digest_test.exs ---
# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshA2A.Semantic.CanonicalDigestTest do
  @moduledoc """
  Real end-to-end coverage of `Ontology -> serialize -> verify -> native
  canonical hash` against the **real** prebuilt praxis-graphlaw WebAssembly
  engine.

  Chicago-school, no test double: every digest asserted below came out of the
  real `praxis_graphlaw_wasm_bg.wasm` module's linear memory, reached through
  a real `node` subprocess running the real host shim in `priv/graphlaw/`. The
  wasm module is instantiated with real host entropy (`crypto.randomFillSync`),
  not a fixed stub, so the determinism properties asserted here are real
  properties of the engine rather than artefacts of a pinned RNG.

  On a machine without the praxis workspace or without `node`, these tests
  **skip loudly and by name** (`@moduletag :graphlaw` plus a real
  availability check that prints the exact missing hop) -- never silently
  substituting a fake engine.
  """

  use ExUnit.Case, async: false

  @moduletag :serial
  @moduletag :serial_shard
  alias AshA2A.Semantic.{CanonicalDigest, GraphLawBridge, IR, Ontology, Serialize}

  # Published BLAKE3 test vector for the input "abc".
  @blake3_abc "6437b3ac38465133ffb63b75273a8db548c558465d79db03fd359c6cd5bd9d85"

  setup_all do
    case GraphLawBridge.host() do
      {:unavailable, reason} ->
        {:ok, skip_reason: reason}

      host ->
        {:ok, skip_reason: nil, host: host}
    end
  end

  setup %{skip_reason: skip_reason} do
    if skip_reason do
      IO.puts("\n  [skipped] real praxis-graphlaw host unavailable: #{inspect(skip_reason)}")
    end

    :ok
  end

  defp live?, do: match?(host when host in [:in_beam, :node_shim], GraphLawBridge.host())

  defp admitted_ir(opts) do
    label_a = Keyword.get(opts, :label_a, "Alice")
    order = Keyword.get(opts, :order, :forward)

    entities = [
      %{"id" => "e1", "kind" => "entity", "type" => "schema:Person", "label" => label_a},
      %{"id" => "e2", "kind" => "entity", "type" => "schema:Person", "label" => "Bob"}
    ]

    %IR{
      source_id: "src-1",
      standing: :admitted,
      authority: :none,
      entities: if(order == :forward, do: entities, else: Enum.reverse(entities)),
      relations: [
        %{
          "id" => "r1",
          "kind" => "relation",
          "subject" => "e1",
          "predicate" => "schema:knows",
          "object" => "e2"
        }
      ],
      goals: [
        %{
          "id" => "g1",
          "kind" => "goal",
          "description" => "Introduce " <> <<34>> <> "Alice" <> <<34>> <> " to Bob"
        }
      ]
    }
  end

  defp ontology!(opts \\ []) do
    {:ok, ontology} = Ontology.from_ir(admitted_ir(opts))
    ontology
  end

  describe "the real engine is reachable and is the engine we think it is" do
    @tag :graphlaw_engine
    test "graphlaw_version/0 returns a real version string from the wasm module" do
      if live?() do
        assert {:ok, version} = GraphLawBridge.version()
        assert version =~ "praxis-graphlaw"
      end
    end

    @tag :graphlaw_engine
    test "blake3_hex/1 reproduces the published BLAKE3 test vector for \"abc\"" do
      if live?() do
        assert {:ok, @blake3_abc} = GraphLawBridge.blake3_hex("abc")
      end
    end

    @tag :graphlaw_engine
    test "run_hooks/2 returns the real admission vocabulary, JSON-decoded" do
      if live?() do
        base = "<http://e/a> <http://e/p> <http://e/b> .\n"
        event = "<http://e/c> <http://e/p> <http://e/d> .\n"

        assert {:ok, %{"status" => status} = payload} = GraphLawBridge.run_hooks(base, event)
        assert status == "ADMITTED"
        assert Map.has_key?(payload, "verdicts")
        assert Map.has_key?(payload, "receipts")
      end
    end

    @tag :graphlaw_engine
    test "validate_all/6 returns the real dialect report, JSON-decoded" do
      if live?() do
        {:ok, nt} = Serialize.to_ntriples(ontology!())

        assert {:ok, %{"graph_hash" => graph_hash, "dialects" => dialects}} =
                 GraphLawBridge.validate_all(nt)

        assert graph_hash =~ ~r/^[0-9a-f]{64}$/
        assert is_list(dialects)
        assert Enum.any?(dialects, &(&1["dialect"] == "SHACL"))
      end
    end
  end

  describe "the RFC S12 path: Ontology -> serialize -> verify -> native canonical digest" do
    @tag :graphlaw_engine
    test "a real Ontology produces a real, verified 64-hex canonical digest" do
      if live?() do
        ontology = ontology!()
        assert {:ok, result} = CanonicalDigest.canonical_digest(ontology)

        assert result.algorithm == :graphlaw_graph_hash
        assert result.format == :ntriples
        assert result.verified == true
        assert result.digest =~ ~r/^[0-9a-f]{64}$/
        assert result.engine_version =~ "praxis-graphlaw"
        assert result.triple_count == length(ontology.triples)
        assert result.distinct_triple_count == result.triple_count
        assert result.document_bytes > 0
      end
    end

    @tag :graphlaw_engine
    test "the digest is syntax-independent: N-Triples and Turtle of the same graph agree" do
      # This is the property RFC S12 is actually asking for -- identity of the
      # *graph*, not of a chosen serialization.
      if live?() do
        ontology = ontology!()

        assert {:ok, nt_result} = CanonicalDigest.canonical_digest(ontology, format: :ntriples)
        assert {:ok, ttl_result} = CanonicalDigest.canonical_digest(ontology, format: :turtle)

        assert nt_result.digest == ttl_result.digest
        refute nt_result.document_bytes == ttl_result.document_bytes
      end
    end

    @tag :graphlaw_engine
    test "the digest is stable across repeated real engine invocations" do
      if live?() do
        ontology = ontology!()
        assert {:ok, first} = CanonicalDigest.digest(ontology)
        assert {:ok, second} = CanonicalDigest.digest(ontology)
        assert first == second
      end
    end

    @tag :graphlaw_engine
    test "the digest ignores IR item order (the graph is the same graph)" do
      if live?() do
        assert {:ok, forward} = CanonicalDigest.digest(ontology!(order: :forward))
        assert {:ok, reverse} = CanonicalDigest.digest(ontology!(order: :reverse))
        assert forward == reverse
      end
    end

    @tag :graphlaw_engine
    test "the digest changes when the graph actually changes" do
      if live?() do
        assert {:ok, alice} = CanonicalDigest.digest(ontology!(label_a: "Alice"))
        assert {:ok, carol} = CanonicalDigest.digest(ontology!(label_a: "Carol"))
        refute alice == carol
      end
    end

    @tag :graphlaw_engine
    test "document/2 returns the exact bytes the digest was taken over" do
      if live?() do
        ontology = ontology!()
        assert {:ok, document} = CanonicalDigest.document(ontology)
        assert {:ok, result} = CanonicalDigest.canonical_digest(ontology)
        assert byte_size(document) == result.document_bytes

        # The bytes are replayable: hashing them directly through the engine
        # reproduces the same identity.
        expected_digest = result.digest
        assert {:ok, ^expected_digest} = GraphLawBridge.graph_hash(document)
      end
    end
  end

  describe "what this digest fixes about Ontology.fingerprint/1 (RFC S12)" do
    # Ontology.fingerprint/1 is
    # `triples |> :erlang.term_to_binary() |> :crypto.hash(:sha256)` -- a
    # stable digest of a BEAM term, which is a different object from the RDF
    # graph that term denotes. `term_fingerprint/1` below replicates that one
    # line so the divergence can be exhibited rather than described.
    defp term_fingerprint(triples) do
      triples
      |> :erlang.term_to_binary()
      |> then(&:crypto.hash(:sha256, &1))
      |> Base.encode16(case: :lower)
    end

    @tag :graphlaw_engine
    test "two Elixir representations of the SAME RDF graph disagree under term_to_binary but agree under the engine" do
      if live?() do
        # Identical RDF graph. The only difference is how the object term is
        # spelled in Elixir: an inferred bare binary vs an explicit literal
        # tuple. Both denote the plain literal "Alice".
        bare = [
          %{
            subject: "urn:ash-a2a:semantic:node:e1",
            predicate: "https://schema.org/description",
            object: "Alice"
          }
        ]

        explicit = [
          %{
            subject: "urn:ash-a2a:semantic:node:e1",
            predicate: "https://schema.org/description",
            object: {:literal, "Alice"}
          }
        ]

        # The BEAM-term fingerprint says these are different objects.
        refute term_fingerprint(bare) == term_fingerprint(explicit)

        # The real engine, hashing the RDF graph, says they are the same graph.
        assert {:ok, bare_digest} = CanonicalDigest.digest(bare)
        assert {:ok, explicit_digest} = CanonicalDigest.digest(explicit)
        assert bare_digest == explicit_digest
      end
    end

    @tag :graphlaw_engine
    test "a plain literal and an explicit xsd:string literal are one RDF term to the engine" do
      if live?() do
        plain = [%{subject: "http://e/a", predicate: "http://e/p", object: {:literal, "hi"}}]

        typed = [
          %{
            subject: "http://e/a",
            predicate: "http://e/p",
            object: {:literal, "hi", datatype: "http://www.w3.org/2001/XMLSchema#string"}
          }
        ]

        refute term_fingerprint(plain) == term_fingerprint(typed)
        assert {:ok, plain_digest} = CanonicalDigest.digest(plain)
        assert {:ok, typed_digest} = CanonicalDigest.digest(typed)
        assert plain_digest == typed_digest
      end
    end
  end

  describe "measured limits of graph_hash/1 -- asserted so the docs cannot drift" do
    @tag :graphlaw_engine
    test "it is NOT duplicate-insensitive: it is a multiset digest, not an RDF-set digest" do
      if live?() do
        t = %{subject: "http://e/a", predicate: "http://e/p", object: {:iri, "http://e/b"}}

        assert {:ok, single} = CanonicalDigest.canonical_digest([t])
        assert {:ok, doubled} = CanonicalDigest.canonical_digest([t, t])

        # The RDF set is identical -- the parse-back gate proves it.
        assert single.distinct_triple_count == 1
        assert doubled.distinct_triple_count == 1
        assert doubled.triple_count == 2

        # ...but the engine's digest still differs. Recorded, not claimed away.
        refute single.digest == doubled.digest
      end
    end

    @tag :graphlaw_engine
    test "it is NOT blank-node canonical: relabelling a blank node changes the digest" do
      if live?() do
        a = [%{subject: {:bnode, "b0"}, predicate: "http://e/p", object: {:iri, "http://e/b"}}]
        b = [%{subject: {:bnode, "zzz"}, predicate: "http://e/p", object: {:iri, "http://e/b"}}]

        assert {:ok, digest_a} = CanonicalDigest.digest(a)
        assert {:ok, digest_b} = CanonicalDigest.digest(b)
        refute digest_a == digest_b
      end
    end

    @tag :graphlaw_engine
    test "it has no parse-error channel -- which is exactly why the gate exists" do
      if live?() do
        good = "<http://e/a> <http://e/p> <http://e/b> .\n"

        assert {:ok, good_digest} = GraphLawBridge.graph_hash(good)
        assert {:ok, garbage_digest} = GraphLawBridge.graph_hash("GARBAGE !!!\n")
        assert {:ok, empty_digest} = GraphLawBridge.graph_hash("")

        # Unparseable input is indistinguishable from the empty graph, and
        # both return a perfectly well-formed 64-hex digest rather than an error.
        assert garbage_digest == empty_digest
        assert garbage_digest =~ ~r/^[0-9a-f]{64}$/
        refute good_digest == garbage_digest
      end
    end
  end

  describe "the gate refuses before a bad graph can reach the engine" do
    test "an invalid IRI is refused with a typed code, never hashed" do
      assert {:error, %{code: :serialize_invalid_iri, reason: :iriref_forbidden_character}} =
               CanonicalDigest.canonical_digest([
                 %{subject: "http://e/a b", predicate: "http://e/p", object: {:literal, "v"}}
               ])
    end

    test "a malformed triple is refused with a typed code" do
      assert {:error, %{code: :serialize_malformed_triple}} =
               CanonicalDigest.canonical_digest([%{subject: "http://e/a"}])
    end

    test "an unknown format is refused" do
      assert {:error, %{code: :canonical_digest_unknown_format}} =
               CanonicalDigest.canonical_digest([], format: :jsonld)
    end

    test "a non-list subject is refused" do
      assert {:error, %{code: :canonical_digest_expected_triples}} =
               CanonicalDigest.canonical_digest(:nope)
    end
  end

  describe "host reporting" do
    test "host/1 names a real reachable host, or a typed reason it is not reachable" do
      case GraphLawBridge.host() do
        host when host in [:in_beam, :node_shim] ->
          assert GraphLawBridge.available?()

        {:unavailable, %{code: code}} ->
          assert code in [
                   :graphlaw_node_not_found,
                   :graphlaw_wasm_not_found,
                   :graphlaw_shim_not_found
                 ]
      end
    end

    test "a wrong wasm path is a typed refusal, not a crash" do
      assert {:unavailable, %{code: :graphlaw_wasm_not_found}} =
               GraphLawBridge.host(wasm_path: "/nonexistent/nope.wasm")

      assert {:error, %{code: :graphlaw_wasm_not_found}} =
               GraphLawBridge.graph_hash("<http://e/a> <http://e/p> <http://e/b> .\n",
                 wasm_path: "/nonexistent/nope.wasm"
               )
    end
  end
end

# --- SECTION 21: Original test/ash_a2a/semantic_canonical_term_digest_test.exs ---
# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshA2A.Semantic.CanonicalTermDigestTest do
  @moduledoc """
  The value-level digest the S23/S24/S26/S27 work depends on.

  The properties asserted here are the ones the RFC sections actually lean
  on: map-key order must not matter (or two identical plans digest
  differently and S27's drift check produces false positives), list order
  MUST matter (or two different plans digest identically and the check
  produces false negatives), and distinct values must not collide through
  the encoding.
  """

  use ExUnit.Case, async: true

  alias AshA2A.Semantic.CanonicalTermDigest

  test "digest/1 emits the SemanticSubject-compatible sha256: form" do
    assert CanonicalTermDigest.digest(%{a: 1}) =~ ~r/\Asha256:[0-9a-f]{64}\z/
  end

  test "map key insertion order does not change the digest" do
    a = %{} |> Map.put(:x, 1) |> Map.put(:y, 2) |> Map.put(:z, 3)
    b = %{} |> Map.put(:z, 3) |> Map.put(:y, 2) |> Map.put(:x, 1)

    assert a == b
    assert CanonicalTermDigest.digest(a) == CanonicalTermDigest.digest(b)
  end

  test "map key order does not change the digest even for large maps" do
    # Erlang switches map representation above 32 keys; the encoding must not
    # notice.
    pairs = for i <- 1..64, do: {:"k#{i}", i}
    forward = Enum.into(pairs, %{})
    backward = pairs |> Enum.reverse() |> Enum.into(%{})

    assert CanonicalTermDigest.digest(forward) == CanonicalTermDigest.digest(backward)
  end

  test "list order DOES change the digest -- plan step order is semantic" do
    refute CanonicalTermDigest.digest([1, 2, 3]) == CanonicalTermDigest.digest([3, 2, 1])
  end

  test "binaries with embedded delimiters do not collide" do
    refute CanonicalTermDigest.digest(["a", "b"]) == CanonicalTermDigest.digest(["a\",\"b"])
    refute CanonicalTermDigest.digest(["a,b"]) == CanonicalTermDigest.digest(["a", "b"])
  end

  test "a binary and the atom of the same name do not collide" do
    refute CanonicalTermDigest.digest("open") == CanonicalTermDigest.digest(:open)
  end

  test "tuples keep their order and are distinct from lists" do
    refute CanonicalTermDigest.digest({:a, [:b]}) == CanonicalTermDigest.digest([:a, [:b]])
    refute CanonicalTermDigest.digest({:a, :b}) == CanonicalTermDigest.digest({:b, :a})
  end

  test "structs digest by module and fields, so two structs with the same fields differ" do
    projection = %AshA2A.Semantic.CapabilityProfile{capability_id: "x"}

    plain = %{
      capability_id: "x",
      consequence: nil,
      preconditions: [],
      add_effects: [],
      delete_effects: [],
      authority_requirement: %{}
    }

    refute CanonicalTermDigest.digest(projection) == CanonicalTermDigest.digest(plain)

    # feat/sa2a-bounds-evidence-fixes-v26.9.16 ported this test without
    # `CapabilityProfile` in its closure and substituted
    # `Allocator.Budget`, a real struct with the same property. Both are
    # on main, so both are asserted.
    budget = AshA2A.Semantic.Allocator.new!([tokens: 10], issued_by: {:host, :digest_test})

    refute CanonicalTermDigest.digest(budget) ==
             CanonicalTermDigest.digest(Map.from_struct(budget))

    # And two different struct modules never share a digest.
    refute CanonicalTermDigest.digest(%URI{path: "/x"}) ==
             CanonicalTermDigest.digest(%Version.Requirement{source: "/x", lexed: []})
  end

  test "encode/1's bytes are inspectable, so a digest mismatch is debuggable" do
    assert IO.iodata_to_binary(CanonicalTermDigest.encode(%{b: 2, a: 1})) == "{:a=1,:b=2}"
    assert IO.iodata_to_binary(CanonicalTermDigest.encode([:x, "y"])) == "[:x,\"y\"]"
    assert IO.iodata_to_binary(CanonicalTermDigest.encode({:at, [:room]})) == "(:at,[:room])"
    assert IO.iodata_to_binary(CanonicalTermDigest.encode(nil)) == "nil"
  end
end

