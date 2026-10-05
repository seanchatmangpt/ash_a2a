# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshA2A.Enterprise.SupervisorCourtTest do
  @moduledoc """
  Courts for `AshA2A.Enterprise.Supervisor` (ARD v26.10.4 §2 wiring):

    1. empty config -> `:ignore`, no enterprise process (dev/test boots
       unchanged, default-off for every enterprise child);
    2. all keys -> every startable child really running, the unavailable
       ones typed-skipped (never silent);
    3. partial config -> exactly that key's children, nothing else;
    4. drain enabled -> the real `AshA2A.Cluster.DrainManager` traps the
       `:sigterm` message (the exact message `:os.set_signal(:sigterm,
       :handle)` delivers for the OS signal) and two-phase-drains a real
       tracked task.

  Zero mocks: every child in these courts is the real GenServer, driven
  over real sockets/paths (a real UNIX-domain listener for the SPIFFE
  watcher, a real tracked task under the real `AshA2A.TaskSupervisor`).
  """

  use ExUnit.Case, async: false

  alias AshA2A.Cluster.DrainManager
  alias AshA2A.Enterprise.Supervisor
  alias AshA2A.SPIFFE.WorkloadWatcher

  # `alias AshA2A.Enterprise.Supervisor` shadows Elixir's `Supervisor` in
  # this module, so the OTP supervisor introspection calls are named
  # explicitly.
  alias Elixir.Supervisor, as: OTPSup

  @gates [
    :spiffe_socket,
    :authzen_pdp_url,
    :kms,
    :finops,
    :drain,
    :affidavit,
    :siem
  ]

  setup do
    saved =
      Map.new(@gates, fn key -> {key, Application.get_env(:ash_a2a, key)} end)
      |> Map.put(:spiffe_trust_domain, Application.get_env(:ash_a2a, :spiffe_trust_domain))
      |> Map.put(:cmek_kms_client, Application.get_env(:ash_a2a, :cmek_kms_client))

    Enum.each(@gates, &Application.delete_env(:ash_a2a, &1))
    Application.delete_env(:ash_a2a, :spiffe_trust_domain)
    Application.delete_env(:ash_a2a, :cmek_kms_client)

    on_exit(fn ->
      Enum.each(saved, fn
        {key, nil} -> Application.delete_env(:ash_a2a, key)
        {key, value} -> Application.put_env(:ash_a2a, key, value)
      end)
    end)

    %{saved: saved}
  end

  # -- helpers --

  defp set_gates(kw) do
    Enum.each(kw, fn {key, value} -> Application.put_env(:ash_a2a, key, value) end)
  end

  defp unique(base) do
    :"#{base}_court_#{System.unique_integer([:positive])}"
  end

  defp start_sup(opts) do
    name = unique(AshA2A.Enterprise.Supervisor)
    overrides = Keyword.get(opts, :overrides, [])
    Supervisor.start_link(name: name, overrides: overrides)
  end

  defp stop_sup(:ignore), do: :ok

  defp stop_sup(pid) when is_pid(pid) do
    # Unlink BEFORE exiting so the supervisor's `:shutdown` exit signal can
    # never kill this (non-trapping) test process and mask a real failure.
    ref = Process.monitor(pid)
    Process.unlink(pid)
    Process.exit(pid, :shutdown)

    receive do
      {:DOWN, ^ref, _, _, _} -> :ok
    end
  end

  defp wait_until(fun, tries \\ 100) do
    if fun.() do
      :ok
    else
      if tries <= 1, do: flunk("wait_until timed out")

      Process.sleep(50)
      wait_until(fun, tries - 1)
    end
  end

  # A real UNIX-domain listener: the watcher's connect succeeds into the
  # listen backlog, so the real WorkloadWatcher reaches :watching.
  defp open_local_listener(path) do
    File.rm(path)

    {:ok, socket} =
      :gen_tcp.listen(0, [:binary, active: false, ip: {:local, to_charlist(path)}])

    on_exit(fn -> File.rm(path) end)
    socket
  end

  # ------------------------------------------------------------------
  # Court 1: empty config -> :ignore (dev/test boots unchanged)
  # ------------------------------------------------------------------

  test "empty config starts nothing (:ignore)" do
    assert :ignore = Supervisor.start_link(name: unique(AshA2A.Enterprise.Supervisor))

    # none of the enterprise children came up under default names either
    refute Process.whereis(AshA2A.TaskSupervisor)
    refute Process.whereis(AshA2A.Cluster.DrainManager)
    refute Process.whereis(AshA2A.SPIFFE.WorkloadWatcher)
  end

  # ------------------------------------------------------------------
  # Court 2: resolution — all keys vs partial config (pure layer)
  # ------------------------------------------------------------------

  test "all keys resolve to every startable child; unavailable ones typed-skip" do
    set_gates(
      spiffe_socket: "/run/spire/sockets/agent.sock",
      authzen_pdp_url: "http://127.0.0.1:1/authzen",
      kms: [client: AshA2A.Security.KMS.Local, kek_id: "ash-a2a/cmek-kek"],
      finops: [quotas: [%{cost_center: "cc1", ceiling: 1000}]],
      drain: true,
      affidavit: [wasm_path: "/opt/affidavit/engine.wasm"],
      siem: [endpoints: ["https://siem.example.com/ocel"]]
    )

    resolution = Supervisor.resolve()

    # every gated child that is really startable in this release is in the
    # tree; every one that is not is typed-skipped — exactly, never silent.
    gated = [
      AshA2A.SPIFFE.WorkloadWatcher,
      AshA2A.AuthZEN.DecisionPool,
      AshA2A.Security.KeyManager,
      AshA2A.FinOps.BudgetStore,
      AshA2A.Cluster.DrainManager,
      AshA2A.Evidence.AffidavitPool,
      AshA2A.Telemetry.OcelBroadcaster
    ]

    startable? = fn module ->
      Code.ensure_loaded?(module) and function_exported?(module, :child_spec, 1)
    end

    started = Enum.map(resolution.children, fn spec -> elem(spec.start, 0) end)

    assert Enum.sort(started) ==
             Enum.sort([
               Task.Supervisor | Enum.filter(gated, startable?)
             ])

    # skips are exactly the complement, each with a typed reason
    skipped = Map.new(resolution.skipped, fn {key, module, reason} -> {module, {key, reason}} end)

    assert MapSet.new(Map.keys(skipped)) ==
             MapSet.new(Enum.reject(gated, startable?))

    for {module, {key, reason}} <- resolution.skipped do
      assert key in [
               :spiffe_socket,
               :authzen_pdp_url,
               :kms,
               :finops,
               :drain,
               :affidavit,
               :siem
             ]

      assert match?({:module_unavailable, ^module}, reason) or
               match?({:not_startable, ^module}, reason)
    end
  end

  test "partial config resolves to exactly that key's children" do
    set_gates(spiffe_socket: "/run/spire/sockets/agent.sock")
    resolution = Supervisor.resolve()

    assert Enum.map(resolution.children, fn spec -> elem(spec.start, 0) end) == [
             AshA2A.SPIFFE.WorkloadWatcher
           ]

    assert resolution.skipped == []

    set_gates(spiffe_socket: nil)
    set_gates(drain: [drain_timeout_ms: 5_000])

    resolution = Supervisor.resolve()

    assert Enum.sort(Enum.map(resolution.children, fn spec -> elem(spec.start, 0) end)) ==
             Enum.sort([Task.Supervisor, AshA2A.Cluster.DrainManager])
  end

  test "a gate explicitly set to false is OFF" do
    set_gates(drain: false, spiffe_socket: nil)
    assert :ignore = Supervisor.start_link(name: unique(AshA2A.Enterprise.Supervisor))
  end

  # ------------------------------------------------------------------
  # Court 3: all keys -> all startable children really running
  # ------------------------------------------------------------------

  test "all keys boot the real children over real sockets/paths" do
    socket_path =
      Path.join(
        System.tmp_dir!(),
        "spire-enterprise-court-#{System.unique_integer([:positive])}.sock"
      )

    open_local_listener(socket_path)

    watcher_name = unique(AshA2A.SPIFFE.WorkloadWatcher)
    dm_name = unique(AshA2A.Cluster.DrainManager)
    ts_name = unique(AshA2A.TaskSupervisor)
    budget_name = unique(AshA2A.FinOps.BudgetStore)
    affidavit_name = unique(AshA2A.Evidence.AffidavitPool)
    siem_name = unique(AshA2A.Telemetry.OcelBroadcaster)

    set_gates(
      spiffe_socket: socket_path,
      authzen_pdp_url: "http://127.0.0.1:1/authzen",
      kms: [client: AshA2A.Security.KMS.Local, kek_id: "ash-a2a/cmek-kek"],
      finops: [quotas: []],
      drain: [drain_timeout_ms: 25_000],
      affidavit: [wasm_path: "/opt/affidavit/engine.wasm"],
      siem: [endpoints: ["https://siem.example.com/ocel"]]
    )

    ensure_decision_pool_free()

    expected =
      Supervisor.resolve() |> Map.get(:children) |> length()

    {:ok, sup} =
      start_sup(
        overrides: [
          {AshA2A.SPIFFE.WorkloadWatcher, name: watcher_name},
          {AshA2A.Cluster.DrainManager, name: dm_name},
          {AshA2A.TaskSupervisor, name: ts_name},
          {AshA2A.FinOps.BudgetStore, name: budget_name},
          {AshA2A.Evidence.AffidavitPool, name: affidavit_name},
          {AshA2A.Telemetry.OcelBroadcaster, name: siem_name}
        ]
      )

    try do
      # every resolved child is really running under the tree
      children = OTPSup.which_children(sup)
      assert length(children) == expected
      assert expected > 0

      for {_id, pid, _type, _modules} <- children do
        assert is_pid(pid) and Process.alive?(pid)
      end

      assert Process.whereis(AshA2A.AuthZEN.DecisionPool)
      assert Process.whereis(dm_name)
      assert Process.whereis(ts_name)

      # the watcher is connected to the real listener (not degraded)
      watcher_pid = Process.whereis(watcher_name)
      wait_until(fn -> WorkloadWatcher.status(watcher_pid) == :watching end)
    after
      stop_sup(sup)
    end
  end

  # ------------------------------------------------------------------
  # Court 4: drain enabled -> traps sigterm, drains a real tracked task
  # ------------------------------------------------------------------

  test "drain manager traps sigterm when enabled" do
    dm_name = unique(AshA2A.Cluster.DrainManager)
    ts_name = unique(AshA2A.TaskSupervisor)

    set_gates(drain: [drain_timeout_ms: 5_000])

    {:ok, sup} =
      start_sup(
        overrides: [
          {AshA2A.Cluster.DrainManager, name: dm_name},
          {AshA2A.TaskSupervisor, name: ts_name}
        ]
      )

    Process.flag(:trap_exit, true)

    try do
      dm = Process.whereis(dm_name)
      assert is_pid(dm)

      # a real task under the real supervised TaskSupervisor, tracked with
      # the real DrainManager
      parent = self()

      task =
        Task.async(fn ->
          :ok = DrainManager.track(dm_name, "court-task", frame: %{step: 1})
          send(parent, :tracked)

          receive do
            :conclude -> DrainManager.release(dm_name, "court-task")
          end
        end)

      assert_receive :tracked, 5_000

      # the exact message :os.set_signal(:sigterm, :handle) delivers for the
      # OS SIGTERM
      send(dm, :sigterm)

      wait_until(fn ->
        match?({:ok, true}, DrainManager.cordoned?(dm_name))
      end)

      # Phase 1: new work is refused, existing work continues
      refusal =
        Task.async(fn -> DrainManager.track(dm_name, "late-task") end)
        |> Task.await()

      assert refusal == {:error, :cordoned}

      assert DrainManager.tracked(dm_name) == {:ok, ["court-task"]}

      # Phase 2: the tracked task concludes -> drain completes; the manager
      # is restart: :temporary, so the supervisor does not restart it
      send(task.pid, :conclude)
      Task.await(task)

      wait_until(fn -> Process.whereis(dm_name) == nil end)

      wait_until(fn ->
        DrainManager.cordoned?(dm_name) == {:error, :drain_manager_unavailable}
      end)

      # the task supervisor sibling is unaffected
      assert Process.whereis(ts_name)

      assert length(OTPSup.which_children(sup)) == 1
    after
      stop_sup(sup)
    end
  end

  # `AshA2A.AuthZEN.DecisionPool` registers under its fixed global name; a
  # lazily-started instance from another suite would collide with the
  # supervised child. Stop any pre-existing instance (the pool is
  # self-healing: `ensure_started/0` rebuilds it on the next call).
  defp ensure_decision_pool_free do
    case Process.whereis(AshA2A.AuthZEN.DecisionPool) do
      nil ->
        :ok

      pid ->
        GenServer.stop(pid, :shutdown)
        wait_until(fn -> Process.whereis(AshA2A.AuthZEN.DecisionPool) == nil end)
    end
  end
end
