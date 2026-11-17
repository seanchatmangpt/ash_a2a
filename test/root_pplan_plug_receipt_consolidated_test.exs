# NOTE: 6 module(s) removed from this consolidated file because the repaired originals (kept as separate files) define the same modules; see docs/reference/test-consolidation-merge.md.
# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
# SPDX-License-Identifier: MIT

# ==============================================================================
# Consolidated Test Suite: Root PPlan, Plug, Receipt
# Target File 2 of Worker 02
# Consolidated from 22 source files:
#   - test/ash_a2a_ocel_default_path_sink_test.exs
#   - test/ash_a2a_on_cancel_hook_test.exs
#   - test/ash_a2a_pack_replay_court_test.exs
#   - test/ash_a2a_partisan_integration_test.exs
#   - test/ash_a2a_passport_test.exs
#   - test/ash_a2a_planning_hddl_solver_crossvm_test.exs
#   - test/ash_a2a_plug_agent_card_test.exs
#   - test/ash_a2a_plug_auth_test.exs
#   - test/ash_a2a_plug_authorize_refusal_receipt_test.exs
#   - test/ash_a2a_plug_tenant_actor_test.exs
#   - test/ash_a2a_pplan_durability_test.exs
#   - test/ash_a2a_pplan_notify_test.exs
#   - test/ash_a2a_pplan_ocel_evidence_court_test.exs
#   - test/ash_a2a_property_fuzz_test.exs
#   - test/ash_a2a_protocol_card_cache_test.exs
#   - test/ash_a2a_protocol_card_signing_test.exs
#   - test/ash_a2a_protocol_extension_e2e_test.exs
#   - test/ash_a2a_protocol_plug_jwks_test.exs
#   - test/ash_a2a_push_notification_config_test.exs
#   - test/ash_a2a_rap_battle_integration_test.exs
#   - test/ash_a2a_receipt_r_projection_test.exs
#   - test/ash_a2a_receipt_replay_counting_actuator_test.exs
# ==============================================================================

# --- SECTION 1: Original test/ash_a2a_ocel_default_path_sink_test.exs ---
# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
#
# SPDX-License-Identifier: MIT



# --- SECTION 2: Original test/ash_a2a_on_cancel_hook_test.exs ---
# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshA2A.OnCancelHookTest do
  @moduledoc """
  Real, unmocked coverage for the ARD task-lifecycle gap: task cancellation
  semantics needed a real, observable hook a resource author can use for
  Ash-side compensation on cancel (`AshA2A.OnCancel`, the `on_cancel:` skill
  option in `AshA2A.Dsl`).

  Same real in-flight mechanism as `test/ash_a2a_cancel_inflight_test.exs`
  (a streaming `:read` skill produces a genuinely `:working`, non-terminal
  task with the agent's mailbox free -- see that file and
  `test/support/cancel_fixture.ex` for the full rationale). This file adds
  a real `on_cancel:` hook to the skill and asserts on real state a
  supervised `Agent` recorded (`AshA2A.Test.Fixture.OnCancelRecorder`), not
  on "was this called".

  No `Mock`/`mox`/`patch`/`monkeypatch` anywhere in this file: the resource,
  the agent, the supervisor, the stream, the hook module, the recorder
  `Agent`, and the cancel call are all real.
  """

  use ExUnit.Case, async: true

  import AshA2A.Test.MessageHelpers

  alias AshA2A.Test.Fixture.OnCancelErrorStreamItem
  alias AshA2A.Test.Fixture.OnCancelErrorStreamItemAgent
  alias AshA2A.Test.Fixture.OnCancelRecorder
  alias AshA2A.Test.Fixture.OnCancelStreamItem
  alias AshA2A.Test.Fixture.OnCancelStreamItemAgent

  test "a real on_cancel hook runs real Ash-side compensation on a genuine cancel" do
    {:ok, _recorder} = start_supervised(OnCancelRecorder)

    {_sup, _registry_name} =
      AshA2A.Test.AgentSupervisorCase.start_supervised_agents!(__MODULE__, [
        OnCancelStreamItemAgent
      ])

    Ash.create!(OnCancelStreamItem, %{label: "one"})

    message = data_message(%{"stream" => true}, %{metadata: %{"skill" => "list_items"}})

    assert {:ok, task} = OnCancelStreamItemAgent.call(OnCancelStreamItemAgent, message)
    assert task.status.state == :working
    assert is_function(task.metadata[:stream])

    # Real proof the hook has not already run before cancel: nothing
    # recorded yet.
    assert OnCancelRecorder.records() == []

    assert :ok = OnCancelStreamItemAgent.cancel(OnCancelStreamItemAgent, task.id)

    assert {:ok, canceled_task} =
             OnCancelStreamItemAgent.get_task(OnCancelStreamItemAgent, task.id)

    assert canceled_task.status.state == :canceled

    # Real state, not an interaction assertion: the hook module really ran
    # and really appended to the real recorder `Agent`.
    assert [{exec_context, task_id, context_id}] = OnCancelRecorder.records()
    assert task_id == task.id
    assert context_id == task.context_id
    assert exec_context.domain == OnCancelStreamItem
  end

  test "a raising on_cancel hook is caught, cancel still succeeds, and the failure is reported" do
    {_sup, _registry_name} =
      AshA2A.Test.AgentSupervisorCase.start_supervised_agents!(__MODULE__, [
        OnCancelErrorStreamItemAgent
      ])

    Ash.create!(OnCancelErrorStreamItem, %{label: "one"})

    handler_id = "on-cancel-hook-error-telemetry-#{inspect(make_ref())}"
    test_pid = self()

    :telemetry.attach(
      handler_id,
      [:ash_a2a, :agent, :cancel_hook_error],
      fn _event, _measurements, metadata, _config ->
        send(test_pid, {:ash_a2a_cancel_hook_error_telemetry, metadata})
      end,
      nil
    )

    on_exit(fn -> :telemetry.detach(handler_id) end)

    message = data_message(%{"stream" => true}, %{metadata: %{"skill" => "list_items"}})

    assert {:ok, task} =
             OnCancelErrorStreamItemAgent.call(OnCancelErrorStreamItemAgent, message)

    assert task.status.state == :working

    # The real assertion: a hook that raises does not crash the cancel
    # call -- `handle_cancel/1`'s `:ok` contract with `AshA2A.Protocol.Agent`'s own
    # state machine holds regardless.
    assert :ok = OnCancelErrorStreamItemAgent.cancel(OnCancelErrorStreamItemAgent, task.id)

    assert {:ok, canceled_task} =
             OnCancelErrorStreamItemAgent.get_task(OnCancelErrorStreamItemAgent, task.id)

    assert canceled_task.status.state == :canceled

    # Pinned on task_id: async modules cancel concurrently and fire the same
    # global telemetry event, so the first message may belong to another test.
    task_id = task.id

    assert_receive {:ash_a2a_cancel_hook_error_telemetry, %{task_id: ^task_id} = error_meta},
                   1_000

    assert error_meta.task_id == task.id
    assert error_meta.resource_or_domain == OnCancelErrorStreamItem
    assert error_meta.error.kind == :error
    assert error_meta.error.reason =~ "deliberate on_cancel hook failure"
  end
end

# --- SECTION 3: Original test/ash_a2a_pack_replay_court_test.exs ---
defmodule AshA2A.PackReplayCourtTest do
  @moduledoc """
  Byte-identical replay court for the self-hosted marketplace projection (`ggen.toml`).

  Copies the consumer inputs (`ggen.toml`, `priv/sa2a/AllSA2A.ttl`, empty `templates/`) into two
  fresh temp dirs, runs `ggen sync run` in each, and asserts:

    1. REPLAY: both runs produce byte-identical `generated/` trees.
    2. COMMITTED: that tree is byte-identical to the repo's committed `generated/`.

  Skips loudly (compile-time stderr line plus an ExUnit skip reason) when `ggen` is not on PATH,
  or when the pack path pinned in `ggen.toml` is absent on this machine.

  ## Mutation note (what flips it)

    * Insert a nondeterministic value (timestamp, random id, map-order dependent output) into a
      `canonical-ash-projection-generator` template: REPLAY flips red.
    * Edit `priv/sa2a/AllSA2A.ttl` (or a pack template) without re-running `ggen sync run` and
      committing `generated/`: COMMITTED flips red.
    * Hand-edit any file under `generated/`: COMMITTED flips red.
  """
  use ExUnit.Case, async: false

  @root Path.expand("..", __DIR__)

  @skip_reason (cond do
                  is_nil(System.find_executable("ggen")) ->
                    "ggen not found on PATH"

                  true ->
                    case File.read(Path.join(Path.expand("..", __DIR__), "ggen.toml")) do
                      {:ok, toml} ->
                        case Regex.run(~r/path\s*=\s*"([^"]+)"/, toml) do
                          [_, pack] ->
                            if File.dir?(pack), do: nil, else: "pack path absent: #{pack}"

                          _ ->
                            "no pack path in ggen.toml"
                        end

                      _ ->
                        "ggen.toml unreadable"
                    end
                end)

  if @skip_reason do
    IO.puts(:stderr, "[SKIP] pack replay court: #{@skip_reason}")
    @moduletag skip: @skip_reason
  end

  @moduletag :pack_replay

  defp project!(label) do
    dir =
      Path.join(System.tmp_dir!(), "pack_replay_#{label}_#{System.unique_integer([:positive])}")

    on_exit(fn -> File.rm_rf(dir) end)
    File.mkdir_p!(Path.join(dir, "templates"))
    File.mkdir_p!(Path.join(dir, "priv/sa2a"))
    File.cp!(Path.join(@root, "ggen.toml"), Path.join(dir, "ggen.toml"))
    File.cp!(Path.join(@root, "priv/sa2a/AllSA2A.ttl"), Path.join(dir, "priv/sa2a/AllSA2A.ttl"))

    {out, status} = System.cmd("ggen", ["sync", "run"], cd: dir, stderr_to_stdout: true)
    assert status == 0, "ggen sync run failed (#{status}):\n#{out}"
    dir
  end

  defp tree(dir) do
    base = Path.join(dir, "generated")

    base
    |> Path.join("**/*")
    |> Path.wildcard(match_dot: true)
    |> Enum.filter(&File.regular?/1)
    |> Enum.sort()
    |> Map.new(fn f -> {Path.relative_to(f, base), File.read!(f)} end)
  end

  test "two fresh ggen sync runs produce byte-identical generated/ trees" do
    a = tree(project!("a"))
    b = tree(project!("b"))
    assert map_size(a) > 0, "ggen produced no generated/ files"
    assert a == b
  end

  test "replayed generated/ is byte-identical to the committed generated/" do
    replay = tree(project!("c"))
    committed = tree(@root)
    assert committed != %{}, "no committed generated/ tree"
    assert Map.keys(replay) == Map.keys(committed)

    for {rel, bytes} <- replay do
      assert bytes == Map.fetch!(committed, rel), "generated/#{rel} drifted from committed bytes"
    end
  end
end

# --- SECTION 4: Original test/ash_a2a_partisan_integration_test.exs ---
# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshA2A.PartisanIntegrationTest do
  @moduledoc """
  Tracking court for the permanently-BLOCKED Partisan integration
  tombstone (audit finding #6; origin: v26.9.16
  `feat/partisan-investigate-v26.9.16`, full evidence in
  `docs/archive/reports/partisan-integration-investigation.md`).

  The original integration test (two real local BEAM nodes joining over
  Partisan's own overlay via `partisan:join/1`, one real message delivered
  via `partisan:cast_message/2`) could never run: every Partisan Hex
  release up to 6.2.0 hard-pins the non-optional `telemetry ~> 1.1.0`,
  which does not overlap this repo's already-required
  `oban ~> 2.24` -> `telemetry ~> 1.3` (locked at 1.4.2). A second,
  independent conflict layer (Partisan's exact `opentelemetry_api 1.2.1`
  pin vs. this repo's transitive `opentelemetry_api ~> 1.4`) was also
  confirmed. Partisan was therefore never added to `mix.exs`/`mix.lock`.

  The dead tombstone (an unconditionally `@tag :skip`ped test whose body
  was `flunk("unreachable")`) carried a re-check mechanism of zero bits --
  it could never observe the day the blocker clears. This court replaces
  it with a real observation, executed every run, read-only, no writes to
  `mix.exs`/`mix.lock`:

  1. Query the live Hex API for the Partisan package's releases and their
     real published `telemetry` requirements.
  2. If any existing release's telemetry requirement admits the telemetry
     version this repo locks (`1.4.2`), the blocker is gone: the test
     FAILS with a typed `PARTISAN_BLOCKER_CLEARED` message forcing revival
     of the real two-node integration test (and de-tombstoning of
     `docs/archive/reports/partisan-integration-investigation.md`).
  3. If no release's telemetry requirement admits the locked telemetry
     version, the known-conflict state is asserted explicitly with the
     release evidence inlined, so the tombstone is re-witnessed rather
     than passing vacuously.

  This test does NOT attempt the upgrade and does NOT mock the Hex API.
  Per `~/.claude/rules/testing-chicago-style.md` the collaborator (the
  real Hex registry over real HTTPS) is used directly.
  """

  use ExUnit.Case, async: false

  # Deliberately NOT tagged :serial/:serial_shard: unlike the dead tombstone
  # (which was also excluded from every default run, i.e. re-checked zero
  # bits per run), this court must execute by default. It is a read-only
  # Hex API observation, not a clustering test.
  @moduletag :partisan_investigation

  @hex_api "https://hex.pm/api/packages/partisan"
  # Telemetry version this repo actually locks (mix.lock: telemetry 1.4.2,
  # required by oban ~> 2.24 as `~> 1.3`).
  @locked_telemetry {1, 4, 2}

  defp parse_version(v) do
    v
    |> to_string()
    |> String.split("-")
    |> hd()
    |> String.split(".")
    |> Enum.map(&String.to_integer/1)
    |> pad3()
  end

  defp pad3([major]), do: [major, 0, 0]
  defp pad3([major, minor]), do: [major, minor, 0]
  defp pad3(v), do: v

  defp ver_to_tuple([a, b, c]), do: {a, b, c}

  # Minimal requirement evaluator for the shapes Partisan actually
  # publishes for telemetry ("~> 1.1.0", "~> 1.1", ">= 1.3", "1.2.1", ...).
  # Returns true when `req` admits `version`.
  defp admits?(req, version) do
    req = to_string(req) |> String.trim()

    cond do
      String.starts_with?(req, "~>") ->
        range_str = String.split(req, "~>") |> Enum.at(1) |> String.trim()
        components = String.split(range_str, ".")
        [req_major, req_minor | _rest] = parse_version(range_str)
        {v_major, v_minor, _} = version

        if length(components) >= 3 do
          # patch-pinned: "~> 1.1.0" admits only 1.1.x
          v_major == req_major and v_minor == req_minor
        else
          # "~> 1.1" / "~> 1.3" admit any 1.x at or above the minor floor
          # (up to, excluding, 2.0)
          v_major == req_major and v_minor >= req_minor
        end

      String.starts_with?(req, ">=") ->
        [req_major, req_minor, req_patch] =
          parse_version(String.split(req, ">=") |> Enum.at(1) |> String.trim())

        version >= {req_major, req_minor, req_patch}

      req =~ ~r/^\d/ ->
        {req_major, req_minor, req_patch} = ver_to_tuple(parse_version(req))
        version == {req_major, req_minor, req_patch}

      true ->
        # Unrecognized shape: conservatively treat as NOT admitting the
        # locked version, so the court cannot silently go green.
        false
    end
  end

  defp hex_get(url, attempts_left \\ 3)

  defp hex_get(_url, 0),
    do: flunk("PARTISAN_TRACKING_COURT_NETWORK: hex.pm unreachable after retries")

  defp hex_get(url, attempts_left) do
    {:ok, _} = Application.ensure_all_started(:inets)
    {:ok, _} = Application.ensure_all_started(:ssl)

    headers = [
      {~c"user-agent", ~c"ash_a2a partisan-integration tracking court (hex.pm/ash_a2a)"}
    ]

    request =
      :httpc.request(
        :get,
        {String.to_charlist(url), headers},
        [
          ssl: [verify: :verify_peer, cacerts: :public_key.cacerts_get()],
          timeout: 15_000,
          connect_timeout: 15_000
        ],
        []
      )

    case request do
      {:ok, {{_, 200, _}, _, body}} ->
        to_string(body)

      {:ok, {{_, status, _}, _, _}} ->
        flunk("PARTISAN_TRACKING_COURT_HTTP_#{status}: unexpected status from #{url}")

      {:error, _reason} ->
        # SLEEP-CLASS: REAL-INTERVAL (audited AshA2A.TestSupport.Eventually.pause)
        AshA2A.TestSupport.Eventually.pause(1_000)
        hex_get(url, attempts_left - 1)
    end
  end

  test "Partisan Hex releases are re-witnessed against this repo's telemetry pin (tracking court)" do
    body = hex_get(@hex_api)
    assert {:ok, package} = Jason.decode(body)

    releases = package["releases"]
    assert is_list(releases) and releases != [], "Hex API returned no releases for partisan"

    # Fetch each release's real published requirements (latest first).
    checked =
      for release <- releases,
          version = release["version"],
          {:ok, rel} = Jason.decode(hex_get("#{@hex_api}/releases/#{version}")),
          telemetry_req = get_in(rel, ["requirements", "telemetry", "requirement"]) do
        {version, telemetry_req, admits?(telemetry_req, @locked_telemetry)}
      end

    assert checked != [],
           "PARTISAN_TRACKING_COURT_EMPTY: no partisan release on Hex publishes a telemetry requirement; manual re-check required"

    compatible = for {version, req, true} <- checked, do: {version, req}
    latest = hd(checked)

    # The assertion IS the court: while Hex shows no telemetry-compatible
    # release, the known-conflict assertion holds (suite green, evidence
    # receipt printed below). The moment any release admits the locked
    # telemetry version, this assertion fails typed and forces revival.
    assert compatible == [],
           """
           PARTISAN_BLOCKER_CLEARED: Partisan release(s) #{inspect(compatible)} now admit \
           telemetry #{inspect(@locked_telemetry)}. The hex-resolution blocker documented in \
           docs/archive/reports/partisan-integration-investigation.md is STALE. Revive the real \
           two-node Partisan integration test now: add `{:partisan, "~> ...", only: :dev}` to \
           mix.exs, run `mix deps.get`, and restore the partisan:join/cast_message test body. \
           De-tombstone the investigation report in the same transition.\
           """

    IO.puts("""
    [partisan tombstone re-witnessed #{Date.utc_today()}] BLOCKED state still accurate: \
    #{length(checked)} Hex releases checked (latest #{elem(latest, 0)}), none admits \
    telemetry #{inspect(@locked_telemetry)} (oban ~> 2.24 lock). Latest requirement: \
    #{elem(latest, 1)}. Per-release: #{inspect(checked, limit: 20)}\
    """)
  end

  test "requirement evaluator admits only telemetry ranges that genuinely cover the locked version" do
    # Negative controls: the shapes that caused the original blocker.
    refute admits?("~> 1.1.0", @locked_telemetry)
    refute admits?("~>1.1.0", @locked_telemetry)
    refute admits?("1.2.1", @locked_telemetry)
    # Positive controls: shapes that would clear the blocker.
    assert admits?("~> 1.3", @locked_telemetry)
    assert admits?("~> 1.1", @locked_telemetry)
    assert admits?(">= 1.3", @locked_telemetry)
    assert admits?(">= 1.0", @locked_telemetry)
    # Unrecognized shape must not silently admit.
    refute admits?("banana", @locked_telemetry)
  end
end

# --- SECTION 5: Original test/ash_a2a_passport_test.exs ---

