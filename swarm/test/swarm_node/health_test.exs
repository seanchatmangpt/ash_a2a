defmodule SwarmNode.HealthTest do
  @moduledoc """
  DEP-01 boot gate, DEP-05 probes, DEP-06 drain -- against the real running
  `:ash_a2a` + `:swarm_node` applications, a real second
  `AshA2A.GraphLaw.WasmexHost` pointed at a missing artifact, and a real Bandit
  listener queried over real HTTP (`:httpc`). No doubles.
  """

  use ExUnit.Case, async: false

  alias SwarmNode.Health

  setup do
    on_exit(fn -> Health.undrain() end)
    :ok
  end

  test "live/0 is :ok while the ash_a2a and agent supervisors run" do
    assert :ok = Health.live()
  end

  test "ready/1 fails while draining, and recovers after undrain" do
    assert :ok = Health.ready(min_peers: 0)
    assert :ok = Health.drain(drain_ms: 0)
    assert {:error, [:draining]} = Health.ready(min_peers: 0)
    :ok = Health.undrain()
    assert :ok = Health.ready(min_peers: 0)
  end

  test "ready/1 requires the configured number of connected peers" do
    peers = length(Node.list())

    assert {:error, [{:insufficient_peers, ^peers, 99}]} = Health.ready(min_peers: 99)
  end

  test "the boot gate refuses when GraphLaw is required but not loaded" do
    missing = Path.join(System.tmp_dir!(), "no_such_graphlaw_#{System.unique_integer()}.wasm")

    {:ok, dead_host} =
      AshA2A.GraphLaw.WasmexHost.start_link(
        name: nil,
        wasm_path: missing,
        expected_sha256: :unpinned
      )

    assert {:error, :graphlaw_unavailable} =
             Health.boot_gate(require_graphlaw: true, graphlaw_host: dead_host)

    assert {:error, [:graphlaw_unavailable]} =
             Health.ready(min_peers: 0, require_graphlaw: true, graphlaw_host: dead_host)

    assert :ok = Health.boot_gate(require_graphlaw: false, graphlaw_host: dead_host)
  end

  test "SwarmNode.Application.start/2 runs the boot gate (configured host)" do
    missing = Path.join(System.tmp_dir!(), "no_such_graphlaw_#{System.unique_integer()}.wasm")

    {:ok, dead_host} =
      AshA2A.GraphLaw.WasmexHost.start_link(
        name: nil,
        wasm_path: missing,
        expected_sha256: :unpinned
      )

    Application.put_env(:swarm_node, :require_graphlaw, true)
    Application.put_env(:swarm_node, :graphlaw_host, dead_host)

    on_exit(fn ->
      Application.delete_env(:swarm_node, :require_graphlaw)
      Application.delete_env(:swarm_node, :graphlaw_host)
    end)

    assert {:error, :graphlaw_unavailable} = SwarmNode.Application.start(:normal, [])

    # Loaded host: the gate passes and start proceeds to the supervisor (which
    # is already running under the test app, hence :already_started).
    Application.delete_env(:swarm_node, :graphlaw_host)
    assert {:error, {:already_started, _}} = SwarmNode.Application.start(:normal, [])
  end

  test "the boot gate admits when the shipped GraphLaw artifact is loaded" do
    assert AshA2A.GraphLaw.WasmexHost.available?(),
           "priv/graphlaw/praxis_graphlaw.wasm must load in the host app"

    assert :ok = Health.boot_gate(require_graphlaw: true)
  end

  describe "admin HTTP surface" do
    setup do
      pid =
        start_supervised!(
          {Bandit, plug: SwarmNode.AdminRouter, port: 0, ip: :loopback, startup_log: false}
        )

      {:ok, {_ip, port}} = ThousandIsland.listener_info(pid)
      :inets.start()
      %{base: "http://127.0.0.1:#{port}"}
    end

    test "healthz/readyz answer 200, readyz answers 503 after /drain", %{base: base} do
      Application.put_env(:swarm_node, :drain_ms, 0)
      on_exit(fn -> Application.delete_env(:swarm_node, :drain_ms) end)

      assert {200, "ok"} = get(base <> "/healthz")
      assert {200, "ok"} = get(base <> "/readyz")
      assert {200, "ok"} = get(base <> "/drain")
      assert {503, ":draining"} = get(base <> "/readyz")
      assert {200, "ok"} = get(base <> "/healthz")
      assert {404, _} = get(base <> "/nope")
    end
  end

  defp get(url) do
    {:ok, {{_, status, _}, _headers, body}} =
      :httpc.request(:get, {String.to_charlist(url), []}, [], body_format: :binary)

    {status, body}
  end
end
