# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshA2A.HealthTest do
  @moduledoc """
  OBS-06/OBS-07/OBS-08 qualification against the real running `:ash_a2a`
  application: real `AshA2A.Health` checks over real processes, served by the
  real `AshA2A.Health.Plug` behind a real Bandit listener, read with real
  `Req` GETs. No mocks.
  """
  use ExUnit.Case, async: false

  @moduletag :serial
  @moduletag :serial_shard

  alias AshA2A.Health

  setup do
    keys = [:health_kill_switch_classes, :outbox_ready_max, :health_ocel_failed_max]
    previous = for key <- keys, do: {key, Application.get_env(:ash_a2a, key)}

    on_exit(fn ->
      for {key, value} <- previous do
        if is_nil(value),
          do: Application.delete_env(:ash_a2a, key),
          else: Application.put_env(:ash_a2a, key, value)
      end
    end)

    :ok
  end

  defp start_http!(opts) do
    port = Enum.random(24_000..24_999)

    {:ok, pid} =
      Bandit.start_link(plug: {AshA2A.Health.Plug, opts}, port: port, ip: {127, 0, 0, 1})

    on_exit(fn -> Process.exit(pid, :normal) end)
    "http://127.0.0.1:#{port}"
  end

  test "liveness is :ok while AshA2A.Supervisor runs" do
    assert {:ok, %{checks: %{supervisor: %{status: :ok}}}} = Health.liveness()
  end

  test "readiness reports every component check and emits [:ash_a2a, :health, :checked]" do
    ref = make_ref()
    parent = self()

    :telemetry.attach(
      {__MODULE__, ref},
      [:ash_a2a, :health, :checked],
      fn _e, m, md, _ -> send(parent, {ref, m, md}) end,
      nil
    )

    on_exit(fn -> :telemetry.detach({__MODULE__, ref}) end)

    {status, %{checks: checks}} = Health.readiness()

    assert Map.keys(checks) |> Enum.sort() ==
             [:graph_law, :kill_switch, :ocel, :receipt_outbox, :receipt_store, :supervisor]

    # The test config uses the non-durable in-memory receipt store.
    assert checks.receipt_store.durable == false
    assert checks.receipt_store.status == :degraded
    assert status in [:degraded, :down]
    assert_receive {^ref, %{duration: d}, %{status: ^status}}, 1_000
    assert is_integer(d)
  end

  test "a tripped kill-switch class named for health makes readiness :down" do
    class = "health-obs-#{System.unique_integer([:positive])}"
    Application.put_env(:ash_a2a, :health_kill_switch_classes, [class])
    {_, %{checks: %{kill_switch: before}}} = Health.readiness()
    assert before.status == :ok

    :ok = AshA2A.KillSwitch.trip(class, :health_test)
    assert {:down, %{checks: %{kill_switch: after_trip}}} = Health.readiness()
    assert after_trip.tripped == [class]
  end

  test "a check that raises is reported :down, readiness stays total and still emits" do
    # A non-atom/non-binary class makes AshA2A.KillSwitch.tripped?/1 raise
    # FunctionClauseError; readiness must not crash the probe.
    Application.put_env(:ash_a2a, :health_kill_switch_classes, [{:not, :a, :class}])
    ref = make_ref()
    parent = self()

    :telemetry.attach(
      {__MODULE__, ref},
      [:ash_a2a, :health, :checked],
      fn _e, _m, md, _ -> send(parent, {ref, md}) end,
      nil
    )

    on_exit(fn -> :telemetry.detach({__MODULE__, ref}) end)

    assert {:down, %{checks: %{kill_switch: check}}} = Health.readiness()
    assert check == %{status: :down, reason: :check_failed, error: FunctionClauseError}
    assert_receive {^ref, %{status: :down}}, 1_000
  end

  test "an outbox deeper than :outbox_ready_max degrades readiness" do
    Application.put_env(:ash_a2a, :outbox_ready_max, -1)
    {_, %{checks: %{receipt_outbox: check}}} = Health.readiness()
    assert check.status == :degraded
  end

  test "an OCEL failure count above :health_ocel_failed_max degrades readiness" do
    Application.put_env(:ash_a2a, :health_ocel_failed_max, -1)
    {_, %{checks: %{ocel: check}}} = Health.readiness()
    assert check.status == :degraded
    Application.delete_env(:ash_a2a, :health_ocel_failed_max)
    {_, %{checks: %{ocel: check}}} = Health.readiness()
    assert check.status == :ok
  end

  test "aggregate/1 is the worst status" do
    assert Health.aggregate(%{a: %{status: :ok}, b: %{status: :ok}}) == :ok
    assert Health.aggregate(%{a: %{status: :ok}, b: %{status: :degraded}}) == :degraded
    assert Health.aggregate(%{a: %{status: :down}, b: %{status: :degraded}}) == :down
  end

  test "runtime_facts/0 flags tmp-backed paths" do
    assert Health.tmp_path?(Path.join(System.tmp_dir!(), "x"))
    refute Health.tmp_path?("/var/lib/ash_a2a")
    refute Health.tmp_path?(nil)
    facts = Health.runtime_facts()
    assert facts.receipt_store == AshA2A.ReceiptStore.Memory
    assert facts.durable == false
  end

  describe "HTTP surface" do
    test "GET /health/live is 200 JSON; /health/ready is 200 when degraded by default" do
      base = start_http!([])
      live = Req.get!(base <> "/health/live", retry: false)
      assert live.status == 200
      assert live.body["status"] == "ok"

      ready = Req.get!(base <> "/health/ready", retry: false)
      assert ready.status == 200
      assert ready.body["status"] == "degraded"
      assert ready.body["checks"]["receipt_store"]["durable"] == false
      assert ["no-store"] = Req.Response.get_header(ready, "cache-control")
    end

    test "degraded_status: 503 drains a degraded node" do
      base = start_http!(degraded_status: 503)
      assert Req.get!(base <> "/health/ready", retry: false).status == 503
    end

    test "a :down node is 503 on /health/ready" do
      class = "health-http-#{System.unique_integer([:positive])}"
      Application.put_env(:ash_a2a, :health_kill_switch_classes, [class])
      :ok = AshA2A.KillSwitch.trip(class, :health_test)
      base = start_http!([])
      resp = Req.get!(base <> "/health/ready", retry: false)
      assert resp.status == 503
      assert resp.body["status"] == "down"
    end

    test "unknown paths and methods fall through untouched" do
      conn = Plug.Test.conn(:post, "/health/ready") |> AshA2A.Health.Plug.call([])
      refute conn.halted
      conn = Plug.Test.conn(:get, "/other") |> AshA2A.Health.Plug.call([])
      refute conn.halted
    end
  end
end