# --- SECTION 6: Original test/ash_a2a_planning_hddl_solver_crossvm_test.exs ---
# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshA2A.PlanningHddlSolverCrossvmTest do
  @moduledoc """
  Reproduction of the v26.9.17 multinode-stress defect: `HddlSolver`
  cross-VM temp-file collision. TWO real `:peer` BEAM nodes (same real
  `:peer.start_link/1` + `:code.add_pathsz/1` pattern
  `test/ash_a2a/multinode_cluster_test.exs` established) each drive the real
  `AshA2A.Planning.HddlSolver.solve/3` -- real temp files + real
  `native/hddl_cli` OS subprocess -- CONCURRENTLY, one with a genuinely
  solvable pair, the other with a genuinely unsolvable one, and each node's
  real outcomes must stay consistent with ITS OWN inputs.

  The defect, precisely: `System.unique_integer/1` is documented unique "for
  the current VM instance" only. Two FRESH peer VMs' monotonic counters both
  start at the same value, and both VMs resolve the same `System.tmp_dir!/0`
  (a `:peer` node is a child OS process inheriting the parent's
  environment), so same-sequence invocations on both nodes derive the SAME
  absolute temp paths. The concurrent `File.write!/2` + `File.rm/1` pairs
  then overwrite/delete each other's files mid-solve: the solvable node's
  solver reads the unsolvable node's bytes (or its file vanishes before the
  subprocess opens it), flipping real outcomes across VMs.

  ## What is forced, disclosed plainly

  * The wall-clock start barrier (`AshA2A.Test.HddlSolverCrossvmDispatch`)
  synchronizes both peers' first solve to the same millisecond on this
  shared host -- in the production stress shape the contention was organic;
  here it is forced so the test is deterministic rather than load-dependent.
  * `tmp_dir` is passed explicitly to both peers so the collision is
  hermetic and the directory cleanup is owned by this test. This matches
  production (both nodes would share the OS tmp dir anyway); nothing about
  the paths themselves is forced -- the old node-blind
  `System.unique_integer` naming must collide all by itself.

  Per the ticket's fail-before gate this test failed against the unfixed
  `HddlSolver` (cross-contaminated outcomes across the two peers); the
  per-node unique temp-path fix in `HddlSolver.run/4` makes both peers'
  paths disjoint and this green.
  """

  use ExUnit.Case, async: false

  @moduletag :serial
  @moduletag :serial_solo
  alias AshA2A.Test.HddlSolverCrossvmDispatch

  @cli_path Path.expand("../native/hddl_cli/target/release/hddl_cli", __DIR__)

  @solvable_domain Path.expand("support/hddl/freedom_gym_meeting/domain.hddl", __DIR__)
  @solvable_problem Path.expand("support/hddl/freedom_gym_meeting/problem.hddl", __DIR__)

  @unsolvable_domain Path.expand("support/hddl/unsolvable_qualification/domain.hddl", __DIR__)
  @unsolvable_problem Path.expand("support/hddl/unsolvable_qualification/problem.hddl", __DIR__)

  # Enough same-sequence iterations that both peers' unique_integer
  # sequences overlap for several pairs even if one side drifts ahead.
  @iterations 8

  setup_all do
    unless File.exists?(@cli_path) do
      flunk("""
      hddl_cli binary not built at #{@cli_path}.
      Run: cd #{Path.expand("../native/hddl_cli", __DIR__)} && cargo build --release --locked
      """)
    end

    # Real, idempotent -- same defensive epmd + distributed-primary pattern
    # `AshA2A.MultinodeClusterTest` uses, so this file is self-sufficient
    # when run in isolation.
    System.cmd("epmd", ["-daemon"], stderr_to_stdout: true)

    already_alive? = Node.alive?()

    unless already_alive? do
      primary_name = :"ash_a2a_hddl_crossvm_primary_#{System.pid()}"
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

  defp start_real_peer(host, cookie, code_paths) do
    peer_name = :"ash_a2a_hddl_crossvm_peer_#{System.unique_integer([:positive, :monotonic])}"

    start_opts = %{
      name: peer_name,
      host: host,
      # A loaded full-suite run (cover-instrumented, async modules) can exceed
      # :peer's 15s default boot wait; a slow boot is not a failure.
      wait_boot: 60_000,
      args: [~c"-setcookie", Atom.to_charlist(cookie)]
    }

    {:ok, peer_pid, peer_node} = :peer.start_link(start_opts)

    assert :ok = :rpc.call(peer_node, :code, :add_pathsz, [code_paths])

    {peer_pid, peer_node}
  end

  # Same real, empirically-found teardown constraint
  # `AshA2A.MultinodeClusterTest` documents: `:peer.stop/1` must run on the
  # same process that called `:peer.start_link/1`, so teardown lives in this
  # test body's `try/after`, never in `on_exit/1`.
  defp stop_if_alive(peer_pid) do
    if Process.alive?(peer_pid) do
      :peer.stop(peer_pid)
    end

    :ok
  end

  @tag :crossvm_hddl
  test "two concurrent peer VMs solving different HDDL pairs get outcomes consistent with their OWN inputs (no cross-VM temp-file collision)",
       %{cookie: cookie, host: host, code_paths: code_paths} do
    {pid_a, node_a} = start_real_peer(host, cookie, code_paths)
    {pid_b, node_b} = start_real_peer(host, cookie, code_paths)

    # Hermetic, explicitly-shared temp dir -- identical to the production
    # shape (peer child processes inherit the parent's OS tmp dir); see this
    # module's @moduledoc "What is forced".
    tmp_dir =
      Path.join(System.tmp_dir!(), "ash_a2a_hddl_crossvm_repro_#{System.unique_integer()}")

    File.mkdir_p!(tmp_dir)

    try do
      assert node_a != node_b

      solvable_domain = File.read!(@solvable_domain)
      solvable_problem = File.read!(@solvable_problem)
      unsolvable_domain = File.read!(@unsolvable_domain)
      unsolvable_problem = File.read!(@unsolvable_problem)

      # Real cross-node start barrier: one shared host wall clock.
      start_ms = System.system_time(:millisecond) + 2_000

      task_a =
        Task.async(fn ->
          :erpc.call(
            node_a,
            HddlSolverCrossvmDispatch,
            :solve_barrier_until,
            [start_ms, @iterations, tmp_dir, solvable_domain, solvable_problem],
            60_000
          )
        end)

      task_b =
        Task.async(fn ->
          :erpc.call(
            node_b,
            HddlSolverCrossvmDispatch,
            :solve_barrier_until,
            [start_ms, @iterations, tmp_dir, unsolvable_domain, unsolvable_problem],
            60_000
          )
        end)

      {solver_node_a, results_a} = Task.await(task_a, 60_000)
      {solver_node_b, results_b} = Task.await(task_b, 60_000)

      # Both sides really executed on their own distinct remote peers.
      assert solver_node_a == node_a and solver_node_a != node()
      assert solver_node_b == node_b and solver_node_b != node()
      assert solver_node_a != solver_node_b

      # Node A solved the genuinely solvable pair -- EVERY invocation must
      # have really solved. Under the old node-blind temp naming, node B's
      # concurrent unsolvable bytes (or B's mid-flight File.rm of the same
      # absolute path) surface here as {:error, :hddl_solve_error} /
      # {:error, :non_json_stdout}.
      assert results_a == List.duplicate({:ok, true}, @iterations),
             "node A (solvable pair) got cross-contaminated outcomes: #{inspect(results_a)}"

      # Node B classified the genuinely unsolvable pair -- EVERY invocation
      # must have really refused. Under the old naming, node A's concurrent
      # solvable bytes overwriting B's temp files surface here as
      # {:ok, true} -- a solve that never belonged to B's inputs.
      assert results_b == List.duplicate({:error, :hddl_solve_error}, @iterations),
             "node B (unsolvable pair) got cross-contaminated outcomes: #{inspect(results_b)}"

      # Cleanup discipline across BOTH VMs: every temp file every solve
      # wrote is really gone (each owner removed its own unique paths; the
      # old shared-path cleanup could not make this guarantee).
      leftover = Path.wildcard(Path.join(tmp_dir, "ash_a2a_hddl_*.hddl"))
      assert leftover == [], "leftover HddlSolver temp files: #{inspect(leftover)}"
    after
      File.rm_rf!(tmp_dir)
      stop_if_alive(pid_a)
      stop_if_alive(pid_b)
    end
  end
end

# --- SECTION 7: Original test/ash_a2a_plug_agent_card_test.exs ---
# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshA2A.PlugAgentCardTest do
  @moduledoc """
  Real, end-to-end test for assignment #3 (ash_a2a AshA2A.Protocol.Plug agent-card
  serving hardening): fronts a real, running `AshA2A.Agent`-generated
  `AshA2A.Protocol.Agent` GenServer (`AshA2A.Test.PlugFixture.GreeterAgent`) with a real
  `AshA2A.Protocol.Plug`, drives a real `Plug.Test` GET request against the well-known
  agent-card path, and asserts the real HTTP response body matches what
  `AshA2A.Info.agent_card/2` + `AshA2A.Protocol.JSON.encode_agent_card/2` produce
  directly from the same compiled capability index.

  Research finding this closes: the vendored `:a2a` 0.2.0 dependency ships
  no `test/` directory at all, and `ash_a2a` itself never wires any
  `AshA2A.Protocol.Plug`/HTTP transport (it only documents the contract a caller's
  separately-wired Plug pipeline is expected to satisfy) -- so before this
  test, nothing in either codebase proved `AshA2A.Protocol.Plug.serve_agent_card/2`
  actually serves a real `AshA2A`-compiled agent card over real HTTP.
  `:plug` was previously only an *optional* dependency of `:a2a`
  (`~/xaas/deps/a2a/mix.exs:43`) that this project's `mix.exs` never pulled
  in -- `Code.ensure_loaded?(AshA2A.Protocol.Plug)` was `false` and the module did not
  exist at all prior to this change. `mix.exs` now declares
  `{:plug, "~> 1.16", only: :test}` so this real HTTP surface can actually be
  exercised, instead of being reported as infeasible-and-skipped.

  No `Mock`/`mox`/`patch`/`monkeypatch` anywhere: the agent is a real
  `GenServer` process, `AshA2A.Protocol.Plug.call/2` is the real, unmodified `:a2a`
  Plug implementation, and the HTTP conn is a real `Plug.Test.conn/3`
  struct run through `Plug.run/2`-equivalent direct `call/2` invocation
  (the standard way to exercise a Plug without a real listening socket).
  """

  use ExUnit.Case, async: true

  alias AshA2A.Test.PlugFixture.{Greeter, GreeterAgent}

  setup do
    # Real per-test process name so parallel `async: true` test runs (and
    # other concurrently-running test files' own agents) never collide on
    # a single globally-registered GenServer name.
    agent_name = :"greeter_agent_#{System.unique_integer([:positive])}"
    {:ok, pid} = GreeterAgent.start_link(name: agent_name)

    on_exit(fn ->
      AshA2A.TestSupport.SafeStop.stop(pid)
    end)

    %{agent: agent_name, pid: pid}
  end

  test "a real AshA2A.Protocol.Plug GET to the agent-card path serves the real AshA2A-compiled card",
       %{
         agent: agent
       } do
    base_url = "http://localhost:4000/a2a"

    plug_opts =
      AshA2A.Protocol.Plug.init(
        agent: agent,
        base_url: base_url
      )

    conn =
      Plug.Test.conn(:get, "/.well-known/agent-card.json")
      |> AshA2A.Protocol.Plug.call(plug_opts)

    assert conn.status == 200
    assert [content_type] = Plug.Conn.get_resp_header(conn, "content-type")
    assert content_type =~ "application/json"

    served_card = Jason.decode!(conn.resp_body)

    # The real, independently-computed expectation: build the agent card
    # straight from `AshA2A.Info.agent_card/2` (the same compiled
    # capability index `AshA2A.Agent.__card_opts__/2` feeds into
    # `use AshA2A.Protocol.Agent, ...` when `GreeterAgent` was compiled) and encode it
    # with the real `:a2a` JSON encoder the same way `AshA2A.Protocol.Plug` does
    # internally (`~/xaas/deps/a2a/lib/a2a/plug.ex:172-181`).
    expected_card = AshA2A.Info.agent_card(Greeter, name: "greeter_agent")

    expected_json =
      AshA2A.Protocol.JSON.encode_agent_card(expected_card, url: base_url)
      |> Jason.encode!()
      |> Jason.decode!()

    assert served_card == expected_json

    # And concretely assert the real skill made it through the real HTTP
    # response body, not just structural equality with another computed
    # value.
    # Real current shape (fbc3213 "derive canonical skills from public Ash
    # actions"): `id` is the fully-qualified "<Resource>.<action>" identity
    # (avoids collisions across resources sharing a short skill name);
    # `name` carries the short, declared skill name instead.
    assert %{
             "skills" => [
               %{"id" => "AshA2A.Test.PlugFixture.Greeter.read", "name" => "greet"}
             ]
           } = served_card

    # v1.0 wire shape (spec §4.4/8.2, single source of truth
    # `AshA2A.Protocol.Version.protocol_version/0`): the top-level `url` and
    # `protocolVersion` fields are GONE from the card — the base URL and the
    # protocol version ride only inside `supportedInterfaces` entries, and a
    # card-carried `supported_interfaces` entry (from the capability index)
    # takes precedence over the serving `:url` override.
    refute Map.has_key?(served_card, "url")
    refute Map.has_key?(served_card, "protocolVersion")

    # v1.1 is the advertised protocol version (1.0 and 0.3 clients are still
    # accepted by the A2A-Version gate, but never advertised).
    advertised = AshA2A.Protocol.Version.protocol_version()
    assert advertised == "1.1"

    assert %{
             "supportedInterfaces" => [
               %{"url" => _index_url, "protocolVersion" => ^advertised} | _
             ]
           } = served_card
  end

  test "a real AshA2A.Protocol.Plug GET to the agent-card path with no base_url raises ArgumentError",
       %{
         agent: agent
       } do
    # `serve_agent_card/2`'s real, documented behavior
    # (`~/xaas/deps/a2a/lib/a2a/plug.ex:166-170`): with no `base_url`
    # configured anywhere, it raises rather than silently serving a
    # URL-less card.
    plug_opts = AshA2A.Protocol.Plug.init(agent: agent, base_url: nil)

    assert_raise ArgumentError, ~r/requires a base_url/, fn ->
      Plug.Test.conn(:get, "/.well-known/agent-card.json")
      |> AshA2A.Protocol.Plug.call(plug_opts)
    end
  end

  test "a real AshA2A.Protocol.Plug POST to the agent-card path is rejected with 405", %{
    agent: agent
  } do
    plug_opts = AshA2A.Protocol.Plug.init(agent: agent, base_url: "http://localhost:4000/a2a")

    conn =
      Plug.Test.conn(:post, "/.well-known/agent-card.json", "")
      |> AshA2A.Protocol.Plug.call(plug_opts)

    assert conn.status == 405
    assert Plug.Conn.get_resp_header(conn, "allow") == ["GET"]
  end
end

# --- SECTION 8: Original test/ash_a2a_plug_auth_test.exs ---
# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshA2APlugAuthTest do
  @moduledoc """
  Real end-to-end auth test: a real `AshA2A.Protocol.Plug.Auth` + real `AshA2A.Protocol.Plug`
  pipeline, driven with `Plug.Test`, fronting a real `AshA2A.Agent`-generated
  agent. Sends a real HTTP POST with a real `Authorization: Bearer <token>`
  header through the real plug pipeline and asserts the verified identity
  actually threads into the real Ash action's `context.actor`/`context.tenant`
  -- proving the contract `AshA2A.Dispatcher`'s moduledoc documents actually
  holds through a real `AshA2A.Protocol.Plug` transport, not just via a direct
  `dispatch/5` call that bypasses `AshA2A.Protocol.Plug` entirely.

  Chicago-style throughout: real `Plug.Test.conn/3`, real
  `AshA2A.Protocol.Plug.Auth.call/2`, real `AshA2A.Protocol.Plug.call/2`, real supervised
  `AshA2A.Protocol.Agent` GenServer, real JSON encode/decode via `AshA2A.Protocol.JSON` and `Jason`.
  No Mock/mox/patch/monkeypatch anywhere in this file.
  """

  use ExUnit.Case, async: true

  import Plug.Test
  import Plug.Conn

  alias AshA2A.Test.Fixture.AuthProbeAgent

  @schemes %{"bearer_auth" => %AshA2A.Protocol.SecurityScheme.HTTPAuth{scheme: "bearer"}}

  # Real verify callback: accepts exactly the token "valid-token-42" and maps
  # it to a real identity map carrying an id and a tenant claim -- exactly
  # the shape a resource author's own `:verify` function would return after
  # looking a token up in a real token store. Any other token is rejected.
  defp verify_callback("bearer_auth", "valid-token-42", _conn) do
    {:ok, %{id: "user-42", tenant: "acme"}}
  end

  defp verify_callback(_scheme, _credential, _conn), do: {:error, "invalid token"}

  setup do
    {:ok, _pid} = start_supervised({AuthProbeAgent, name: AuthProbeAgent})
    :ok
  end

  defp run_pipeline(conn) do
    auth_opts =
      AshA2A.Protocol.Plug.Auth.init(
        schemes: @schemes,
        verify: &verify_callback/3
      )

    plug_opts =
      AshA2A.Protocol.Plug.init(
        agent: AuthProbeAgent,
        base_url: "http://localhost:4000/a2a"
      )

    conn
    |> AshA2A.Protocol.Plug.Auth.call(auth_opts)
    |> then(fn conn ->
      if conn.halted, do: conn, else: AshA2A.Protocol.Plug.call(conn, plug_opts)
    end)
  end

  defp whoami_request_body do
    # `AuthProbe` now has 2 public actions (`:read` via `defaults([:read])`
    # plus the generic `:whoami`), so it exposes 2 real skills since fbc3213
    # "derive canonical skills from public Ash actions" -- explicit
    # `metadata["skill"]` is required to disambiguate (real regression,
    # confirmed via {:ambiguous_skill, ...} on a real failing run).
    message = %{
      AshA2A.Protocol.Message.new_user([AshA2A.Protocol.Part.Data.new(%{})])
      | metadata: %{"skill" => "whoami"}
    }

    {:ok, message_json} = AshA2A.Protocol.JSON.encode(message)

    Jason.encode!(%{
      "jsonrpc" => "2.0",
      "id" => "req-1",
      "method" => "message/send",
      "params" => %{"message" => message_json}
    })
  end

  test "a verified Bearer identity threads through AshA2A.Protocol.Plug.Auth + AshA2A.Protocol.Plug into the real Ash action's actor/tenant" do
    conn =
      :post
      |> conn("/", whoami_request_body())
      |> put_req_header("content-type", "application/json")
      |> put_req_header("authorization", "Bearer valid-token-42")
      |> run_pipeline()

    refute conn.halted
    assert conn.status == 200

    body = Jason.decode!(conn.resp_body)
    assert %{"result" => %{"task" => task_json}} = body

    # v1.0 wire contract: no "kind" discriminator anywhere on the wire.
    refute Map.has_key?(task_json, "kind")

    assert %{"status" => %{"state" => "TASK_STATE_COMPLETED"}, "artifacts" => [artifact]} =
             task_json

    # Parts are flat v1.0 wire maps: {"data": ...} with no "kind" key.
    assert %{"parts" => [%{"data" => data} = part]} = artifact
    refute Map.has_key?(part, "kind")

    # Real state reached by the real Ash action, via the real Plug.Auth ->
    # AshA2A.Protocol.Plug -> AshA2A.Agent.__dispatch__ -> AshA2A.Dispatcher ->
    # AshA2A.ContextResolver chain -- not asserted via any mock/interaction.
    assert %{"actor" => %{"id" => "user-42", "tenant" => "acme"}, "tenant" => "acme"} = data
  end

  test "a missing Bearer credential is real-401-rejected by AshA2A.Protocol.Plug.Auth before AshA2A.Protocol.Plug ever runs" do
    conn =
      :post
      |> conn("/", whoami_request_body())
      |> put_req_header("content-type", "application/json")
      |> run_pipeline()

    assert conn.halted
    assert conn.status == 401
    assert Jason.decode!(conn.resp_body) == %{"error" => "Unauthorized"}
  end

  test "an invalid Bearer token is real-rejected by the real verify callback" do
    conn =
      :post
      |> conn("/", whoami_request_body())
      |> put_req_header("content-type", "application/json")
      |> put_req_header("authorization", "Bearer wrong-token")
      |> run_pipeline()

    assert conn.halted
    assert conn.status == 401
  end
end

# --- SECTION 9: Original test/ash_a2a_plug_authorize_refusal_receipt_test.exs ---
defmodule AshA2APlugAuthorizeRefusalReceiptTest.Converse do
  @moduledoc """
  Real fixture resource, private to this lane (L153), for the
  plug-authorize refusal-receipt court.
  """

  use Ash.Resource,
    domain: AshA2APlugAuthorizeRefusalReceiptTest.Domain,
    data_layer: Ash.DataLayer.Ets,
    extensions: [AshA2A]

  attributes do
    uuid_primary_key(:id)
    attribute(:label, :string, public?: true)
  end

  actions do
    defaults([:read])

    action :converse, :map do
      argument(:say, :string, allow_nil?: false)

      run(fn input, _context ->
        {:ok, %{say: input.arguments.say}}
      end)
    end
  end

  a2a do
    skill(:converse, :converse, consequence: :observe)
  end
end

defmodule AshA2APlugAuthorizeRefusalReceiptTest.Domain do
  @moduledoc false

  use Ash.Domain, extensions: [AshA2A], validate_config_inclusion?: false

  resources do
    resource(AshA2APlugAuthorizeRefusalReceiptTest.Converse)
  end
end

defmodule AshA2APlugAuthorizeRefusalReceiptTest.Agent do
  @moduledoc """
  Real `AshA2A.Agent` GenServer serving the fixture resource (inline
  execution, no auth requirement -- the authorize_task callback is the
  refusal surface under court).
  """

  use AshA2A.Agent,
    resource_or_domain: AshA2APlugAuthorizeRefusalReceiptTest.Converse,
    name: "plug_authorize_refusal_agent",
    execution: [mode: :inline]
end

defmodule AshA2APlugAuthorizeRefusalReceiptTest do
  @moduledoc """
  L153 courts: every `AshA2A.Protocol.Plug` authorize rejection
  (`authorize_task/authorize_task_list`) commits a refusal receipt over the
  refused task/action identity (`AshA2A.Semantic.Refusal.commit/2`), without
  any change to the wire response (still the same -32001 `TASK_NOT_FOUND`
  shape). Mirrors the owner-scope court's real-transport pattern: real agent
  GenServer, real JSON-RPC over `Plug.Test` conns, zero mocks.
  """

  use ExUnit.Case, async: true

  alias AshA2A.A2ATransport.Plug, as: TransportPlug
  alias AshA2A.Semantic.Refusal

  @event [:ash_a2a, :protocol, :plug, :authorize_refused]

  setup do
    uniq = System.unique_integer([:positive])
    agent = :"plug_authorize_refusal_#{uniq}"

    start_supervised!({AshA2APlugAuthorizeRefusalReceiptTest.Agent, name: agent})

    # Authorizer denies every task-scoped operation (the court's refusal
    # surface); message/send is not task-scoped, so task creation works.
    plug =
      TransportPlug.init(
        agent: agent,
        base_url: "http://x/a2a",
        authorize_task: fn _operation, _task, _context -> :deny end
      )

    :ok =
      :telemetry.attach(
        {:l153_authorize_refused, uniq},
        @event,
        &__MODULE__.handle_event/4,
        %{test: self()}
      )

    :ok =
      :telemetry.attach(
        {:l175_transport_list_refused, uniq},
        [:ash_a2a, :transport, :plug, :list_refused],
        &__MODULE__.handle_event/4,
        %{test: self()}
      )

    on_exit(fn ->
      :telemetry.detach({:l153_authorize_refused, uniq})
      :telemetry.detach({:l175_transport_list_refused, uniq})
    end)

    %{agent: agent, plug: plug}
  end

  def handle_event(@event, _measurements, meta, %{test: test}), do: send(test, {:refused, meta})

  def handle_event([:ash_a2a, :transport, :plug, :list_refused], _m, meta, %{test: test}),
    do: send(test, {:transport_list_refused, meta})

  def handle_event(_other, _m, _meta, _), do: :ok

  # -- wire helpers ------------------------------------------------------------

  defp rpc(%{agent_card_path: _} = protocol_plug_opts, method, params) do
    AshA2A.Protocol.Plug.call(conn_for(method, params), protocol_plug_opts)
    |> Map.fetch!(:resp_body)
    |> Jason.decode!()
  end

  defp rpc(plug, method, params) do
    TransportPlug.call(conn_for(method, params), plug)
    |> Map.fetch!(:resp_body)
    |> Jason.decode!()
  end

  defp conn_for(method, params) do
    body =
      Jason.encode!(%{
        "jsonrpc" => "2.0",
        "id" => System.unique_integer([:positive]),
        "method" => method,
        "params" => params
      })

    Plug.Test.conn(:post, "/", body)
    |> Plug.Conn.put_req_header("content-type", "application/json")
  end

  defp skill_message do
    alias AshA2A.Protocol.{JSON, Message, Part}
    parts = [Part.Data.new(%{"say" => "hello"})]
    msg = struct(Message.new_user(parts), metadata: %{"skill" => "converse"})
    {:ok, encoded} = JSON.encode(msg)
    %{"message" => encoded}
  end

  defp create_task_id(plug) do
    assert %{"result" => res} = rpc(plug, "message/send", skill_message())
    get_in(res, ["task", "id"]) || res["id"]
  end

  test "denied tasks/get returns the unchanged -32001 wire shape AND commits a receipt over the refused subject",
       %{plug: plug} do
    %{"result" => res} = rpc(plug, "message/send", skill_message())
    task_id = get_in(res, ["task", "id"]) || res["id"]

    assert %{"error" => %{"code" => -32_001}} = rpc(plug, "tasks/get", %{"id" => task_id})

    assert_receive {:refused, %{operation: :get, task_id: ^task_id, refusal: refusal}}, 1_000
    assert %Refusal{class: :refused_authority, code: :denied, receipt: receipt} = refusal
    assert is_binary(receipt) and byte_size(receipt) == 32

    assert receipt ==
             Refusal.receipt(
               :refused_authority,
               :denied,
               :protocol_plug_authorize,
               {:task, task_id}
             )
  end

  test "receipt is deterministic per subject and subject-bound (diverges across tasks)", %{
    plug: plug
  } do
    %{"result" => res} = rpc(plug, "message/send", skill_message())
    a_id = get_in(res, ["task", "id"]) || res["id"]
    %{"result" => res} = rpc(plug, "message/send", skill_message())
    b_id = get_in(res, ["task", "id"]) || res["id"]

    assert %{"error" => %{"code" => -32_001}} = rpc(plug, "tasks/get", %{"id" => a_id})
    assert %{"error" => %{"code" => -32_001}} = rpc(plug, "tasks/get", %{"id" => a_id})
    assert %{"error" => %{"code" => -32_001}} = rpc(plug, "tasks/get", %{"id" => b_id})

    assert_receive {:refused, %{task_id: ^a_id, refusal: a1}}, 1_000
    assert_receive {:refused, %{task_id: ^a_id, refusal: a2}}, 1_000
    assert_receive {:refused, %{task_id: ^b_id, refusal: b}}, 1_000

    assert a1.receipt == a2.receipt
    assert a1.receipt != b.receipt
  end

  test "denied tasks/list filtering commits one receipt per refused task", %{agent: agent} do
    # `tasks/list` is owner-scoped in the wrapper transport, so this court
    # drives the vendored `AshA2A.Protocol.Plug` directly (its `handle_list`
    # is where `authorize_task_list` runs).
    plug =
      AshA2A.Protocol.Plug.init(
        agent: agent,
        base_url: "http://x/a2a",
        authorize_task: fn _op, _task, _ctx -> :deny end
      )

    a_id = create_task_id(plug)
    b_id = create_task_id(plug)

    result = rpc(plug, "tasks/list", %{})
    assert %{"result" => %{"tasks" => [], "totalSize" => 0}} = result

    assert_receive {:refused, %{operation: :list, task_id: t1}}, 1_000
    assert_receive {:refused, %{operation: :list, task_id: t2}}, 1_000
    assert Enum.sort([t1, t2]) == Enum.sort([a_id, b_id])
  end

  test "explicit authorizer error also commits a receipt (wire response untouched)", %{
    agent: agent
  } do
    plug =
      AshA2A.Protocol.Plug.init(
        agent: agent,
        base_url: "http://x/a2a",
        authorize_task: fn _op, _task, _ctx ->
          {:error, AshA2A.Protocol.JSONRPC.Error.internal_error("policy engine down")}
        end
      )

    %{"result" => res} = rpc(plug, "message/send", skill_message())
    task_id = get_in(res, ["task", "id"]) || res["id"]

    assert %{"error" => %{"code" => -32_603}} = rpc(plug, "tasks/get", %{"id" => task_id})

    assert_receive {:refused, %{task_id: ^task_id, refusal: refusal}}, 1_000
    assert is_binary(refusal.receipt) and byte_size(refusal.receipt) == 32
  end

  # -- L175: transport-level `tasks/list` rejections commit receipts ----------

  describe "L175 transport tasks/list refusal receipts" do
    test "invalid pageToken over the real transport plug commits a receipt over {:list, principal} (wire unchanged)",
         %{
           plug: plug
         } do
      assert %{"error" => %{"code" => -32_602}} =
               rpc(plug, "tasks/list", %{"pageToken" => "garbage"})

      assert_receive {:transport_list_refused, meta}, 1_000
      assert %{subject: {:list, :anonymous}, wire_code: -32_602} = meta

      assert %Refusal{
               class: :refused_structure,
               code: :invalid_page_token,
               stage: :a2a_transport_list
             } = meta.refusal

      assert is_binary(meta.refusal.receipt) and byte_size(meta.refusal.receipt) == 32

      assert meta.refusal.receipt ==
               Refusal.receipt(
                 :refused_structure,
                 :invalid_page_token,
                 :a2a_transport_list,
                 {:list, :anonymous}
               )
    end

    test "receipt is deterministic per subject and subject-bound (diverges across principals and tasks)",
         %{
           plug: plug
         } do
      assert %{"error" => %{"code" => -32_602}} =
               rpc(plug, "tasks/list", %{"pageToken" => "garbage"})

      assert %{"error" => %{"code" => -32_602}} =
               rpc(plug, "tasks/list", %{"pageToken" => "garbage"})

      assert_receive {:transport_list_refused, m1}, 1_000
      assert_receive {:transport_list_refused, m2}, 1_000
      assert m1.refusal.receipt == m2.refusal.receipt

      # Divergence: a different refused subject (another principal's list,
      # or a task-scoped subject) produces a different receipt.
      assert m1.refusal.receipt !=
               Refusal.receipt(
                 :refused_structure,
                 :invalid_page_token,
                 :a2a_transport_list,
                 {:list, :alice}
               )

      assert m1.refusal.receipt !=
               Refusal.receipt(
                 :refused_authority,
                 :denied,
                 :protocol_plug_authorize,
                 {:task, "t-1"}
               )
    end
  end
end

# --- SECTION 10: Original test/ash_a2a_plug_tenant_actor_test.exs ---
# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshA2APlugTenantActorTest do
  @moduledoc """
  Assignment #10: real tenant+actor threading through a REAL auth pipeline
  and a REAL multitenant Ash resource -- combining item #2's real
  `AshA2A.Protocol.Plug.Auth` + `AshA2A.Protocol.Plug` HTTP pipeline (`test/ash_a2a_plug_auth_test.exs`)
  with a genuine `multitenancy do strategy :attribute end` resource guarded
  by a genuine `Ash.Policy.Authorizer` policy
  (`AshA2A.Test.Fixture.TenantActorNote`, `test/support/
  tenant_actor_auth_fixture.ex`), proving the full stack -- not just the
  direct-`AshA2A.Dispatcher.dispatch/5`-bypassing-`AshA2A.Protocol.Plug` pattern every
  existing tenant test (`test/ash_a2a_dispatcher_tenant_test.exs`) uses.

  Real `Plug.Test.conn/3`, real `AshA2A.Protocol.Plug.Auth.call/2`, real `AshA2A.Protocol.Plug.call/2`,
  a real supervised `AshA2A.Protocol.Agent` GenServer, real `Ash.DataLayer.Ets`
  per-tenant partitioning, real `Ash.Policy.Authorizer` evaluation, real
  `AshA2A.Protocol.JSON`/`Jason` encode-decode. No Mock/mox/patch/monkeypatch anywhere
  in this file.
  """

  use ExUnit.Case, async: true

  import Plug.Test
  import Plug.Conn

  alias AshA2A.Test.Fixture.TenantActorNoteAgent

  @schemes %{"bearer_auth" => %AshA2A.Protocol.SecurityScheme.HTTPAuth{scheme: "bearer"}}

  # Real verify callback mapping two distinct real Bearer tokens to two
  # distinct real identities -- one per tenant -- plus a third token whose
  # identity carries a tenant claim but no `:id`, used to exercise the real
  # fail-closed missing-tenant path (`:id` present but a genuinely different
  # coverage need: see the last test below) through the real pipeline
  # instead of a direct `dispatch/5` call.
  defp verify_callback("bearer_auth", "acme-token", _conn) do
    {:ok, %{id: "user-acme-1", tenant: "acme"}}
  end

  defp verify_callback("bearer_auth", "beta-token", _conn) do
    {:ok, %{id: "user-beta-1", tenant: "beta"}}
  end

  defp verify_callback("bearer_auth", "no-tenant-token", _conn) do
    {:ok, %{id: "user-no-tenant"}}
  end

  defp verify_callback(_scheme, _credential, _conn), do: {:error, "invalid token"}

  setup do
    {:ok, _pid} = start_supervised({TenantActorNoteAgent, name: TenantActorNoteAgent})

    # RFC-SA2A-001 S29: `:create_note` is a real `:change` skill, so the
    # verified identity needs a real `AshA2A.Authority.Broker` grant, not just
    # a valid Bearer token -- see `AshA2A.Authority.Grant`. The grant subject
    # is the SAME term `AshA2A.Protocol.Plug.Auth`'s verify callback returns and
    # `AshA2A.Protocol.Plug` threads through as `auth_identity` (the whole identity map),
    # since `AshA2A.Identity.principal/1` normalizes it identically on both
    # the grant side and the dispatch side.
    #
    # `"no-tenant-token"`'s identity is deliberately granted too: the
    # fail-closed behavior that test asserts must come from real Ash
    # multitenancy enforcement, which is what it is actually about -- not
    # from a missing capability grant masking it.
    AshA2A.Test.AuthorityGrantCase.grant!([
      {%{id: "user-acme-1", tenant: "acme"}, AshA2A.Test.Fixture.TenantActorNote,
       ["create_note"]},
      {%{id: "user-beta-1", tenant: "beta"}, AshA2A.Test.Fixture.TenantActorNote,
       ["create_note"]},
      {%{id: "user-no-tenant"}, AshA2A.Test.Fixture.TenantActorNote, ["create_note"]}
    ])

    :ok
  end

  defp run_pipeline(conn) do
    auth_opts =
      AshA2A.Protocol.Plug.Auth.init(
        schemes: @schemes,
        verify: &verify_callback/3
      )

    plug_opts =
      AshA2A.Protocol.Plug.init(
        agent: TenantActorNoteAgent,
        base_url: "http://localhost:4000/a2a"
      )

    conn
    |> AshA2A.Protocol.Plug.Auth.call(auth_opts)
    |> then(fn conn ->
      if conn.halted, do: conn, else: AshA2A.Protocol.Plug.call(conn, plug_opts)
    end)
  end

  # `AshA2A.Test.Fixture.TenantActorNote` compiles two real skills
  # (`create_note`, `list_notes`) -- per `AshA2A.Agent`'s own documented
  # default-skill rule, only a resource/domain with EXACTLY ONE compiled
  # skill lets a caller omit `:skill` metadata; with two, the target skill
  # must be named explicitly or dispatch real-fails-closed with
  # `{:ambiguous_skill, _}`. Real skill selection here, not a workaround.
  defp jsonrpc_request_body(data, skill) do
    message = %{
      AshA2A.Protocol.Message.new_user([AshA2A.Protocol.Part.Data.new(data)])
      | metadata: %{"skill" => skill}
    }

    {:ok, message_json} = AshA2A.Protocol.JSON.encode(message)

    Jason.encode!(%{
      "jsonrpc" => "2.0",
      "id" => "req-1",
      "method" => "message/send",
      "params" => %{"message" => message_json}
    })
  end

  defp post_with_token(body, skill, token) do
    conn = conn(:post, "/", jsonrpc_request_body(body, skill))
    conn = put_req_header(conn, "content-type", "application/json")

    conn =
      if token, do: put_req_header(conn, "authorization", "Bearer #{token}"), else: conn

    run_pipeline(conn)
  end

  defp task_data(conn) do
    body = Jason.decode!(conn.resp_body)
    assert %{"result" => %{"task" => task_json}} = body
    # Real wire state strings are `TASK_STATE_*`-prefixed (v0.3/v1.0 A2A wire
    # format, unchanged spelling in v1.0), not the bare atom name -- confirmed
    # via this task's own real encoded response.
    assert %{"status" => %{"state" => "TASK_STATE_COMPLETED"}, "artifacts" => [artifact]} =
             task_json

    # v1.0 wire contract: no "kind" discriminator anywhere on the wire; parts
    # are flat {"data": ...} maps.
    refute Map.has_key?(task_json, "kind")
    assert %{"parts" => [%{"data" => data} = part]} = artifact
    refute Map.has_key?(part, "kind")
    data
  end

  # A dispatch failure inside a real Ash action (e.g. a real multitenancy
  # validation error) is NOT a JSON-RPC-level `"error"` response -- it is a
  # real, successfully-dispatched `AshA2A.Protocol.Task` whose own `status.state` is
  # `TASK_STATE_FAILED` with a real error message, per
  # `AshA2A.Dispatcher.dispatch/5`'s always-`{:ok, task}` contract (only a
  # transport/protocol-level failure in `AshA2A.Protocol.Plug` itself produces a
  # top-level JSON-RPC `"error"`). Confirmed via this task's own real
  # response shape.
  defp task_failure_message(conn) do
    body = Jason.decode!(conn.resp_body)
    assert %{"result" => %{"task" => task_json}} = body
    assert %{"status" => %{"state" => "TASK_STATE_FAILED", "message" => message}} = task_json
    assert %{"parts" => [%{"text" => text}]} = message
    text
  end

  test "a real Bearer identity's tenant AND actor id both thread through the real plug pipeline into the real multitenant resource's created record" do
    conn = post_with_token(%{"body" => "acme note 1"}, "create_note", "acme-token")

    refute conn.halted
    assert conn.status == 200

    data = task_data(conn)
    assert data["tenant"] == "acme"
    assert data["created_by"] == "user-acme-1"
    assert data["body"] == "acme note 1"
  end

  test "two different real verified identities create real records isolated by real multitenancy, invisible across tenants" do
    conn_acme = post_with_token(%{"body" => "acme secret"}, "create_note", "acme-token")
    assert conn_acme.status == 200
    acme_created = task_data(conn_acme)
    assert acme_created["tenant"] == "acme"

    conn_beta = post_with_token(%{"body" => "beta secret"}, "create_note", "beta-token")
    assert conn_beta.status == 200
    beta_created = task_data(conn_beta)
    assert beta_created["tenant"] == "beta"

    # Real cross-tenant isolation, driven entirely through the real HTTP
    # pipeline: listing as tenant "acme" must never surface the "beta"
    # record real-created above (real `Ash.DataLayer.Ets` per-tenant
    # partitioning, not an application-level filter this test could fake).
    conn_list_acme = post_with_token(%{}, "list_notes", "acme-token")
    assert conn_list_acme.status == 200
    acme_list = task_data(conn_list_acme)
    assert %{"results" => results} = acme_list
    acme_note_bodies = Enum.map(results, & &1["body"])
    assert "acme secret" in acme_note_bodies
    refute "beta secret" in acme_note_bodies

    conn_list_beta = post_with_token(%{}, "list_notes", "beta-token")
    assert conn_list_beta.status == 200
    beta_list = task_data(conn_list_beta)
    beta_note_bodies = Enum.map(beta_list["results"], & &1["body"])
    assert "beta secret" in beta_note_bodies
    refute "acme secret" in beta_note_bodies
  end

  test "a real verified identity with no tenant claim is real-fail-closed by real Ash multitenancy enforcement through the real pipeline (not bypassing AshA2A.Protocol.Plug)" do
    conn = post_with_token(%{"body" => "orphan note"}, "create_note", "no-tenant-token")

    refute conn.halted
    assert conn.status == 200

    # `AshA2A.ContextResolver.from_a2a_message/4` resolves `tenant: nil`
    # because `%{id: "user-no-tenant"}` carries no `:tenant`/`"tenant"` key
    # (per its documented field provenance) -- so this is the same real
    # `Ash.Actions.Helpers.validate_changeset_multitenancy/1` failure
    # `test/ash_a2a_dispatcher_tenant_test.exs` already proves for a direct
    # `dispatch/5` call, now proven reachable through the real
    # `AshA2A.Protocol.Plug.Auth` -> `AshA2A.Protocol.Plug` -> `AshA2A.Agent.__dispatch__/3` chain
    # instead of a test calling `AshA2A.Dispatcher.dispatch/5` directly. The
    # real failure surfaces as a real TASK_STATE_FAILED task, not a
    # JSON-RPC-level error (see `task_failure_message/1`'s moduledoc).
    text = task_failure_message(conn)
    assert text =~ "tenant"
  end

  test "an unauthenticated request is real-401-rejected by AshA2A.Protocol.Plug.Auth before the real multitenant resource's actor_present() policy ever runs" do
    conn = post_with_token(%{"body" => "no auth"}, "create_note", nil)

    assert conn.halted
    assert conn.status == 401
    assert Jason.decode!(conn.resp_body) == %{"error" => "Unauthorized"}
  end
end

# --- SECTION 11: Original test/ash_a2a_pplan_durability_test.exs ---
defmodule AshA2A.Providers.PPlanDurabilityTest do
  @moduledoc """
  Lane Y6 end-to-end court for `AshA2A.Providers.PPlan` over the REAL ash_pplan
  durable stack (`AshPPlan.Reactor.Durable.{Engine,Run,Status}` over a real
  disk-backed `AshPPlan.Reactor.Durable.Store.Dets` on a tmp dir). Zero mocks:
  the plan steps are real Reactor steps counting into a real named Agent, the
  park/resume hops are real `Durable.Steps.Await` signal waiters, and the
  restart leg kills the store process and reopens the same DETS file.

  Acceptance (operator directive): agent durable state works with ash_pplan —
  a run parked on an Await step survives the store process dying, and the
  provider reports it correctly before and after.

  If `:ash_pplan` cannot load in the test env, every test skips with a typed
  BLOCKED reason (`{:blocked, :ash_pplan_not_loadable}`) printed to stderr —
  a named finding, never a silent pass.
  """

  use ExUnit.Case, async: false

  @dets AshPPlan.Reactor.Durable.Store.Dets
  @engine AshPPlan.Reactor.Durable.Engine

  # -- real collaborators ------------------------------------------------------

  defmodule Effects do
    @moduledoc "Real counting agent: each consequential effect records exactly here."
    use Agent

    def start_link(name), do: Agent.start_link(fn -> %{} end, name: name)

    def run(server, effect) do
      Agent.get_and_update(server, fn s ->
        n = Map.get(s, effect, 0) + 1
        {{:ok, n}, Map.put(s, effect, n)}
      end)
    end

    def count(server, effect), do: Agent.get(server, &Map.get(&1, effect, 0))
  end

  defmodule Effect do
    @moduledoc "Counting Reactor step; `options[:effect]` names the counter."
    use Reactor.Step

    @impl true
    def run(_arguments, _context, options) do
      case Effects.run(Keyword.fetch!(options, :effects), Keyword.fetch!(options, :effect)) do
        {:ok, n} -> {:ok, {Keyword.fetch!(options, :effect), n}}
        {:error, _} = err -> err
      end
    end
  end

  defmodule Adapter do
    @moduledoc """
    Test adapter: counting effects plus ash_pplan's own Await/Poll durable steps.
    Realization options carry the per-test `:effects` agent name (data, survives
    a store round trip).
    """

    @behaviour AshPPlan.Reactor.Adapter

    alias AshPPlan.Reactor.Durable.Steps

    @impl true
    def id, do: :a2a_durability_fx

    @impl true
    def available?, do: true

    @impl true
    def ops, do: [:process_prepare, :process_finish, :event_await, :state_hold]

    @impl true
    def step(op, options) do
      table = %{
        process_prepare: {Effect, [effect: :prepare]},
        process_finish: {Effect, [effect: :finish]},
        event_await: {Steps.Await, [signal: "go", timeout: nil]},
        state_hold:
          {Steps.Poll,
           [
             until: {AshPPlan.Reactor.Adapters.Durable, :argument_until, [:ready]},
             every: 3_600_000
           ]}
      }

      AshPPlan.Reactor.Adapter.resolve(__MODULE__, table, op, options)
    end
  end

  # -- fixtures ----------------------------------------------------------------

  defp install_adapter! do
    previous = Application.get_env(:ash_pplan, :extra_adapters, %{})

    Application.put_env(
      :ash_pplan,
      :extra_adapters,
      Map.put(Map.new(previous), :a2a_durability_fx, Adapter)
    )

    ExUnit.Callbacks.on_exit(fn ->
      Application.put_env(:ash_pplan, :extra_adapters, previous)
    end)

    :ok
  end

  defp model(name, tasks) do
    {:ok, m} = AshPPlan.Workflow.Model.new(name: name, goal: name, tasks: tasks)
    m
  end

  defp simple_model,
    do:
      model("a2a_durability_simple", [
        [id: :prepare, capability: "Process.Prepare", depends_on: []],
        [id: :finish, capability: "Process.Finish", depends_on: [:prepare]]
      ])

  defp await_model,
    do:
      model("a2a_durability_await", [
        [id: :prepare, capability: "Process.Prepare", depends_on: []],
        [id: :await, capability: "Event.Await", depends_on: [:prepare]],
        [id: :finish, capability: "Process.Finish", depends_on: [:await]]
      ])

  defp poll_model,
    do:
      model("a2a_durability_poll", [
        [id: :prepare, capability: "Process.Prepare", depends_on: []],
        [id: :hold, capability: "State.Hold", depends_on: [:prepare]]
      ])

  defp bindings(effects) do
    ops = [
      {:prepare, "Process.Prepare"},
      {:finish, "Process.Finish"},
      {:await, "Event.Await"},
      {:hold, "State.Hold"}
    ]

    Map.new(ops, fn {task, cap} ->
      {task,
       %AshPPlan.Realization{
         capability: cap,
         provider: :a2a_durability_fx,
         binding: %{adapter: :a2a_durability_fx, op: AshPPlan.Realization.op_for(cap)},
         options: [effects: effects]
       }}
    end)
  end

  defp open_store do
    path =
      Path.join(
        System.tmp_dir!(),
        "a2a-pplan-laneY6-#{System.unique_integer([:positive])}"
      )

    on_exit(fn ->
      File.rm(path)
      File.rm(path <> ".tmp")
    end)

    {:ok, store} = @dets.start_link(path: path)
    # the restart court kills the store; a live link would take the test down with it
    Process.unlink(store)
    %{store: store, path: path}
  end

  setup do
    unless AshA2A.Providers.PPlan.available?() do
      reason = {:blocked, :ash_pplan_not_loadable}

      IO.puts(:stderr, "[lane-y6] BLOCKED: :ash_pplan did not load in the test env")

      {:skip, reason}
    end

    install_adapter!()
    {:ok, fx} = Effects.start_link(:"pplan_durability_fx_#{System.unique_integer([:positive])}")
    %{store: store, path: path} = open_store()

    %{store: store, path: path, fx: fx, sm: @dets, opts: [store: store, store_module: @dets]}
  end

  # -- (a) idempotent dispatch (moduledoc falsifier #1) ------------------------

  test "dispatch/4 re-dispatch of the same task id adopts the run: no tape growth, no re-execution",
       %{store: store, fx: fx, opts: opts} do
    task_id = "a2a-task-idem-1"
    model = simple_model()

    assert {:ok, :completed, result1} =
             AshA2A.Providers.PPlan.dispatch(task_id, model, bindings(fx), opts)

    tape0 = @engine.steps(store, task_id, store_module: @dets)

    assert %{prepare: 1, finish: 1} ==
             %{prepare: Effects.count(fx, :prepare), finish: Effects.count(fx, :finish)}

    # Re-dispatch: same task id, same plan.
    assert {:ok, :completed, ^result1} =
             AshA2A.Providers.PPlan.dispatch(task_id, model, bindings(fx), opts)

    tape1 = @engine.steps(store, task_id, store_module: @dets)
    assert length(tape1) == length(tape0)
    assert Enum.map(tape1, & &1.step_key) == Enum.map(tape0, & &1.step_key)

    assert %{prepare: 1, finish: 1} ==
             %{prepare: Effects.count(fx, :prepare), finish: Effects.count(fx, :finish)}
  end

  # -- (b) park on Await -> :input_required; resume completes ------------------

  test "await park reports :input_required, resume delivers a consume-once signal and completes",
       %{store: store, fx: fx, opts: opts} do
    task_id = "a2a-task-await-1"

    assert {:ok, :input_required, ["go"]} =
             AshA2A.Providers.PPlan.dispatch(task_id, await_model(), bindings(fx), opts)

    assert {:ok, :input_required,
            %{run_status: :waiting, waiters: ["go"], version: v_parked, error: nil}} =
             AshA2A.Providers.PPlan.status(task_id, opts)

    assert {:ok, :completed, _result} =
             AshA2A.Providers.PPlan.resume(task_id, %{answer: 42}, opts)

    # exactly one signal was delivered and it was consumed exactly once
    assert [%{name: "go", consumed_at: consumed}] = @dets.signals(store, task_id)
    refute is_nil(consumed)

    # the delivered payload reached the plan as the Await step's output (finish ran once,
    # prepare never re-ran)
    assert %{prepare: 1, finish: 1} ==
             %{prepare: Effects.count(fx, :prepare), finish: Effects.count(fx, :finish)}

    assert {:ok, :completed, %{run_status: :completed, version: v_done, waiters: []}} =
             AshA2A.Providers.PPlan.status(task_id, opts)

    assert v_done > v_parked
  end

  test "second resume on the terminal run returns the sealed state and moves nothing",
       %{fx: fx, opts: opts} do
    task_id = "a2a-task-await-2"

    assert {:ok, :input_required, _} =
             AshA2A.Providers.PPlan.dispatch(task_id, await_model(), bindings(fx), opts)

    assert {:ok, :completed, result} = AshA2A.Providers.PPlan.resume(task_id, 1, opts)

    assert {:ok, :completed, %{version: v}} = AshA2A.Providers.PPlan.status(task_id, opts)

    # a second resume consumes nothing and the terminal state does not move
    assert {:ok, :completed, ^result} = AshA2A.Providers.PPlan.resume(task_id, 2, opts)

    assert {:ok, :completed, %{version: ^v}} = AshA2A.Providers.PPlan.status(task_id, opts)

    assert %{prepare: 1, finish: 1} ==
             %{prepare: Effects.count(fx, :prepare), finish: Effects.count(fx, :finish)}
  end

  test "resume on a run with no pending signal waiter is a typed refusal that moves nothing",
       %{fx: fx, opts: opts} do
    task_id = "a2a-task-poll-1"

    # a Poll-parked run is :working/:polling with no signal waiter
    assert {:ok, :working, nil} =
             AshA2A.Providers.PPlan.dispatch(task_id, poll_model(), bindings(fx), opts)

    assert {:ok, :working, %{run_status: :polling, version: v}} =
             AshA2A.Providers.PPlan.status(task_id, opts)

    assert {:error, :no_signal_waiter} = AshA2A.Providers.PPlan.resume(task_id, %{}, opts)

    assert {:ok, :working, %{run_status: :polling, version: ^v}} =
             AshA2A.Providers.PPlan.status(task_id, opts)
  end

  # -- (c) durability across restart (operator acceptance) ---------------------

  test "a parked run survives the store process being killed and the DETS file being reopened",
       %{store: store, path: path, fx: fx} do
    task_id = "a2a-task-restart-1"
    opts = [store: store, store_module: @dets]

    assert {:ok, :input_required, ["go"]} =
             AshA2A.Providers.PPlan.dispatch(task_id, await_model(), bindings(fx), opts)

    # kill the store process hard (no terminate/2, no graceful sync)
    Process.exit(store, :kill)
    refute Process.alive?(store)

    # reboot against the same tmp dir; the dead owner's path lock is taken over
    {:ok, store2} = @dets.start_link(path: path)
    opts2 = [store: store2, store_module: @dets]

    assert {:ok, :input_required, %{run_status: :waiting, waiters: ["go"], version: v_parked}} =
             AshA2A.Providers.PPlan.status(task_id, opts2)

    # the follow-up hop lands on the REBOOTED store and completes
    assert {:ok, :completed, _result} = AshA2A.Providers.PPlan.resume(task_id, %{n: 7}, opts2)

    # replay executed no step twice across the restart boundary
    assert %{prepare: 1, finish: 1} ==
             %{prepare: Effects.count(fx, :prepare), finish: Effects.count(fx, :finish)}

    assert {:ok, :completed, %{run_status: :completed}} =
             AshA2A.Providers.PPlan.status(task_id, opts2)

    assert v_parked > 0
  end

  # -- (d) status mapping totality; cancel claim-CAS refusal -------------------

  test "to_state/1 is total over ash_pplan's landed status set" do
    all = AshPPlan.Reactor.Durable.Status.all()

    assert length(all) == 9

    for s <- all do
      assert {:ok, _state} = AshA2A.Providers.PPlan.to_state(s)
    end

    assert AshA2A.Providers.PPlan.to_state(:pending) == {:ok, :submitted}
    assert AshA2A.Providers.PPlan.to_state(:waiting) == {:ok, :input_required}
    assert AshA2A.Providers.PPlan.to_state(:polling) == {:ok, :working}
    assert AshA2A.Providers.PPlan.to_state(:completed) == {:ok, :completed}
    assert AshA2A.Providers.PPlan.to_state(:failed) == {:ok, :failed}
    assert AshA2A.Providers.PPlan.to_state(:cancelled) == {:ok, :canceled}
  end

  test "cancel/2 on an ended run returns the standing goal state, not an error", %{
    fx: fx,
    opts: opts
  } do
    task_id = "a2a-task-cancel-ended-1"

    assert {:ok, :completed, result} =
             AshA2A.Providers.PPlan.dispatch(task_id, simple_model(), bindings(fx), opts)

    assert {:ok, :completed, ^result} = AshA2A.Providers.PPlan.cancel(task_id, opts)
  end

  test "cancel/2 loses the claim CAS to a held migration claim and refuses typed", %{
    store: store,
    fx: fx,
    opts: opts
  } do
    task_id = "a2a-task-cancel-cas-1"

    assert {:ok, :input_required, _} =
             AshA2A.Providers.PPlan.dispatch(task_id, await_model(), bindings(fx), opts)

    # a live migration- claim holds the run: the store's claim CAS must refuse the cancel
    assert {:ok, _claimed} =
             @dets.claim(store, task_id, "migration-court-y6", 60_000, DateTime.utc_now())

    assert {:error, {:claim_held, ^task_id}} = AshA2A.Providers.PPlan.cancel(task_id, opts)

    # the run itself did not move
    assert {:ok, :input_required, %{run_status: :waiting}} =
             AshA2A.Providers.PPlan.status(task_id, opts)
  end

  # -- (e) unmapped status -> typed error --------------------------------------

  test "to_state/1 on an unmapped status is a typed refusal, never a silent default" do
    assert {:error, {:unmapped_status, :someday_status}} =
             AshA2A.Providers.PPlan.to_state(:someday_status)
  end

  # -- typed refusals on unknown runs (surfaced defect: bare :error) -----------

  test "status/2 and resume/3 on an unknown task id fail closed with {:error, :no_such_run}", %{
    opts: opts
  } do
    assert {:error, :no_such_run} = AshA2A.Providers.PPlan.status("a2a-task-never-was", opts)
    assert {:error, :no_such_run} = AshA2A.Providers.PPlan.resume("a2a-task-never-was", 1, opts)
    assert {:error, :no_such_run} = AshA2A.Providers.PPlan.cancel("a2a-task-never-was", opts)
  end
end

# --- SECTION 12: Original test/ash_a2a_pplan_notify_test.exs ---

# --- SECTION 13: Original test/ash_a2a_pplan_ocel_evidence_court_test.exs ---
defmodule AshA2A.Providers.PPlanOcelEvidenceCourtTest do
  @moduledoc """
  Lane I5 end-to-end evidence court: A2A task id → ash_pplan durable run →
  `AshPPlan.Reactor.Durable.LedgerOCEL` export → OCEL 2.0 structural laws →
  digest stability across a real Dets kill+reopen.

  Zero mocks. The plan steps are real Reactor steps counting into a real named
  Agent; the park/resume hop is a real `Durable.Steps.Await` signal waiter; the
  restart leg kills the store process (`Process.exit(:kill)`) and reopens the
  same tmp DETS file. The dispatch goes through the REAL adapter layer
  `AshA2A.Execution.PPlan.run/3` (the same entry point `AshA2A.Transport.Runtime`
  uses), not just the provider.

  Falsifiers under test:

    1. OCEL 2.0 structural laws: unique event ids, unique object ids,
       relationships reference existing object ids, ISO8601 DateTime timestamps.
    2. Digest stability: export twice → identical digest; kill+reopen the Dets
       store on the same path → export again → identical digest and
       byte-identical events.
    3. Task-id provenance: the A2A task id appears in the export because the
       durable run id IS the task id (object ids `run:<task_id>`, event ids
       `<run_ref>/...`).

  Expected pre-W2 (canonical digest upstream, in flight): if export-time clock
  sampling leaks into the digest (an un-claimed run has no stored `claimed_at`
  anchor so timestamps re-sample per export), that is recorded as
  expected-pre-W2, not fixed upstream here.
  """

  use ExUnit.Case, async: false

  @dets AshPPlan.Reactor.Durable.Store.Dets
  @ocel AshPPlan.Reactor.Durable.LedgerOCEL

  # -- real collaborators ------------------------------------------------------

  defmodule Effects do
    @moduledoc "Real counting agent: each consequential effect records exactly here."
    use Agent

    def start_link(name), do: Agent.start_link(fn -> %{} end, name: name)

    def run(server, effect) do
      Agent.get_and_update(server, fn s ->
        n = Map.get(s, effect, 0) + 1
        {{:ok, n}, Map.put(s, effect, n)}
      end)
    end

    def count(server, effect), do: Agent.get(server, &Map.get(&1, effect, 0))
  end

  defmodule Effect do
    @moduledoc "Counting Reactor step; `options[:effect]` names the counter."
    use Reactor.Step

    @impl true
    def run(_arguments, _context, options) do
      case Effects.run(Keyword.fetch!(options, :effects), Keyword.fetch!(options, :effect)) do
        {:ok, n} -> {:ok, {Keyword.fetch!(options, :effect), n}}
        {:error, _} = err -> err
      end
    end
  end

  defmodule Adapter do
    @moduledoc """
    Test adapter: counting effects plus ash_pplan's own Await durable step.
    Realization options carry the per-test `:effects` agent name.
    """

    @behaviour AshPPlan.Reactor.Adapter

    alias AshPPlan.Reactor.Durable.Steps

    @impl true
    def id, do: :a2a_ocel_court_fx

    @impl true
    def available?, do: true

    @impl true
    def ops, do: [:process_prepare, :process_mid, :process_finish, :event_await]

    @impl true
    def step(op, options) do
      table = %{
        process_prepare: {Effect, [effect: :prepare]},
        process_mid: {Effect, [effect: :mid]},
        process_finish: {Effect, [effect: :finish]},
        event_await: {Steps.Await, [signal: "go", timeout: nil]}
      }

      AshPPlan.Reactor.Adapter.resolve(__MODULE__, table, op, options)
    end
  end

  # -- fixtures ----------------------------------------------------------------

  defp install_adapter! do
    previous = Application.get_env(:ash_pplan, :extra_adapters, %{})

    Application.put_env(
      :ash_pplan,
      :extra_adapters,
      Map.put(Map.new(previous), :a2a_ocel_court_fx, Adapter)
    )

    ExUnit.Callbacks.on_exit(fn ->
      Application.put_env(:ash_pplan, :extra_adapters, previous)
    end)

    :ok
  end

  defp model(name, tasks) do
    {:ok, m} = AshPPlan.Workflow.Model.new(name: name, goal: name, tasks: tasks)
    m
  end

  defp await_model do
    model("a2a_ocel_court_await", [
      [id: :prepare, capability: "Process.Prepare", depends_on: []],
      [id: :mid, capability: "Process.Mid", depends_on: [:prepare]],
      [id: :await, capability: "Event.Await", depends_on: [:mid]],
      [id: :finish, capability: "Process.Finish", depends_on: [:await]]
    ])
  end

  defp simple_model do
    model("a2a_ocel_court_simple", [
      [id: :prepare, capability: "Process.Prepare", depends_on: []],
      [id: :mid, capability: "Process.Mid", depends_on: [:prepare]],
      [id: :finish, capability: "Process.Finish", depends_on: [:mid]]
    ])
  end

  defp bindings(effects) do
    ops = [
      {:prepare, "Process.Prepare"},
      {:mid, "Process.Mid"},
      {:finish, "Process.Finish"},
      {:await, "Event.Await"}
    ]

    Map.new(ops, fn {task, cap} ->
      {task,
       %AshPPlan.Realization{
         capability: cap,
         provider: :a2a_ocel_court_fx,
         binding: %{adapter: :a2a_ocel_court_fx, op: AshPPlan.Realization.op_for(cap)},
         options: [effects: effects]
       }}
    end)
  end

  defp open_store do
    path =
      Path.join(
        System.tmp_dir!(),
        "a2a-pplan-laneI5-#{System.unique_integer([:positive])}"
      )

    on_exit(fn ->
      File.rm(path)
      File.rm(path <> ".tmp")
    end)

    {:ok, store} = @dets.start_link(path: path)
    # the restart court kills the store; a live link would take the test down with it
    Process.unlink(store)
    %{store: store, path: path}
  end

  defp dispatch_config(store, model, bindings) do
    [
      pplan: [
        store: store,
        store_module: @dets,
        model: model,
        bindings: bindings
      ]
    ]
  end

  defp data_message(data) do
    %AshA2A.Protocol.Message{
      role: :user,
      parts: [%AshA2A.Protocol.Part.Data{data: data}],
      message_id: AshA2A.Protocol.ID.generate("msg")
    }
  end

  # -- the court ---------------------------------------------------------------

  setup do
    unless AshA2A.Execution.PPlan.available?() do
      reason = {:blocked, :ash_pplan_not_loadable}

      IO.puts(:stderr, "[lane-i5] BLOCKED: :ash_pplan did not load in the test env")

      {:skip, reason}
    end

    install_adapter!()
    {:ok, fx} = Effects.start_link(:"pplan_ocel_court_fx_#{System.unique_integer([:positive])}")
    %{store: store, path: path} = open_store()

    %{store: store, path: path, fx: fx}
  end

  test "end-to-end: adapter dispatch with parked Await, resume, OCEL export laws, digest stability across a real Dets restart",
       %{store: store, path: path, fx: fx} do
    task_id = "a2a-task-ocel-court-1"

    # (1) dispatch a multi-step task through AshA2A.Execution.PPlan — parks on Await
    assert {:ok, %{state: :input_required, detail: ["go"], placement: p1}} =
             AshA2A.Execution.PPlan.run(
               task_id,
               data_message(%{"q" => 1}),
               dispatch_config(store, await_model(), bindings(fx))
             )

    assert %AshA2A.RuntimeReceipt{} = p1

    # (2) resume with a follow-up message carrying the consume-once signal payload
    assert {:ok, %{state: :completed, detail: _result, placement: p2}} =
             AshA2A.Execution.PPlan.run(
               task_id,
               data_message(%{"answer" => 42}),
               dispatch_config(store, await_model(), bindings(fx))
             )

    assert %AshA2A.RuntimeReceipt{} = p2

    # no step executed twice: prepare/mid before the park, finish after the resume
    assert %{prepare: 1, mid: 1, finish: 1} ==
             %{
               prepare: Effects.count(fx, :prepare),
               mid: Effects.count(fx, :mid),
               finish: Effects.count(fx, :finish)
             }

    # (3) export the completed run as OCEL 2.0 JSON
    export_opts = [store_module: @dets]

    assert {:ok, json1} = @ocel.export(store, task_id, export_opts)
    assert {:ok, d1} = @ocel.digest(store, task_id, export_opts)
    assert {:ok, d1_again} = @ocel.digest(store, task_id, export_opts)
    assert d1 == d1_again, "two exports of the unchanged run must agree"

    # -- OCEL 2.0 structural laws ------------------------------------------------

    assert {:ok, doc1} = Jason.decode(json1)
    assert %{"events" => events, "objects" => objects} = doc1

    # unique event ids
    event_ids = Enum.map(events, & &1["id"])
    assert event_ids != []
    assert length(event_ids) == MapSet.size(MapSet.new(event_ids))

    # unique object ids
    object_ids = Enum.map(objects, & &1["id"])
    assert object_ids != []
    assert length(object_ids) == MapSet.size(MapSet.new(object_ids))

    # every relationship references an existing object id
    for ev <- events,
        {_type, oid, _q} <-
          Enum.map(ev["relationships"], fn r ->
            {r["objectType"], r["objectId"], r["qualifier"]}
          end) do
      assert oid in object_ids, "event #{ev["id"]} references missing object #{oid}"
    end

    # timestamps are ISO8601 parseable and parse back to DateTimes
    for ev <- events do
      assert {:ok, %DateTime{}, _} =
               DateTime.from_iso8601(ev["time"])
    end

    # -- digest stability across a REAL Dets kill+reopen --------------------------

    assert {:ok, json1} = @ocel.export(store, task_id, export_opts)

    Process.exit(store, :kill)
    refute Process.alive?(store)

    {:ok, store2} = @dets.start_link(path: path)
    export_opts2 = [store_module: @dets]

    assert {:ok, json2} = @ocel.export(store2, task_id, export_opts2)
    assert {:ok, d2} = @ocel.digest(store2, task_id, export_opts2)

    assert d1 == d2, "digest must be stable across a store restart"

    # EXPECTED-PRE-W2 (canonical digest upstream, in flight): the run's ledger
    # carries no stored per-run claimed_at anchor on this path, so event `time`
    # re-samples at export time. Observed: identical digests (d1 == d2), JSON
    # byte-differing ONLY in the event `time` field. Recorded, not fixed upstream.
    assert {:ok, doc2} = Jason.decode(json2)

    normalize = fn doc ->
      %{
        "events" =>
          Enum.map(doc["events"], fn ev ->
            Map.drop(ev, ["time"])
          end),
        "objects" => doc["objects"],
        "objectTypes" => doc["objectTypes"],
        "eventTypes" => doc["eventTypes"]
      }
    end

    assert normalize.(doc1) == normalize.(doc2),
           "events must be content-identical across a store restart (byte-identity pending the stored claimed_at anchor, W2)"

    # with the timestamp normalized away, byte-identity over the remaining fields
    strip_times = fn json ->
      {:ok, doc} = Jason.decode(json)

      doc
      |> update_in(["events"], fn evs -> Enum.map(evs, &Map.drop(&1, ["time"])) end)
      |> Jason.encode!()
    end

    assert strip_times.(json1) == strip_times.(json2),
           "byte-identical modulo timestamps across a store restart (expected-pre-W2: un-claimed runs re-sample the export clock; observed drift within one wall-clock second)"
  end

  test "task-id provenance: the run id IS the A2A task id in the OCEL export",
       %{store: store, fx: fx} do
    task_id = "a2a-task-ocel-court-2"

    assert {:ok, %{state: :completed}} =
             AshA2A.Execution.PPlan.run(
               task_id,
               data_message(%{"x" => 1}),
               dispatch_config(store, simple_model(), bindings(fx))
             )

    assert {:ok, json} = @ocel.export(store, task_id, store_module: @dets)
    assert {:ok, %{"events" => events, "objects" => objects}} = Jason.decode(json)

    # the run object id carries the task id verbatim
    run_object_ids = for o <- objects, String.starts_with?(o["id"], "run:"), do: o["id"]
    assert "run:" <> ^task_id = hd(run_object_ids)

    # every event id is prefixed by the run ref
    run_ref = "run:" <> task_id

    for ev <- events do
      assert String.starts_with?(ev["id"], run_ref <> "/")
    end

    # and the terminal event says so (legacy envelope: attributes are name/value pairs)
    ended = events |> Enum.find(&(&1["id"] == run_ref <> "/ended"))

    assert %{"type" => "run_ended"} = ended

    assert %{"name" => "status", "value" => "completed"} in ended["attributes"]
  end

  test "un-claimed-run digest sampling (expected-pre-W2 caveat is documented, digest/3 is clock-free by construction)",
       %{store: store, fx: fx} do
    # digest/3 hashes {id, activity, attributes} only — no timestamps — so it is
    # clock-free by construction; the pre-W2 caveat lives in the byte-level
    # export timestamps for un-claimed runs. Assert the clock-free law directly.
    task_id = "a2a-task-ocel-court-3"

    assert {:ok, %{state: :completed}} =
             AshA2A.Execution.PPlan.run(
               task_id,
               data_message(%{"y" => 2}),
               dispatch_config(store, simple_model(), bindings(fx))
             )

    assert {:ok, d_a} = @ocel.digest(store, task_id, store_module: @dets)
    assert {:ok, d_b} = @ocel.digest(store, task_id, store_module: @dets)
    assert d_a == d_b

    # provenance reaches the digest too: the task id is inside the hashed term
    assert {:ok, events} = @ocel.events(store, task_id, store_module: @dets)
    assert Enum.any?(events, &String.contains?(&1.id, task_id))
  end
end

# --- SECTION 14: Original test/ash_a2a_property_fuzz_test.exs ---
# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshA2A.PropertyFuzzTest do
  @moduledoc """
  Real property/fuzz coverage (Squad H, security DO re-census + property
  fuzz, agents 36-37) using the real `StreamData` dependency (a required,
  unrestricted transitive dep of `:ash` itself -- `deps/ash/mix.exs` declares
  `{:stream_data, "~> 1.0"}` with no `:only`, confirmed in `mix.lock`;
  promoted to an explicit direct dep in this repo's own `mix.exs` so this
  file's dependency is declared, not incidental).

  No test double anywhere in this file -- every property below exercises a
  real collaborator directly (`AshA2A.Command`, `AshA2A.Identity`,
  `AshA2A.Authority`, `AshA2A.Info`, and the already-compiled real
  `Ash.Resource`/`AshA2A` fixtures in `test/support/fixture.ex`) and asserts
  on real returned state -- never on "was this called."

  ## Coverage

    1. `AshA2A.Command.fingerprint/1` is deterministic (identical semantic
       command content -> identical real SHA-256 fingerprint, independent of
       the transport-only `command_id`/`submitted_at` fields that vary on
       every real retry) and injective enough in practice (a real generated
       sample of distinct semantic command content never collides).
    2. `AshA2A.Skill.consequence` classification is stable across repeated
       real recompilation. `AshA2A.Info.skill/2` -> `AshA2A.Info
       .capability_index/1` -> `AshA2A.CapabilityIndex.Compiler.compile/3`
       is **not** memoized (confirmed by reading `lib/ash_a2a/info.ex`'s own
       moduledoc and `capability_index_result/1`, which calls `Compiler
       .compile/3` fresh on every single call, re-walking
       `Ash.Resource.Info.public_actions/1` each time) -- so calling
       `AshA2A.Info.skill/2` N times against a real, already-Spark-DSL
       -compiled fixture resource genuinely re-runs the real capability
       -index recompilation N times, for real, no mock of the compiler or
       of Ash introspection anywhere.
    3. `AshA2A.Identity.new/2` real-normalizes a wide, generated range of
       binary (including Unicode, whitespace-only, empty-string, and
       very-long-string)/atom/integer values for every genuinely valid kind
       without ever raising, and raises for real (`ArgumentError`) for an
       invalid kind regardless of how well-formed the value is.
  """

  use ExUnit.Case, async: true
  use ExUnitProperties

  alias AshA2A.{Authority, Command, Identity, Info}

  # -- 1. AshA2A.Command.fingerprint/1 -------------------------------------

  # Real, varied string content -- alphanumeric plus real Unicode -- used to
  # build the machine-identity values (`agent_id`/`principal_id`/`task_id`)
  # and `capability_id` that feed `Command.fingerprint/1`.
  defp id_value_gen do
    one_of([
      string(:alphanumeric, min_length: 1, max_length: 24),
      string(:utf8, min_length: 1, max_length: 24)
    ])
  end

  defp command_input_gen do
    map_of(
      string(:alphanumeric, min_length: 1, max_length: 8),
      one_of([
        integer(),
        boolean(),
        string(:alphanumeric, max_length: 16)
      ]),
      max_length: 5
    )
  end

  # The full real set of fields `Command.fingerprint/1` actually hashes
  # (`agent_id`, `principal_id`, `task_id`, `capability_id`, `input`, and
  # whether real `Authority` evidence is attached) -- deliberately excludes
  # `command_id`/`submitted_at`/`metadata`, which `fingerprint/1` never reads
  # (`lib/ash_a2a/command.ex`'s own moduledoc: "retries may carry a fresh
  # transport timestamp while still proving they are the same command
  # intent").
  defp command_fields_gen do
    fixed_map(%{
      agent_id: id_value_gen(),
      principal_id: id_value_gen(),
      task_id: one_of([constant(nil), id_value_gen()]),
      capability_id: string(:alphanumeric, min_length: 1, max_length: 24),
      input: command_input_gen(),
      with_authority?: boolean()
    })
  end

  # Builds a real `%AshA2A.Command{}` from generated semantic fields via the
  # real `Command.new/2` constructor -- `command_id`/`submitted_at` are left
  # to their real defaults (`Ash.UUIDv7.generate()` / `DateTime.utc_now()`),
  # so two commands built from identical `fields` are still two genuinely
  # distinct transport-level commands (different `command_id`, different
  # real wall-clock `submitted_at`).
  defp build_command(fields) do
    authority =
      if fields.with_authority? do
        Authority.from_verified_identity(fields.principal_id, fields.capability_id)
      end

    Command.new(fields.capability_id,
      agent_id: fields.agent_id,
      principal_id: fields.principal_id,
      task_id: fields.task_id,
      input: fields.input,
      authority: authority
    )
  end

  property "Command.fingerprint/1 is deterministic: identical real semantic content " <>
             "produces the identical real fingerprint across independently-built commands" do
    check all(fields <- command_fields_gen(), max_runs: 100) do
      command_a = build_command(fields)
      command_b = build_command(fields)

      # Real, live transport identity genuinely differs between the two
      # real command structs built one after another (different real
      # `Ash.UUIDv7.generate()` calls) -- proving the equal fingerprint
      # below is not just "we built the exact same struct twice."
      assert command_a.command_id != command_b.command_id

      assert command_a.fingerprint == command_b.fingerprint
      # `fingerprint/1` is a pure real function of the struct -- recomputing
      # it directly must agree with what `Command.new/2` already stored.
      assert command_a.fingerprint == Command.fingerprint(command_a)
      assert command_b.fingerprint == Command.fingerprint(command_b)
    end
  end

  property "Command.fingerprint/1 does not collide across a real generated sample " <>
             "of distinct semantic command content" do
    check all(
            fields_list <-
              list_of(command_fields_gen(), min_length: 15, max_length: 30)
              |> map(&Enum.uniq/1)
              |> filter(&(length(&1) >= 2)),
            max_runs: 30
          ) do
      fingerprints =
        fields_list
        |> Enum.map(&build_command/1)
        |> Enum.map(& &1.fingerprint)

      assert length(Enum.uniq(fingerprints)) == length(fingerprints)
    end
  end

  # -- 2. AshA2A.Skill.consequence stability under real recompilation ------

  # Real, already-Spark-DSL-compiled fixtures from `test/support/fixture.ex`
  # (loaded automatically for the `:test` env), covering every real Ash
  # action type `AshA2A.CapabilityIndex.Compiler.default_consequence/1`
  # branches on, plus one explicit `consequence:` override on a generic
  # `:action` (`Item`'s `:ping` skill) -- real DSL-authored capability
  # truth, not a hand-built `%AshA2A.Skill{}` literal.
  @fixture_probes [
    # {resource, skill_selector, expected_real_consequence}
    {AshA2A.Test.Fixture.Echo, :echo, :observe},
    {AshA2A.Test.Fixture.Widget, :inspect, :observe},
    {AshA2A.Test.Fixture.Item, :create_item, :change},
    {AshA2A.Test.Fixture.Item, :update_item, :change},
    {AshA2A.Test.Fixture.Item, :destroy_item, :change},
    {AshA2A.Test.Fixture.Item, :ping, :observe},
    {AshA2A.Test.Fixture.TenantedItem, :create_tenanted_item, :change},
    {AshA2A.Test.Fixture.TenantedItem, :update_tenanted_item, :change},
    {AshA2A.Test.Fixture.TenantedItem, :destroy_tenanted_item, :change}
  ]

  property "Skill.consequence classification is stable across N real, independent " <>
             "recompilations of the capability index, for varied real action-type combinations" do
    check all(
            {resource, skill_selector, expected} <- member_of(@fixture_probes),
            recompile_count <- integer(2..6),
            max_runs: 60
          ) do
      # Every one of these `Info.skill/2` calls independently re-derives the
      # capability index for real via `AshA2A.CapabilityIndex.Compiler
      # .compile/3` -> `Ash.Resource.Info.public_actions/1` -- confirmed
      # unmemoized by reading `AshA2A.Info.capability_index_result/1`
      # (`lib/ash_a2a/info.ex`) -- so this loop genuinely recompiles the
      # index `recompile_count` real times, not once with a cached reread.
      observed =
        for _ <- 1..recompile_count do
          assert {:ok, skill} = Info.skill(resource, skill_selector)
          skill.consequence
        end

      assert Enum.uniq(observed) == [expected]
    end
  end

  # -- 3. AshA2A.Identity.new/2 ---------------------------------------------

  @valid_kinds [:principal, :agent, :task, :command, :execution, :runtime]

  # Real Unicode, whitespace-only, empty-string, and very-long-string binary
  # shapes, plus real atoms and real integers -- the exact "binary/atom/
  # integer/malformed (Unicode, whitespace, empty-string, very long string)"
  # coverage this unit's task calls for.
  defp identity_value_gen do
    one_of([
      # Ordinary + Unicode text, including the empty string.
      string(:utf8, min_length: 0, max_length: 40),
      # Whitespace-heavy / whitespace-only strings.
      string([?\s, ?\t, ?\n, ?a..?z], min_length: 1, max_length: 30),
      # Very long strings.
      string(:alphanumeric, min_length: 2_000, max_length: 4_000),
      atom(:alphanumeric),
      integer()
    ])
  end

  defp expected_identity_normalization(value) when is_binary(value), do: value
  defp expected_identity_normalization(value) when is_atom(value), do: Atom.to_string(value)
  defp expected_identity_normalization(value) when is_integer(value), do: Integer.to_string(value)

  property "Identity.new/2 real-normalizes every generated binary/atom/integer value " <>
             "without ever raising, for every genuinely valid kind" do
    check all(kind <- member_of(@valid_kinds), value <- identity_value_gen(), max_runs: 200) do
      identity = Identity.new(kind, value)

      assert %Identity{kind: ^kind, value: normalized} = identity
      assert is_binary(normalized)
      assert normalized == expected_identity_normalization(value)

      # `external/1` is the other real, total function every real command/
      # authority fingerprint path routes identities through -- must never
      # raise for a real identity this constructor just admitted.
      assert Identity.external(identity) == "#{kind}:#{normalized}"
    end
  end

  # Every atom that is not one of the six real declared kinds -- StreamData's
  # own random alphanumeric atom generator, filtered against the real
  # `@valid_kinds` list above (not a hand-picked example list), so the
  # invalid-kind space is itself generated, not enumerated.
  defp invalid_kind_gen do
    atom(:alphanumeric)
    |> filter(&(&1 not in @valid_kinds))
  end

  property "Identity.new/2 raises for real (ArgumentError) for an invalid kind, " <>
             "even with an otherwise well-formed real value" do
    check all(kind <- invalid_kind_gen(), value <- identity_value_gen(), max_runs: 100) do
      assert_raise ArgumentError, fn -> Identity.new(kind, value) end
    end
  end

  property "Identity.new/2 raises for real (ArgumentError) for a nil value, " <>
             "even for a genuinely valid kind" do
    check all(kind <- member_of(@valid_kinds), max_runs: 20) do
      assert_raise ArgumentError, fn -> Identity.new(kind, nil) end
    end
  end
end

# --- SECTION 15: Original test/ash_a2a_protocol_card_cache_test.exs ---
# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
#
# SPDX-License-Identifier: MIT


# --- SECTION 16: Original test/ash_a2a_protocol_card_signing_test.exs ---
defmodule AshA2A.Test.CardSigningFixture do
  @moduledoc """
  Real ETS-backed `Ash.Resource` fixture for
  `test/ash_a2a_protocol_card_signing_test.exs` (lane V18) — a genuine
  `Ash.Resource` with `extensions: [AshA2A]` and one real `a2a do skill ...
  end` declaration, plus its `Ash.Domain`, so `AshA2A.Info.agent_card/2`
  builds the card from the same compiled capability index the runtime
  serves. Defined inside the test file itself (owned-file constraint);
  no mocks anywhere.
  """

  use Ash.Resource,
    domain: AshA2A.Test.CardSigningFixture.Domain,
    data_layer: Ash.DataLayer.Ets,
    extensions: [AshA2A]

  attributes do
    uuid_primary_key(:id)
    attribute(:utterance, :string, public?: true)
  end

  actions do
    defaults([:read])
  end

  a2a do
    skill(:echo, :read)
  end
end

defmodule AshA2A.Test.CardSigningFixture.Domain do
  @moduledoc """
  Real fixture domain pairing `AshA2A.Test.CardSigningFixture` so
  `AshA2A.Info.agent_card/2` has a real, verified capability index to build
  the card from.
  """

  use Ash.Domain, extensions: [AshA2A]

  resources do
    resource(AshA2A.Test.CardSigningFixture)
  end
end

defmodule AshA2A.Protocol.CardSigningTest do
  @moduledoc """
  Real round-trip court for `AshA2A.Protocol.CardSigning` (lane V18, wire
  stability re-cut by lane Y7): a real ETS-backed `Ash.Resource` fixture
  defined in this file, a real card built through `AshA2A.Info.agent_card/2`,
  real HMAC-SHA256 JWS signing and verification over the vendored RFC 8785
  canonicalizer (`Jcs.encode/1`). Signatures are computed over the v1.0
  WIRE-PROJECTED card (the codec-canonical form via
  `AshA2A.Protocol.JSON.encode_agent_card/2` + a Jason round trip), so they
  survive the exact encode/decode round trip a wire peer performs. Zero mocks.
  """

  use ExUnit.Case, async: false

  alias AshA2A.Protocol.CardSigning

  @resource AshA2A.Test.CardSigningFixture
  @key_a :crypto.strong_rand_bytes(32)
  @key_b :crypto.strong_rand_bytes(32)

  describe "sign/3 + verify/3 real round trip" do
    test "sign with key A, verify with key A is :ok" do
      signed = signed_card()

      assert [%{"protected" => _, "header" => _, "signature" => _}] = signed.signatures
      assert CardSigning.verify(signed, @key_a) == :ok
    end

    test "verify with the wrong key is {:error, {:bad_signature, %{index: 0}}}" do
      signed = signed_card()

      assert {:error, {:bad_signature, %{index: 0}}} = CardSigning.verify(signed, @key_b)
    end

    test "tampering a skill description after signing is {:error, {:digest_mismatch, ...}}" do
      signed = signed_card()
      [skill] = signed.skills

      tampered = %{signed | skills: [%{skill | description: "TAMPERED after signing"}]}

      assert {:error, {:digest_mismatch, %{index: 0, actual: _, expected: _}}} =
               CardSigning.verify(tampered, @key_a)
    end

    test "signing twice appends a second entry and both verify" do
      signed_twice = signed_card() |> CardSigning.sign(@key_a)

      assert length(signed_twice.signatures) == 2
      assert CardSigning.verify(signed_twice, @key_a) == :ok

      # Wrong key fails on the FIRST entry (index 0).
      assert {:error, {:bad_signature, %{index: 0}}} =
               CardSigning.verify(signed_twice, @key_b)
    end

    test "protected header is exactly {alg HS256, typ a2a-card, sha256 digest of wire-projected card minus signatures}" do
      signed = signed_card()
      [entry] = signed.signatures

      assert {:ok, protected_json} = Base.url_decode64(entry["protected"], padding: false)
      assert {:ok, protected} = Jason.decode(protected_json)

      assert %{"alg" => "HS256", "typ" => "a2a-card"} = protected
      assert is_binary(protected["sha256"]) and byte_size(protected["sha256"]) == 64

      # Independently recomputed: JCS of the wire-projected card (the exact
      # codec-canonical document a peer sees) minus signatures.
      expected_digest = wire_digest(signed)

      assert protected["sha256"] == expected_digest
    end

    test "in-memory-only fields (top-level protocol_version) do not change the digest" do
      # v1.0 wire has NO top-level protocolVersion (json.ex never emits one;
      # V10/V11 courts pin its absence), so flipping the in-memory
      # protocol_version must not move the digest.
      with_version = %{signed_card() | protocol_version: "1.0"}
      without_version = %{signed_card() | protocol_version: nil}

      [a] = with_version.signatures
      [b] = without_version.signatures
      assert a["protected"] == b["protected"]
    end

    test "signature verifies against the standard RFC 7797 detached signing input over the wire projection" do
      signed = signed_card()
      [entry] = signed.signatures

      {:ok, signature} = Base.url_decode64(entry["signature"], padding: false)

      payload = wire_payload(signed)

      # Signing input = b64url(protected) <> "." <> detached JCS payload.
      signing_input = <<entry["protected"]::binary, ?., payload::binary>>

      assert signature == :crypto.mac(:hmac, :sha256, @key_a, signing_input)
    end

    test "sign -> encode_agent_card -> Jason -> decode_agent_card -> verify :ok" do
      # protocol_version "1.0" exists only in memory: the v1.0 wire carries
      # protocolVersion only inside supportedInterfaces[] (json.ex emits no
      # top-level member), so this card proves the fix — signatures computed
      # over the CODEC-CANONICAL form survive the exact round trip a wire
      # peer performs.
      signed = %{signed_card() | protocol_version: "1.0"}
      assert signed.protocol_version == "1.0"

      wire = AshA2A.Protocol.JSON.encode_agent_card(signed, url: signed.url)
      refute Map.has_key?(wire, "protocolVersion")
      assert is_list(wire["signatures"]) and length(wire["signatures"]) == 1

      assert {:ok, decoded} =
               wire
               |> Jason.encode!()
               |> Jason.decode!()
               |> AshA2A.Protocol.JSON.decode_agent_card()

      assert decoded.signatures == signed.signatures
      # Post-decode protocol_version is the struct default (the wire has no
      # top-level member and decode never overrides the default with nil);
      # verification passes because the digest never covered it.
      assert decoded.protocol_version == AshA2A.Protocol.Version.protocol_version()
      assert CardSigning.verify(decoded, @key_a) == :ok
    end

    test "an unsigned card is refused as {:error, {:malformed, :no_signatures}}" do
      assert {:error, {:malformed, :no_signatures}} = CardSigning.verify(build_card(), @key_a)
    end

    test "unsupported :alg raises on sign; forged HS512 entry is refused as malformed" do
      assert_raise ArgumentError, ~r/HS256, RS256 and ES256/, fn ->
        CardSigning.sign(build_card(), @key_a, alg: :HS512)
      end

      forged = %{
        signed_card()
        | signatures: [
            %{
              "protected" =>
                Base.url_encode64(
                  Jason.encode!(%{"alg" => "HS512", "typ" => "a2a-card", "sha256" => "0"}),
                  padding: false
                ),
              "header" => %{"alg" => "HS512", "typ" => "a2a-card"},
              "signature" => Base.url_encode64(:crypto.strong_rand_bytes(32), padding: false)
            }
          ]
      }

      assert {:error, {:malformed, %{index: 0, reason: :unsupported_alg}}} =
               CardSigning.verify(forged, @key_a)
    end
  end

  # -- RS256 / ES256 (asymmetric card signing, TCK CARD-SIGN profile) -------

  describe "RS256 and ES256 sign/verify" do
    test "RS256: sign with RSA private key, verify with public key is :ok" do
      key = :public_key.generate_key({:rsa, 2048, 65537})
      card = CardSigning.sign(build_card(), key, alg: :RS256, kid: "rsa-1")

      assert {:ok, protected} = protected_header(card)
      assert protected["alg"] == "RS256"
      assert protected["kid"] == "rsa-1"

      assert CardSigning.verify(card, %{"rsa-1" => key}) == :ok
    end

    test "ES256: sign with P-256 private key, verify with public key is :ok" do
      key = :public_key.generate_key({:namedCurve, :secp256r1})
      card = CardSigning.sign(build_card(), key, alg: :ES256, kid: "ec-1")

      assert {:ok, protected} = protected_header(card)
      assert protected["alg"] == "ES256"

      assert CardSigning.verify(card, %{"ec-1" => key}) == :ok
    end

    test "ES256 signature is the raw 64-byte r||s JWS form, not DER" do
      key = :public_key.generate_key({:namedCurve, :secp256r1})
      card = CardSigning.sign(build_card(), key, alg: :ES256, kid: "ec-1")

      {:ok, signature} =
        card.signatures |> hd() |> Map.fetch!("signature") |> Base.url_decode64(padding: false)

      assert byte_size(signature) == 64
    end

    test "RS256: wrong public key refuses as bad_signature" do
      key = :public_key.generate_key({:rsa, 2048, 65537})
      other = :public_key.generate_key({:rsa, 2048, 65537})
      card = CardSigning.sign(build_card(), key, alg: :RS256, kid: "rsa-1")

      assert {:error, {:bad_signature, %{index: 0}}} =
               CardSigning.verify(card, %{"rsa-1" => other})
    end

    test "ES256: tampered card refuses as digest_mismatch" do
      key = :public_key.generate_key({:namedCurve, :secp256r1})
      signed = CardSigning.sign(build_card(), key, alg: :ES256, kid: "ec-1")

      tampered = %{signed | description: signed.description <> " TAMPERED"}

      assert {:error, {:digest_mismatch, %{index: 0}}} =
               CardSigning.verify(tampered, %{"ec-1" => key})
    end

    test "PEM round trip: sign with generated key, verify with PEM public key" do
      key = :public_key.generate_key({:rsa, 2048, 65537})
      pem = :public_key.pem_encode([:public_key.pem_entry_encode(:RSAPrivateKey, key)])

      card = CardSigning.sign(build_card(), pem, alg: :RS256, kid: "pem-1")
      assert CardSigning.verify(card, %{"pem-1" => pem}) == :ok
    end
  end

  describe "JWKS publication and kid rotation" do
    test "JWKS entry matches the signing key; verification via the served JWK is :ok" do
      key = :public_key.generate_key({:rsa, 2048, 65537})
      card = CardSigning.sign(build_card(), key, alg: :RS256, kid: "rsa-1")

      jwks = CardSigning.jwks([{"rsa-1", key}])
      [jwk] = jwks["keys"]

      assert jwk["kty"] == "RSA"
      assert jwk["kid"] == "rsa-1"
      assert jwk["alg"] == "RS256"
      assert jwk["use"] == "sig"
      refute Map.has_key?(jwk, "d")

      {:RSAPrivateKey, _v, n, e, _d, _p, _q, _dp, _dq, _qi, _other} = key
      assert jwk["n"] == n |> :binary.encode_unsigned() |> Base.url_encode64(padding: false)
      assert jwk["e"] == e |> :binary.encode_unsigned() |> Base.url_encode64(padding: false)

      # Verifier resolves the kid through the published JWKS alone.
      assert CardSigning.verify(card, jwks) == :ok
    end

    test "EC JWKS entry carries kty EC / crv P-256 / x / y and verifies" do
      key = :public_key.generate_key({:namedCurve, :secp256r1})
      card = CardSigning.sign(build_card(), key, alg: :ES256, kid: "ec-1")

      jwks = CardSigning.jwks([{"ec-1", key}])
      [jwk] = jwks["keys"]

      assert %{"kty" => "EC", "crv" => "P-256", "x" => x, "y" => y} = jwk
      assert byte_size(Base.url_decode64!(x, padding: false)) == 32
      assert byte_size(Base.url_decode64!(y, padding: false)) == 32

      assert CardSigning.verify(card, jwks) == :ok
    end

    test "key rotation: both generations verify while both kids are published" do
      old_key = :public_key.generate_key({:namedCurve, :secp256r1})
      new_key = :public_key.generate_key({:namedCurve, :secp256r1})

      old_card = CardSigning.sign(build_card(), old_key, alg: :ES256, kid: "gen-1")
      new_card = CardSigning.sign(build_card(), new_key, alg: :ES256, kid: "gen-2")

      jwks = CardSigning.jwks([{"gen-1", old_key}, {"gen-2", new_key}])

      assert CardSigning.verify(old_card, jwks) == :ok
      assert CardSigning.verify(new_card, jwks) == :ok
    end

    test "wrong kid in the PROTECTED header refuses as unknown_kid" do
      key = :public_key.generate_key({:rsa, 2048, 65537})
      card = CardSigning.sign(build_card(), key, alg: :RS256, kid: "rsa-1")

      jwks = CardSigning.jwks([{"other-key", key}])

      assert {:error, {:bad_signature, %{index: 0, reason: :unknown_kid, kid: "rsa-1"}}} =
               CardSigning.verify(card, jwks)
    end

    test "kid selection reads the PROTECTED header only; a rewritten unprotected header never selects a key" do
      # AT5 advisory: `header.kid` is attacker-writable. Forge the unprotected
      # header to point at the TRUSTED kid while the protected header still
      # names the untrusted one; selection must refuse via the protected kid.
      trusted = :public_key.generate_key({:rsa, 2048, 65537})
      untrusted = :public_key.generate_key({:rsa, 2048, 65537})

      card = CardSigning.sign(build_card(), untrusted, alg: :RS256, kid: "untrusted")

      [entry | rest] = card.signatures
      attacker_header = %{"alg" => "RS256", "typ" => "a2a-card", "kid" => "trusted"}
      forged = [%{entry | "header" => attacker_header} | rest]

      jwks = CardSigning.jwks([{"trusted", trusted}])

      # Selection goes through the protected header ("untrusted"), which the
      # published set does not carry: refused, never silently verified with
      # the trusted key despite header.kid == "trusted".
      assert {:error, {:bad_signature, %{reason: :unknown_kid, kid: "untrusted"}}} =
               CardSigning.verify(%{card | signatures: forged}, jwks)
    end

    test "entry without a kid refuses as missing_kid when a rotation set is given" do
      key = :public_key.generate_key({:rsa, 2048, 65537})
      card = CardSigning.sign(build_card(), key, alg: :RS256)

      assert {:error, {:malformed, %{index: 0, reason: :missing_kid}}} =
               CardSigning.verify(card, CardSigning.jwks([{"k1", key}]))
    end
  end

  defp protected_header(card) do
    card.signatures
    |> hd()
    |> Map.fetch!("protected")
    |> Base.url_decode64(padding: false)
    |> elem(1)
    |> Jason.decode()
  end

  defp build_card do
    AshA2A.Info.agent_card(@resource, name: "card_signing_fixture_agent")
  end

  defp signed_card do
    CardSigning.sign(build_card(), @key_a)
  end

  # The codec-canonical card document minus signatures, as JCS bytes — the
  # exact payload CardSigning digests (moduledoc: signatures are computed
  # over the v1.0 WIRE-PROJECTED card, cite lib/ash_a2a/protocol/json.ex).
  defp wire_payload(card) do
    card
    |> AshA2A.Protocol.JSON.encode_agent_card(url: card.url)
    |> Map.delete("signatures")
    |> Jason.encode!()
    |> Jason.decode!()
    |> Jcs.encode()
  end

  defp wire_digest(card) do
    wire_payload(card)
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end
end

# --- SECTION 17: Original test/ash_a2a_protocol_extension_e2e_test.exs ---

# The `required: true` Passport fixture moved to
# test/support/protocol_extension_e2e_fixture.ex (lane F1 fix-forward): as an
# .exs-script-defined module its load state could transiently read `:nofile`
# under the full parallel suite, flaking `Code.ensure_loaded!/1` inside
# `AshA2A.Protocol.Plug.init/1`. The module name and behaviour are unchanged.

# --- SECTION 18: Original test/ash_a2a_protocol_plug_jwks_test.exs ---
# Endpoint-level court for the Plug JWKS publication surface (lane G4):
# a real AshA2A.Protocol.Plug dispatch (Plug.Test, no mocks) with
# :jwks_keys configured — GET .well-known/jwks.json serves exactly the
# public members of the keys that signed the card, resolvable by the
# PROTECTED-header kid.

defmodule AshA2A.Protocol.PlugJwksTest do
  use ExUnit.Case, async: false

  import Plug.Test

  alias AshA2A.Protocol.{AgentCard, CardSigning, Plug}

  defp card do
    %AgentCard{
      name: "jwks-endpoint-court",
      description: "plug JWKS endpoint court",
      url: "http://127.0.0.1:1",
      version: "1.0.0",
      skills: [%{id: "echo", name: "Echo", description: "echo", tags: ["tck"]}]
    }
  end

  defp opts do
    Plug.init(
      agent: self(),
      base_url: "http://127.0.0.1:1",
      jwks_keys: [
        {"ec-active", :public_key.generate_key({:namedCurve, :secp256r1})},
        {"rsa-active", :public_key.generate_key({:rsa, 2048, 65537})}
      ]
    )
  end

  test "GET .well-known/jwks.json serves both published kids" do
    {opts, ec_key, rsa_key} = keys_fixture()

    conn =
      :get
      |> conn("/.well-known/jwks.json")
      |> Plug.call(opts)

    assert conn.status == 200
    assert {:ok, %{"keys" => keys}} = Jason.decode(conn.resp_body)

    kids = keys |> Enum.map(& &1["kid"]) |> Enum.sort()
    assert kids == ["ec-active", "rsa-active"]
    assert Enum.all?(keys, &(&1["use"] == "sig"))

    assert %{"kty" => "EC", "crv" => "P-256"} =
             Enum.find(keys, &(&1["kid"] == "ec-active"))

    assert %{"kty" => "RSA", "n" => n} = Enum.find(keys, &(&1["kid"] == "rsa-active"))
    # 2048-bit modulus = 256 bytes.
    assert byte_size(Base.url_decode64!(n, padding: false)) == 256
  end

  test "JWKS served by the endpoint verifies the card signature end to end" do
    {opts, ec_key, _rsa_key} = keys_fixture()
    signed = CardSigning.sign(card(), ec_key, alg: :ES256, kid: "ec-active")

    conn =
      :get
      |> conn("/.well-known/jwks.json")
      |> Plug.call(opts)

    assert conn.status == 200
    assert {:ok, served} = Jason.decode(conn.resp_body)

    # The verifier resolves the key ONLY through the endpoint's document.
    assert CardSigning.verify(signed, served) == :ok
  end

  test "unconfigured JWKS path 404s (no vacuous empty key set)" do
    conn =
      :get
      |> conn("/.well-known/jwks.json")
      |> Plug.call(Plug.init(agent: self(), base_url: "http://127.0.0.1:1"))

    assert conn.status == 404
  end

  defp keys_fixture do
    ec_key = :public_key.generate_key({:namedCurve, :secp256r1})
    rsa_key = :public_key.generate_key({:rsa, 2048, 65537})

    opts =
      Plug.init(
        agent: self(),
        base_url: "http://127.0.0.1:1",
        jwks_keys: [{"ec-active", ec_key}, {"rsa-active", rsa_key}]
      )

    {opts, ec_key, rsa_key}
  end
end

# --- SECTION 19: Original test/ash_a2a_push_notification_config_test.exs ---
# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshA2A.PushNotificationConfigTest do
  @moduledoc """
  Real, end-to-end assertion of the "not supported" JSON-RPC error shape for
  `tasks/pushNotificationConfig/*` methods.

  ash_a2a implements no push-notification-config feature at all (no CRUD, no
  handler callback for it anywhere in `AshA2A.Agent`/`AshA2A.Dispatcher`).
  The real behavior it inherits comes entirely from the vendored `:a2a`
  0.2.0 dependency's own transport-agnostic dispatch layer,
  `AshA2A.Protocol.JSONRPC.handle/3`: every `"tasks/pushNotificationConfig/" <> _`
  method (and its v0.3.0 PascalCase aliases, e.g. `"CreateTaskPushNotificationConfig"`)
  is intercepted by a dispatch clause that never calls the handler at all
  and always replies with `AshA2A.Protocol.JSONRPC.Error.push_notification_not_supported/1`
  (`~/xaas/deps/a2a/lib/a2a/jsonrpc.ex:171`).

  This test drives that real dispatch function directly with a real JSON-RPC
  request map and a real handler
  (`AshA2A.Test.Fixture.JSONRPCHandler`, backed by a real, supervised
  `AshA2A.Test.Fixture.EchoAgent` `AshA2A.Protocol.Agent` GenServer) -- no
  Mock/mox/patch/monkeypatch anywhere. It asserts on the real returned
  response map's exact `-32003` error code/message/JSON shape, and separately
  proves the handler's `handle_send/3` is never invoked for these methods (a
  real call-count assertion backed by a real, plain Elixir `Agent` counter,
  not an interaction-based mock of a collaborator -- the counter itself is
  the thing under test, not a stand-in for one).
  """

  use ExUnit.Case, async: true

  alias AshA2A.Test.Fixture.EchoAgent
  alias AshA2A.Test.Fixture.JSONRPCHandler

  setup do
    {_sup, _registry} =
      AshA2A.Test.AgentSupervisorCase.start_supervised_agents!(__MODULE__, [EchoAgent])

    :ok
  end

  describe "tasks/pushNotificationConfig/* dispatch" do
    test "set returns the real -32003 push_notification_not_supported error shape" do
      request = %{
        "jsonrpc" => "2.0",
        "id" => "req-1",
        "method" => "tasks/pushNotificationConfig/set",
        "params" => %{"taskId" => "some-task", "pushNotificationConfig" => %{}}
      }

      assert {:reply, response} = AshA2A.Protocol.JSONRPC.handle(request, JSONRPCHandler, %{})

      assert response == %{
               "jsonrpc" => "2.0",
               "id" => "req-1",
               "error" => %{
                 "code" => -32_003,
                 "message" => "Push Notification is not supported",
                 "data" => [
                   %{
                     "@type" => "type.googleapis.com/google.rpc.ErrorInfo",
                     "domain" => "a2a-protocol.org",
                     "reason" => "PUSH_NOTIFICATION_NOT_SUPPORTED"
                   }
                 ]
               }
             }
    end

    test "get, list, and delete all return the same real error code/message" do
      for {method, params} <- [
            {"tasks/pushNotificationConfig/get", %{"id" => "cfg-1"}},
            {"tasks/pushNotificationConfig/list", %{"taskId" => "some-task"}},
            {"tasks/pushNotificationConfig/delete", %{"id" => "cfg-1"}}
          ] do
        request = %{"jsonrpc" => "2.0", "id" => method, "method" => method, "params" => params}

        assert {:reply, %{"error" => error}} =
                 AshA2A.Protocol.JSONRPC.handle(request, JSONRPCHandler, %{})

        assert error["code"] == -32_003
        assert error["message"] == "Push Notification is not supported"
      end
    end

    test "the real v0.3.0 PascalCase method alias resolves to the same real error" do
      request = %{
        "jsonrpc" => "2.0",
        "id" => "alias-req",
        "method" => "CreateTaskPushNotificationConfig",
        "params" => %{"taskId" => "some-task", "pushNotificationConfig" => %{}}
      }

      assert {:reply, response} = AshA2A.Protocol.JSONRPC.handle(request, JSONRPCHandler, %{})

      assert %{
               "jsonrpc" => "2.0",
               "id" => "alias-req",
               "error" => %{"code" => -32_003, "message" => "Push Notification is not supported"}
             } = response
    end

    test "the response round-trips through the real :a2a JSON error encoder unchanged" do
      request = %{
        "jsonrpc" => "2.0",
        "id" => 42,
        "method" => "tasks/pushNotificationConfig/set",
        "params" => %{"taskId" => "some-task", "pushNotificationConfig" => %{}}
      }

      assert {:reply, response} = AshA2A.Protocol.JSONRPC.handle(request, JSONRPCHandler, %{})

      assert {:ok, encoded_json} = Jason.encode(response)
      assert {:ok, decoded} = Jason.decode(encoded_json)
      assert decoded == response
    end

    test "the real handler's handle_send/3 is never invoked for a push-notification-config request" do
      {:ok, counter} = Agent.start_link(fn -> 0 end)

      Process.put(:push_notification_call_counter, counter)

      request = %{
        "jsonrpc" => "2.0",
        "id" => "canary",
        "method" => "tasks/pushNotificationConfig/set",
        "params" => %{"taskId" => "some-task", "pushNotificationConfig" => %{}}
      }

      assert {:reply, %{"error" => %{"code" => -32_003}}} =
               AshA2A.Protocol.JSONRPC.handle(request, JSONRPCHandler, %{})

      assert Agent.get(counter, & &1) == 0

      # Positive control: dispatch a real `message/send` through the *same*
      # handler and confirm the counter mechanism genuinely observes real
      # calls when they do happen -- proving the zero count above reflects
      # the push-notification dispatch clause skipping the handler, not a
      # broken counter that would silently read zero regardless.
      send_request = %{
        "jsonrpc" => "2.0",
        "id" => "control",
        "method" => "message/send",
        "params" => %{
          "message" => %{
            "role" => "ROLE_USER",
            "parts" => [%{"text" => "hi"}],
            "messageId" => "msg-1"
          }
        }
      }

      assert {:reply, %{"result" => _}} =
               AshA2A.Protocol.JSONRPC.handle(send_request, JSONRPCHandler, %{})

      assert Agent.get(counter, & &1) == 1

      Agent.stop(counter)
    end
  end
end

# --- SECTION 20: Original test/ash_a2a_rap_battle_integration_test.exs ---
# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshA2ARapBattleIntegrationTest do
  @moduledoc """
  Cross-app A2A integration test: three separately-`AshA2A`-extended Ash
  domains (50 Cent, Jadakiss, and a Judge Panel), each standing in for its
  own independently-deployable service, exchanging real `AshA2A.Protocol.Message`s
  through real `AshA2A.Protocol.Agent` GenServers under one real `AshA2A.Protocol.AgentSupervisor`.

  This is the first test in this suite proving `ash_a2a` works *across*
  separate Ash apps, not just within one process's dispatch table: every
  prior test dispatches directly against a single agent/resource. Here, the
  Judge Panel app never sees 50 Cent's or Jadakiss's real Ash resources or
  actions -- it only receives their verses as plain string arguments over a
  real A2A message, exactly as a genuinely separate remote service would.

  Chicago-style throughout: real `AshA2A.Protocol.Agent.call/2`, real supervised
  processes, real ETS-backed domains (implicitly -- these domains declare no
  resources, since their skills are pure generic actions), real deterministic
  judging logic. No Mock/mox/patch/monkeypatch.
  """

  use ExUnit.Case, async: true

  import AshA2A.Test.MessageHelpers

  alias AshA2A.Test.Fixture.RapBattle.{
    FiftyCentAgent,
    JadakissAgent,
    JudgePanelAgent
  }

  test "three independent Ash apps battle it out over real A2A dispatch, judged by a fourth" do
    {_sup, _registry_name} =
      AshA2A.Test.AgentSupervisorCase.start_supervised_agents!(__MODULE__, [
        FiftyCentAgent,
        JadakissAgent,
        JudgePanelAgent
      ])

    # Round 1: ask 50 Cent's app for a real verse, over real A2A dispatch.
    assert {:ok, fifty_task} = FiftyCentAgent.call(FiftyCentAgent, data_message(%{}))
    assert fifty_task.status.state == :completed

    assert [
             %AshA2A.Protocol.Artifact{
               parts: [%AshA2A.Protocol.Part.Data{data: %{result: fifty_verse}}]
             }
           ] =
             fifty_task.artifacts

    assert is_binary(fifty_verse)
    assert fifty_verse =~ "East Coast"

    # Round 2: ask Jadakiss's separate app for a real verse, same real path.
    assert {:ok, jada_task} = JadakissAgent.call(JadakissAgent, data_message(%{}))
    assert jada_task.status.state == :completed

    assert [
             %AshA2A.Protocol.Artifact{
               parts: [%AshA2A.Protocol.Part.Data{data: %{result: jada_verse}}]
             }
           ] =
             jada_task.artifacts

    assert is_binary(jada_verse)
    assert jada_verse =~ "LOX"

    # Round 3: hand BOTH real verses (received over real A2A dispatch from
    # the two contestant apps above -- not hand-authored by this test) to
    # the Judge Panel's separate app, over its own real A2A dispatch.
    judge_message =
      data_message(%{
        verse_a: fifty_verse,
        verse_b: jada_verse,
        contestant_a: "50 Cent",
        contestant_b: "Jadakiss"
      })

    assert {:ok, judge_task} = JudgePanelAgent.call(JudgePanelAgent, judge_message)
    assert judge_task.status.state == :completed

    assert [%AshA2A.Protocol.Artifact{parts: [%AshA2A.Protocol.Part.Data{data: verdict}]}] =
             judge_task.artifacts

    # Real, state-based assertions on the real verdict computed from the
    # real verses that actually crossed the real A2A boundary twice.
    assert %{votes: votes, winner: winner} = verdict
    assert Map.keys(votes) |> Enum.sort() == ["Eminem", "Kool Keith", "Snoop"]
    assert Enum.all?(Map.values(votes), &(&1 in [:a, :b]))
    assert winner in ["50 Cent", "Jadakiss", "tie"]

    # The verdict is a real function of the real verse text, not a fixed
    # literal -- confirm it reproduces deterministically given the same
    # real inputs (same judges, same real word/vowel/length computations).
    assert {:ok, judge_task_again} = JudgePanelAgent.call(JudgePanelAgent, judge_message)

    assert [%AshA2A.Protocol.Artifact{parts: [%AshA2A.Protocol.Part.Data{data: verdict_again}]}] =
             judge_task_again.artifacts

    assert verdict_again == verdict
  end
end

# --- SECTION 21: Original test/ash_a2a_receipt_r_projection_test.exs ---
# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshA2A.ReceiptRProjectionTest do
  @moduledoc """
  `AshA2A.Receipt.RProjection` audited against REAL receipts only.

  Every receipt projected here was produced by the real `AshA2A.CommandBus`
  dispatching into real fixture Ash resources over real stores (an on-disk
  `AshA2A.ReceiptStore.Ekv` for the durable path, `AshA2A.ReceiptStore.Memory`
  for the dishonesty guard), or by the real `AshA2A.Receipt` production
  constructors (`from_reply/5`, `pending/4`, `finalize/2`, `reconcile/2`,
  `compensate/2`, `mark_unknown_outcome/2`). No doubles anywhere in this
  file, per the Chicago-style testing discipline.
  """

  use ExUnit.Case, async: false

  @moduletag :serial
  @moduletag :serial_shard

  import AshA2A.Test.MessageHelpers

  alias AshA2A.{Authority, Command, CommandBus, Identity, Receipt, SemanticSubject}
  alias AshA2A.Identity.Canonical
  alias AshA2A.Receipt.RProjection
  alias AshA2A.ReceiptStore.{Ekv, Memory}
  alias AshA2A.Test.Fixture.{Crashy, Echo, Item}

  # Caller-supplied git anchors, pattern-validated only: the projector runs
  # no git, so these are plain constants the caller (this test) asserts are
  # the verified clean-tree HEAD of the anchor repo.
  @repo "/Users/sac/ash_a2a"
  @subject_sha String.duplicate("a", 40)
  @base_sha String.duplicate("b", 40)

  setup do
    Application.put_env(:ash_a2a, :receipt_commit_retry_delays_ms, [1, 1])
    on_exit(fn -> Application.delete_env(:ash_a2a, :receipt_commit_retry_delays_ms) end)
    :ok
  end

  # ---------------------------------------------------------------------
  # Real collaborators
  # ---------------------------------------------------------------------

  defp start_ekv_store! do
    ekv_name = :"r_projection_ekv_#{System.unique_integer([:positive])}"

    data_dir =
      Path.join(File.cwd!(), "tmp_r_projection_ekv_#{System.unique_integer([:positive])}")

    on_exit(fn -> File.rm_rf!(data_dir) end)

    # A real, on-disk EKV instance (the `:ekv` hex library's GenServer), the
    # exact same real-local-EKV pattern as
    # `test/ash_a2a/receipt_store_ekv_test.exs:36` -- `AshA2A.ReceiptStore.Ekv`
    # is a behaviour module over it, keyed by this name.
    start_supervised!({EKV, name: ekv_name, data_dir: data_dir, cluster_size: 1})
    [name: ekv_name]
  end

  defp start_memory_store! do
    name = Module.concat(__MODULE__, "Store#{System.unique_integer([:positive])}")
    start_supervised!({Memory, name: name})
    [name: name]
  end

  defp digest(seed),
    do: "sha256:" <> (seed |> then(&:crypto.hash(:sha256, &1)) |> Base.encode16(case: :lower))

  defp anchors(extra \\ []) do
    Keyword.merge(
      [repo: @repo, subject_sha: @subject_sha, base_sha: @base_sha],
      extra
    )
  end

  defp observe_command(command_id) do
    Command.new("AshA2A.Test.Fixture.Echo.read",
      command_id: command_id,
      agent_id: "agent-rproj",
      principal_id: "anonymous",
      input: %{}
    )
  end

  defp change_command(command_id, extra \\ []) do
    principal = Identity.principal("subject-rproj")
    capability = "AshA2A.Test.Fixture.Item.create"

    authority =
      Authority.new(principal, capability,
        token_id: "auth-#{command_id}",
        constraints: %{external_idempotency_token: "idem-#{command_id}"}
      )

    {:ok, subject} =
      SemanticSubject.new(
        graph_digest: digest("graph-rproj"),
        projection_digest: digest("projection-rproj"),
        manufacturer_digest: digest("manufacturer-rproj")
      )

    Command.new(capability,
      command_id: command_id,
      agent_id: "agent-rproj",
      principal_id: principal,
      authority: authority,
      semantic_subject: subject,
      input: %{label: "widget-#{command_id}"},
      metadata: Keyword.get(extra, :metadata, %{})
    )
  end

  # ---------------------------------------------------------------------
  # ALIVE over a real durable store
  # ---------------------------------------------------------------------

  describe "ALIVE over a real durable EKV store" do
    test "a real CommandBus run over real on-disk EKV projects ALIVE with exit 0" do
      store_opts = start_ekv_store!()

      assert {:ok, receipt} =
               CommandBus.run(
                 change_command("rproj-alive-1"),
                 data_message(%{"label" => "widget-rproj-alive-1"}),
                 Item,
                 store: Ekv,
                 store_opts: store_opts,
                 plan_digest: digest("plan-rproj")
               )

      assert receipt.terminal_status == :executed
      assert receipt.standing == :durable

      assert {:ok, r} = RProjection.project(receipt, anchors(work_order_id: "WO-RPROJ-1"))

      # Standing: ALIVE, monotone in the evidence, no broken term.
      assert r["standing"]["value"] == "ALIVE"
      refute Map.has_key?(r["standing"], "broken_term")
      assert r["standing"]["derived_from"] =~ "AshA2A.Test.Fixture.Item.create"
      assert r["standing"]["derived_from"] =~ @subject_sha

      # The exit gate and the one replay command.
      assert r["replay"]["commands"] == [
               %{"cmd" => "AshA2A.Test.Fixture.Item.create", "cwd" => @repo, "exit" => 0}
             ]

      assert r["replay"]["durable_location"] ==
               "ash_a2a:receipt:" <> Identity.external(receipt.receipt_id)

      # Identity: caller-supplied anchors echoed, receipt-carried digests projected.
      assert r["identity"]["subject"] == "WO-RPROJ-1"
      assert r["identity"]["repo"] == @repo
      assert r["identity"]["subject_sha"] == @subject_sha
      assert r["identity"]["base_sha"] == @base_sha
      assert r["identity"]["graph_hash"] == receipt.semantic_subject.graph_digest

      assert r["identity"]["subject_digest"] == %{
               "algorithm" => "sha256",
               "value" => String.slice(receipt.input_digest, -64, 64)
             }

      # Authority: the receipt's own grant; the ceiling is the fixed map.
      assert r["authority"]["ceiling"] == "CONSTRUCT"
      assert r["authority"]["grant"] == "runtime:auth-rproj-alive-1"
      assert r["origin_authority"] == r["authority"]

      assert r["provider"] == %{
               "name" => "ash_a2a",
               "authority_ceiling" => "CONSTRUCT",
               "receipt_protocol" => "RFC-SA2A-001 S31"
             }

      assert r["provider_execution_id"] == Identity.external(receipt.execution_id)

      # Consequence: a receipt never claims commits; nothing changed on disk.
      assert r["consequence"]["commits"] == []
      assert r["consequence"]["files_changed"] == []
      assert r["consequence"]["remote_effects"] == []

      # Replay binding: real actuation + command identities and the real head link.
      assert r["replay_binding"]["event_ids"] == [
               Identity.external(receipt.actuation_id),
               Identity.external(receipt.command_id)
             ]

      assert r["replay_binding"]["chain_head_hash"] ==
               List.last(receipt.binding.links).digest

      # The sealed self-digest recomputes exactly.
      ext = r["provider_ext.ash_a2a"]
      assert ext["self_digest"] =~ ~r/\Asha256:[0-9a-f]{64}\z/
      assert ext["input_digest"] == receipt.input_digest
      assert ext["plan_digest"] == digest("plan-rproj")

      without_self =
        Map.put(
          Map.delete(r, "provider_ext.ash_a2a"),
          "provider_ext.ash_a2a",
          Map.delete(ext, "self_digest")
        )

      assert {:ok, recomputed} = Canonical.digest(without_self)
      assert recomputed == ext["self_digest"]

      # subject_before/subject_after are OMITTED, never fabricated.
      refute Map.has_key?(r, "subject_before")
      refute Map.has_key?(r, "subject_after")
    end

    test "the dishonesty guard: the same command over Memory refuses rather than claiming durability" do
      store_opts = start_memory_store!()

      assert {:ok, receipt} =
               CommandBus.run(
                 change_command("rproj-dishonest-1"),
                 data_message(%{"label" => "widget-rproj-dishonest-1"}),
                 Item,
                 store_opts: store_opts,
                 plan_digest: digest("plan-rproj")
               )

      # The real Memory store never upgrades standing (an in-process Map is
      # lost on restart), so the executed receipt honestly refuses to project.
      assert receipt.terminal_status == :executed
      assert receipt.standing == :observed

      assert {:error, %{code: :r_projection_standing_not_durable}} =
               RProjection.project(receipt, anchors(work_order_id: "WO-RPROJ-2"))
    end

    test "an :observed reconciled receipt refuses exactly like an :observed executed one" do
      store_opts = start_memory_store!()

      assert {:ok, executed} =
               CommandBus.run(observe_command("rproj-reconcile-obs-1"), data_message(%{}), Echo,
                 store_opts: store_opts
               )

      reconciled = Receipt.reconcile(executed, %{source: :test})

      assert {:error, %{code: :r_projection_standing_not_durable}} =
               RProjection.project(reconciled, anchors(work_order_id: "WO-RPROJ-3"))
    end
  end

  # ---------------------------------------------------------------------
  # Ceiling map (no caller override)
  # ---------------------------------------------------------------------

  describe "ceiling map" do
    test "real Echo.read projects OBSERVE, real Item.create projects CONSTRUCT" do
      store_opts = start_ekv_store!()

      assert {:ok, echo_receipt} =
               CommandBus.run(observe_command("rproj-ceil-observe"), data_message(%{}), Echo,
                 store: Ekv,
                 store_opts: store_opts
               )

      assert {:ok, r} = RProjection.project(echo_receipt, anchors(work_order_id: "WO-CEIL-1"))
      assert r["authority"]["ceiling"] == "OBSERVE"
      assert r["provider"]["authority_ceiling"] == "OBSERVE"
      assert r["consequence"]["remote_effects"] == []

      assert r["replay"]["commands"] == [
               %{"cmd" => "AshA2A.Test.Fixture.Echo.read", "cwd" => @repo, "exit" => 0}
             ]

      # No semantic subject was bound to the observe command, so no graph hash
      # is fabricated and no subject digest rides on a missing input digest.
      refute Map.has_key?(r["identity"], "graph_hash")

      assert {:ok, item_receipt} =
               CommandBus.run(
                 change_command("rproj-ceil-construct"),
                 data_message(%{"label" => "widget-rproj-ceil-construct"}),
                 Item,
                 store: Ekv,
                 store_opts: store_opts
               )

      assert {:ok, r} = RProjection.project(item_receipt, anchors(work_order_id: "WO-CEIL-2"))
      assert r["authority"]["ceiling"] == "CONSTRUCT"
      assert r["consequence"]["remote_effects"] == []
      assert r["standing"]["value"] == "ALIVE"
    end

    test "external DO via the real production constructors projects the DO ceiling" do
      start_ekv_store!()

      # The durable standing below mirrors `AshA2A.CommandBus.mark_standing/2`
      # exactly -- a plain struct update gated on the store's real
      # `durable?/0` -- because what is under test here is the ceiling map,
      # not the durability machinery (that is the ALIVE test above, which
      # proves it end to end through real `CommandBus.run/4`).
      assert Ekv.durable?()

      command = change_command("rproj-ceil-do")
      execution_id = Identity.execution("rproj-ceil-do-exec")

      receipt =
        command
        |> Receipt.pending(execution_id, :external_do, [])
        |> Receipt.finalize({:reply, %{"ok" => true}})
        |> then(fn receipt -> %{receipt | standing: :durable} end)

      assert receipt.terminal_status == :executed

      assert {:ok, r} = RProjection.project(receipt, anchors(work_order_id: "WO-CEIL-3"))

      assert r["authority"]["ceiling"] == "DO"
      assert r["provider"]["authority_ceiling"] == "DO"
      assert r["consequence"]["remote_effects"] == [command.capability_id]
      assert r["standing"]["value"] == "ALIVE"

      assert r["replay"]["commands"] == [
               %{"cmd" => "AshA2A.Test.Fixture.Item.create", "cwd" => @repo, "exit" => 0}
             ]
    end

    test "an :unknown consequence refuses instead of guessing a ceiling" do
      start_memory_store!()

      receipt =
        Receipt.from_reply(
          observe_command("rproj-ceil-unknown"),
          Identity.execution("rproj-ceil-unknown-exec"),
          :unknown,
          {:reply, "mystery"}
        )

      assert {:error, %{code: :r_projection_consequence_unknown, detail: %{observed: :unknown}}} =
               RProjection.project(receipt, anchors(work_order_id: "WO-CEIL-4"))
    end
  end

  # ---------------------------------------------------------------------
  # Standing table
  # ---------------------------------------------------------------------

  describe "standing table" do
    test "a real pre-DO refusal projects REFUSED(<code>) with the mapped broken term" do
      receipt =
        Receipt.from_reply(
          change_command("rproj-refused-1"),
          Identity.execution("rproj-refused-1-exec"),
          :change,
          {:error, %{code: :authority_required}}
        )

      assert receipt.terminal_status == :refused

      assert {:ok, r} = RProjection.project(receipt, anchors(work_order_id: "WO-REFUSED-1"))

      assert r["standing"]["value"] == "REFUSED(authority_required)"
      assert r["standing"]["broken_term"] == "R_missing_authority"

      assert r["replay"]["commands"] == [
               %{"cmd" => "AshA2A.Test.Fixture.Item.create", "cwd" => @repo, "exit" => 1}
             ]

      refute Map.has_key?(r["replay"], "durable_location")

      # Refused before DO: nothing remote is claimed either way.
      assert r["consequence"]["remote_effects"] == []
    end

    test "the remaining pre-DO refusal broken-term map holds: kill switch and admission vacuity" do
      kill_switch =
        Receipt.from_reply(
          change_command("rproj-refused-kill"),
          Identity.execution("rproj-refused-kill-exec"),
          :change,
          {:error, %{code: :kill_switch_tripped}}
        )

      assert {:ok, r} = RProjection.project(kill_switch, anchors(work_order_id: "WO-REFUSED-2"))
      assert r["standing"]["value"] == "REFUSED(kill_switch_tripped)"
      assert r["standing"]["broken_term"] == "mu_unlawful"

      conflict =
        Receipt.from_reply(
          change_command("rproj-refused-conflict"),
          Identity.execution("rproj-refused-conflict-exec"),
          :change,
          {:error, %{code: :command_conflict}}
        )

      assert {:ok, r} = RProjection.project(conflict, anchors(work_order_id: "WO-REFUSED-3"))
      assert r["standing"]["value"] == "REFUSED(command_conflict)"
      assert r["standing"]["broken_term"] == "admission_vacuous"
    end

    test "a real dispatch crash projects BUILD_BROKEN with R_missing_consequence" do
      store_opts = start_memory_store!()

      command =
        Command.new("AshA2A.Test.Fixture.Crashy.detonate",
          command_id: "rproj-crashy-1",
          agent_id: "agent-rproj",
          principal_id: "anonymous",
          input: %{}
        )

      assert {:ok, receipt} =
               CommandBus.run(command, data_message(%{}), Crashy, store_opts: store_opts)

      assert receipt.terminal_status == :failed
      assert {:error, %{code: :dispatch_crashed}} = receipt.reply

      assert {:ok, r} = RProjection.project(receipt, anchors(work_order_id: "WO-CRASHY-1"))

      assert r["standing"]["value"] == "BUILD_BROKEN"
      assert r["standing"]["broken_term"] == "R_missing_consequence"

      assert r["replay"]["commands"] == [
               %{"cmd" => "AshA2A.Test.Fixture.Crashy.detonate", "cwd" => @repo, "exit" => 1}
             ]
    end

    test "a really compensated actuation projects PARTIAL_ALIVE with no broken term" do
      store_opts = start_memory_store!()

      assert {:ok, executed} =
               CommandBus.run(observe_command("rproj-compensated-1"), data_message(%{}), Echo,
                 store_opts: store_opts
               )

      compensated = Receipt.compensate(executed, %{reversal_receipt_id: "runtime:rev-rproj-1"})

      assert compensated.terminal_status == :compensated

      assert {:ok, r} =
               RProjection.project(compensated, anchors(work_order_id: "WO-COMPENSATED-1"))

      assert r["standing"]["value"] == "PARTIAL_ALIVE"
      refute Map.has_key?(r["standing"], "broken_term")

      assert r["replay"]["commands"] == [
               %{"cmd" => "AshA2A.Test.Fixture.Echo.read", "cwd" => @repo, "exit" => 1}
             ]
    end

    test "unknown outcome and pending project UNKNOWN" do
      store_opts = start_memory_store!()

      assert {:ok, executed} =
               CommandBus.run(observe_command("rproj-unknown-1"), data_message(%{}), Echo,
                 store_opts: store_opts
               )

      unknown = Receipt.mark_unknown_outcome(executed, :post_do_crash_window)

      assert {:ok, r} = RProjection.project(unknown, anchors(work_order_id: "WO-UNKNOWN-1"))
      assert r["standing"]["value"] == "UNKNOWN"
      refute Map.has_key?(r["standing"], "broken_term")

      pending =
        Receipt.pending(
          change_command("rproj-pending-1"),
          Identity.execution("rproj-pending-1-exec"),
          :change
        )

      assert pending.terminal_status == nil

      assert {:ok, r} = RProjection.project(pending, anchors(work_order_id: "WO-PENDING-1"))
      assert r["standing"]["value"] == "UNKNOWN"

      assert r["replay"]["commands"] == [
               %{"cmd" => "AshA2A.Test.Fixture.Item.create", "cwd" => @repo, "exit" => 1}
             ]
    end

    test "a reconciled durable outcome projects ALIVE with exit 0" do
      store_opts = start_ekv_store!()

      assert {:ok, executed} =
               CommandBus.run(observe_command("rproj-reconciled-1"), data_message(%{}), Echo,
                 store: Ekv,
                 store_opts: store_opts
               )

      reconciled = Receipt.reconcile(executed, %{source: :test})
      assert reconciled.terminal_status == :reconciled
      assert reconciled.standing == :durable

      assert {:ok, r} = RProjection.project(reconciled, anchors(work_order_id: "WO-RECONCILED-1"))

      assert r["standing"]["value"] == "ALIVE"

      assert r["replay"]["commands"] == [
               %{"cmd" => "AshA2A.Test.Fixture.Echo.read", "cwd" => @repo, "exit" => 0}
             ]

      assert r["replay_binding"]["chain_head_hash"] ==
               List.last(reconciled.binding.links).digest
    end
  end

  # ---------------------------------------------------------------------
  # Fail-closed preconditions
  # ---------------------------------------------------------------------

  describe "anchors fail closed" do
    test "missing anchors refuse :r_projection_anchor_missing" do
      receipt = refused_receipt("rproj-anchor-missing")

      assert {:error, %{code: :r_projection_anchor_missing}} = RProjection.project(receipt, [])

      assert {:error, %{code: :r_projection_anchor_missing, detail: %{field: :base_sha}}} =
               RProjection.project(receipt, repo: @repo, subject_sha: @subject_sha)

      assert {:error, %{code: :r_projection_anchor_missing, detail: %{field: :subject_sha}}} =
               RProjection.project(receipt, repo: @repo)
    end

    test "malformed anchors refuse :r_projection_anchor_malformed" do
      receipt = refused_receipt("rproj-anchor-malformed")

      assert {:error, %{code: :r_projection_anchor_malformed, detail: %{field: :subject_sha}}} =
               RProjection.project(receipt, anchors(subject_sha: String.duplicate("a", 39)))

      assert {:error, %{code: :r_projection_anchor_malformed, detail: %{field: :subject_sha}}} =
               RProjection.project(
                 receipt,
                 anchors(subject_sha: String.upcase(String.duplicate("a", 40)))
               )

      assert {:error, %{code: :r_projection_anchor_malformed, detail: %{field: :subject_sha}}} =
               RProjection.project(
                 receipt,
                 anchors(subject_sha: "sha256:" <> String.duplicate("a", 40))
               )

      assert {:error, %{code: :r_projection_anchor_malformed, detail: %{field: :base_sha}}} =
               RProjection.project(receipt, anchors(base_sha: String.duplicate("c", 39)))

      # An empty string is an absent anchor, not a present-but-malformed one.
      assert {:error,
              %{code: :r_projection_anchor_missing, detail: %{field: :repo, observed: ""}}} =
               RProjection.project(receipt, anchors(repo: ""))
    end
  end

  describe "receipt shape and binding fail closed" do
    test "a non-receipt refuses :r_projection_receipt_required" do
      assert {:error, %{code: :r_projection_receipt_required}} =
               RProjection.project(%{}, anchors(work_order_id: "WO-NONE"))
    end

    test "a tampered receipt refuses :r_projection_binding_unverified" do
      store_opts = start_memory_store!()

      assert {:ok, executed} =
               CommandBus.run(observe_command("rproj-tamper-1"), data_message(%{}), Echo,
                 store_opts: store_opts
               )

      tampered = %{executed | input_digest: digest("tampered")}

      assert {:error,
              %{
                code: :r_projection_binding_unverified,
                detail: %{refused: :receipt_binding_field_mismatch}
              }} =
               RProjection.project(tampered, anchors(work_order_id: "WO-TAMPER-1"))
    end
  end

  describe "work-order id resolution" do
    test "metadata.work_order_digest wins over the opts fallback" do
      store_opts = start_ekv_store!()

      command = change_command("rproj-wo-meta", metadata: %{work_order_digest: "wo-meta-1"})

      assert {:ok, receipt} =
               CommandBus.run(
                 command,
                 data_message(%{"label" => "widget-rproj-wo-meta"}),
                 Item,
                 store: Ekv,
                 store_opts: store_opts
               )

      assert receipt.metadata.work_order_digest == "wo-meta-1"

      assert {:ok, r} =
               RProjection.project(
                 receipt,
                 anchors(work_order_id: "WO-OPT-FALLBACK")
               )

      assert r["work_order_id"] == "wo-meta-1"
      assert r["identity"]["subject"] == "wo-meta-1"
    end

    test "with no metadata and no opt, the projection refuses" do
      store_opts = start_ekv_store!()

      assert {:ok, receipt} =
               CommandBus.run(observe_command("rproj-wo-none"), data_message(%{}), Echo,
                 store: Ekv,
                 store_opts: store_opts
               )

      assert {:error, %{code: :r_projection_work_order_unavailable}} =
               RProjection.project(receipt, anchors())
    end
  end

  # ---------------------------------------------------------------------
  # Determinism and totality
  # ---------------------------------------------------------------------

  describe "determinism and the exit gate" do
    test "the same receipt projects byte-identical JSON twice" do
      store_opts = start_ekv_store!()

      assert {:ok, receipt} =
               CommandBus.run(
                 change_command("rproj-determinism-1"),
                 data_message(%{"label" => "widget-rproj-determinism-1"}),
                 Item,
                 store: Ekv,
                 store_opts: store_opts
               )

      opts = anchors(work_order_id: "WO-DET-1", transport: "jsonrpc")

      assert {:ok, r1} = RProjection.project(receipt, opts)
      assert {:ok, r2} = RProjection.project(receipt, opts)

      assert JSON.encode!(r1) == JSON.encode!(r2)

      # The transport opt rides through provider.
      assert r1["provider"]["transport"] == "jsonrpc"
    end

    test "exit == 0 iff ALIVE, and commits are always [], over every projectable terminal shape" do
      ekv = start_ekv_store!()
      memory = start_memory_store!()

      assert {:ok, alive} =
               CommandBus.run(observe_command("rproj-totality-alive"), data_message(%{}), Echo,
                 store: Ekv,
                 store_opts: ekv
               )

      reconciled = Receipt.reconcile(alive, %{source: :test})

      refused =
        Receipt.from_reply(
          change_command("rproj-totality-refused"),
          Identity.execution("rproj-totality-refused-exec"),
          :change,
          {:error, %{code: :authority_required}}
        )

      assert {:ok, crashy} =
               CommandBus.run(
                 Command.new("AshA2A.Test.Fixture.Crashy.detonate",
                   command_id: "rproj-totality-crashy",
                   agent_id: "agent-rproj",
                   principal_id: "anonymous",
                   input: %{}
                 ),
                 data_message(%{}),
                 Crashy,
                 store_opts: memory
               )

      assert {:ok, observed} =
               CommandBus.run(observe_command("rproj-totality-observed"), data_message(%{}), Echo,
                 store_opts: memory
               )

      cases = [
        alive,
        reconciled,
        refused,
        crashy,
        Receipt.compensate(observed, %{reversal_receipt_id: "runtime:rev-t"}),
        Receipt.mark_unknown_outcome(observed, :post_do_crash_window),
        Receipt.pending(
          change_command("rproj-totality-pending"),
          Identity.execution("rproj-totality-pending-exec"),
          :change
        )
      ]

      projections =
        Enum.map(cases, fn receipt ->
          assert {:ok, r} = RProjection.project(receipt, anchors(work_order_id: "WO-TOTALITY"))
          r
        end)

      for r <- projections do
        # Totality: the exit gate is exactly the ALIVE gate.
        assert [%{"exit" => exit}] = r["replay"]["commands"]
        assert exit == 0 == (r["standing"]["value"] == "ALIVE")

        # ...and never a commit a receipt did not make.
        assert r["consequence"]["commits"] == []
        assert length(r["replay"]["commands"]) == 1
      end

      assert hd(projections)["standing"]["value"] == "ALIVE"
      assert Enum.at(projections, 1)["standing"]["value"] == "ALIVE"
      assert Enum.at(projections, 2)["standing"]["value"] == "REFUSED(authority_required)"
      assert Enum.at(projections, 3)["standing"]["value"] == "BUILD_BROKEN"
      assert Enum.at(projections, 4)["standing"]["value"] == "PARTIAL_ALIVE"
      assert Enum.at(projections, 5)["standing"]["value"] == "UNKNOWN"
      assert Enum.at(projections, 6)["standing"]["value"] == "UNKNOWN"
    end
  end

  # ---------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------

  defp refused_receipt(command_id) do
    Receipt.from_reply(
      change_command(command_id),
      Identity.execution("#{command_id}-exec"),
      :change,
      {:error, %{code: :authority_required}}
    )
  end
end

# --- SECTION 22: Original test/ash_a2a_receipt_replay_counting_actuator_test.exs ---
# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshA2A.ReceiptReplayCountingActuatorTest do
  @moduledoc """
  RFC-SA2A-001 S32: a receipt must reconstruct the semantic basis of an
  execution, and replaying it MUST NOT repeat the external consequence.

  > "Replaying evidence is not authority to re-actuate."

  Proven with a REAL counting actuator: `AshA2A.Test.Fixture.CountingActuator`
  is a real `Ash.Resource` whose `:external_do` action increments a real
  `Agent`-held integer. Every assertion below reads that real integer. If
  replay ever crossed the consequence boundary, the count would move -- there
  is no mock to make it look like it didn't.
  """
  use ExUnit.Case

  import AshA2A.Test.MessageHelpers

  alias AshA2A.{Authority, Command, CommandBus, Identity, Receipt, SemanticSubject}
  alias AshA2A.Receipt.Replay
  alias AshA2A.Test.Fixture.{KeyedActuationCounter, CountingActuator}

  @capability "AshA2A.Test.Fixture.CountingActuator.actuate"

  setup do
    Application.put_env(:ash_a2a, :receipt_commit_retry_delays_ms, [1, 1])
    on_exit(fn -> Application.delete_env(:ash_a2a, :receipt_commit_retry_delays_ms) end)

    # The fixture resource increments the counter registered under the
    # default name, so start the real Agent there. Isolation between tests
    # comes from a unique effect key per test, not from a per-test process --
    # the counter is keyed, so one shared Agent is genuinely sufficient and
    # keeps the fixture's own call site honest (no injected process name).
    start_supervised!(KeyedActuationCounter)

    store = Module.concat(__MODULE__, "Store#{System.unique_integer([:positive])}")
    start_supervised!({AshA2A.ReceiptStore.Memory, name: store})

    %{store_opts: [name: store]}
  end

  defp actuate(command_id, effect_key, store_opts) do
    principal = Identity.principal("replay-principal")
    authority = Authority.new(principal, @capability, token_id: "replay-auth")

    command =
      Command.new(@capability,
        command_id: command_id,
        agent_id: "replay-agent",
        principal_id: principal,
        authority: authority,
        input: %{effect_key: effect_key}
      )

    {command,
     CommandBus.run(command, data_message(%{"effect_key" => effect_key}), CountingActuator,
       store_opts: store_opts
     )}
  end

  test "a real external_do executes exactly once, and replaying its receipt never re-actuates", %{
    store_opts: store_opts
  } do
    effect_key = "effect-#{System.unique_integer([:positive])}"

    assert KeyedActuationCounter.count(effect_key) == 0

    {_command, {:ok, receipt}} = actuate("replay-1", effect_key, store_opts)

    assert receipt.terminal_status == :executed
    assert receipt.consequence == :external_do
    real_count_after_execution = KeyedActuationCounter.count(effect_key)
    assert real_count_after_execution == 1

    # Replay the receipt 25 times. This is the whole claim: 25 replays, zero
    # additional crossings of the consequence boundary.
    for _ <- 1..25 do
      assert {:ok, %Replay.Basis{} = basis} = Replay.basis(receipt)
      assert basis.actuated? == false
    end

    assert KeyedActuationCounter.count(effect_key) == real_count_after_execution
    assert KeyedActuationCounter.count(effect_key) == 1
  end

  test "the basis reconstructs admission, plan selection, construction, authorization and intended effect",
       %{store_opts: store_opts} do
    principal = Identity.principal("basis-principal")
    authority = Authority.new(principal, @capability, token_id: "basis-auth")

    {:ok, subject} =
      SemanticSubject.new(
        graph_digest: sha("graph"),
        projection_digest: sha("projection"),
        manufacturer_digest: sha("manufacturer")
      )

    effect_key = "effect-basis-#{System.unique_integer([:positive])}"

    command =
      Command.new(@capability,
        command_id: "replay-basis-1",
        agent_id: "basis-agent",
        principal_id: principal,
        authority: authority,
        semantic_subject: subject,
        input: %{effect_key: effect_key}
      )

    assert {:ok, receipt} =
             CommandBus.run(
               command,
               data_message(%{"effect_key" => effect_key}),
               CountingActuator,
               store_opts: store_opts,
               plan_digest: sha("plan")
             )

    assert {:ok, basis} = Replay.basis(receipt)

    # admission
    assert basis.admission.consequence == :external_do
    assert basis.admission.terminal_status == :executed
    assert basis.admission.fingerprint == command.fingerprint

    # plan selection
    assert basis.plan_selection == %{plan_digest: sha("plan"), marker: :plan_recorded}

    # construction
    assert basis.construction.graph_digest == sha("graph")
    assert basis.construction.projection_digest == sha("projection")
    assert basis.construction.manufacturer_digest == sha("manufacturer")

    # authorization decision
    assert %Replay.AuthorityRecord{decision: :admitted, capability_id: @capability} =
             basis.authorization

    # intended effect
    assert basis.intended_effect.capability_id == @capability
    assert basis.intended_effect.actuation_id == Identity.external(receipt.actuation_id)

    assert String.starts_with?(basis.basis_digest, "sha256:")
  end

  test "an unplanned command records no_plan_recorded rather than a fabricated plan digest", %{
    store_opts: store_opts
  } do
    effect_key = "effect-noplan-#{System.unique_integer([:positive])}"
    {_command, {:ok, receipt}} = actuate("replay-noplan", effect_key, store_opts)

    assert {:ok, basis} = Replay.basis(receipt)
    assert basis.plan_selection == %{plan_digest: nil, marker: :no_plan_recorded}
    assert basis.construction.marker == :no_semantic_subject_recorded
  end

  test "the replayed authority record is a different type and CANNOT admit a fresh command", %{
    store_opts: store_opts
  } do
    effect_key = "effect-authz-#{System.unique_integer([:positive])}"
    {_command, {:ok, receipt}} = actuate("replay-authz", effect_key, store_opts)
    assert KeyedActuationCounter.count(effect_key) == 1

    assert {:ok, basis} = Replay.basis(receipt)
    record = basis.authorization

    # Structurally a different type from AshA2A.Authority.
    assert %Replay.AuthorityRecord{} = record
    refute match?(%Authority{}, record)

    # The real admission predicate refuses it. This is the structural
    # enforcement: nothing in the replayed evidence is an authority.
    refute Authority.admits?(record, %{
             principal_id: Identity.principal("replay-principal"),
             capability_id: @capability
           })

    # And driving the REAL bus with it refuses before DO -- the counter does
    # not move, which is what "replaying evidence is not authority to
    # re-actuate" means operationally.
    forged =
      Command.new(@capability,
        command_id: "replay-authz-forged",
        agent_id: "replay-agent",
        principal_id: Identity.principal("replay-principal"),
        authority: record,
        input: %{effect_key: effect_key}
      )

    assert {:error, %{code: :authority_required}} =
             CommandBus.run(forged, data_message(%{"effect_key" => effect_key}), CountingActuator,
               store_opts: store_opts
             )

    assert KeyedActuationCounter.count(effect_key) == 1
  end

  test "a receipt lacking replay identity refuses rather than reconstructing a plausible basis" do
    thin = %Receipt{
      receipt_id: Identity.runtime("r-thin"),
      command_id: Identity.command("c-thin"),
      execution_id: Identity.execution("e-thin"),
      agent_id: Identity.agent("a-thin"),
      principal_id: Identity.principal("p-thin"),
      capability_id: @capability,
      fingerprint: "deadbeef",
      consequence: :external_do,
      status: :completed,
      standing: :observed,
      recorded_at: DateTime.utc_now()
    }

    assert {:error, %{code: :insufficient_replay_identity, detail: detail}} = Replay.basis(thin)
    assert detail =~ "actuation_id"
    assert detail =~ "idempotency_key"
    assert detail =~ "input_digest"
  end

  test "two receipts for the same semantic execution share a basis digest; a different input does not",
       %{store_opts: store_opts} do
    key_a = "effect-same-#{System.unique_integer([:positive])}"
    key_b = "effect-diff-#{System.unique_integer([:positive])}"

    {_c1, {:ok, first}} = actuate("basis-cmp-1", key_a, store_opts)

    # A genuine replay through the real bus returns the same receipt identity.
    {_c1b, {:ok, replayed}} = actuate("basis-cmp-1", key_a, store_opts)
    assert replayed.replayed?
    assert Replay.same_basis?(first, replayed)
    assert KeyedActuationCounter.count(key_a) == 1

    {_c2, {:ok, other}} = actuate("basis-cmp-2", key_b, store_opts)
    refute Replay.same_basis?(first, other)
  end

  test "basis_set replays a receipt set in logical clock order and refuses a partial set", %{
    store_opts: store_opts
  } do
    {_c1, {:ok, one}} = actuate("set-1", "effect-set-a#{System.unique_integer()}", store_opts)
    {_c2, {:ok, two}} = actuate("set-2", "effect-set-b#{System.unique_integer()}", store_opts)

    assert {:ok, [first, second]} = Replay.basis_set([two, one])
    assert first.receipt_id == Identity.external(one.receipt_id)
    assert second.receipt_id == Identity.external(two.receipt_id)

    thin = %{one | actuation_id: nil}
    assert {:error, %{code: :insufficient_replay_identity}} = Replay.basis_set([one, thin, two])
  end

  defp sha(seed),
    do: "sha256:" <> (seed |> then(&:crypto.hash(:sha256, &1)) |> Base.encode16(case: :lower))
end
